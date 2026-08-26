#!/usr/bin/env bash
# Two builds in flight at once, and the older one must not win.
#
# A push and the cron backstop, a dispatch and a re-run: they overlap, and
# they finish in whatever order they finish. What decides is a pointer that
# several workflows read and write, so it needs a real compare-and-swap, and
# a result that arrives after a newer candidate exists has to fail closed.

set -euo pipefail

directory=$(cd "$(dirname "$0")/.." && pwd -P)
state="$directory/scripts/state.py"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

remote="$work/remote.git"
git init --quiet --bare "$remote"

failures=0

run()
{
	python3 "$state" --repository "$remote" --profile vita "$@"
}

field()
{
	run read --field "$1" 2>/dev/null
}

check()
{
	local description=$1 expected=$2 actual=$3
	if [[ $actual != "$expected" ]]; then
		printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' \
			"$description" "$expected" "$actual" >&2
		failures=$((failures + 1))
	fi
}

refuses()
{
	local description=$1
	shift
	if output=$(run "$@" 2>&1); then
		printf 'FAIL: %s was accepted\n' "$description" >&2
		failures=$((failures + 1))
	elif [[ $? != 3 ]] && ! grep -q '^stale:' <<<"$output"; then
		printf 'FAIL: %s failed for the wrong reason: %s\n' "$description" "$output" >&2
		failures=$((failures + 1))
	fi
}

# Nothing has ever been recorded: a world with no state reads as generation 0
# rather than as an error, because that is what the first build finds.
check "an empty state has no candidate" 0 "$(field generation)"

# Until a build records one, there is nothing for a result to be older than.
# Every world looks like this before its first build, and so does a core
# published before any of this existed: the channel has to keep moving.
if ! run promote --core-snapshot sdk-snapshot-from-before >/dev/null 2>&1; then
	printf 'FAIL: a channel update with no candidate recorded was refused\n' >&2
	failures=$((failures + 1))
fi
check "and refusing nothing wrote nothing" 0 "$(field generation)"

check "the first candidate is generation 1" 1 "$(run record --build-id sha256:aaa --version 0.20260826.1 --run 101)"
check "and it is the one recorded" sha256:aaa "$(field build_id)"
check "with nothing published yet" "" "$(field core_snapshot)"

check "a second input takes the candidacy" 2 "$(run record --build-id sha256:bbb --version 0.20260826.2 --run 102)"
check "and the first is no longer it" sha256:bbb "$(field build_id)"

# The first build finishes late. Its snapshot is still published -- snapshots
# are immutable and cost nothing -- but it does not get to be the candidate.
refuses "a snapshot from an overtaken build" publish --generation 1 --core-snapshot sdk-snapshot-aaa
check "the candidate is untouched" "" "$(field core_snapshot)"

run publish --generation 2 --core-snapshot sdk-snapshot-bbb >/dev/null
check "the current build names its snapshot" sdk-snapshot-bbb "$(field core_snapshot)"
check "and is waiting for packages" packages_building "$(field status)"

# The case this exists for: packages for the overtaken core arrive after a
# newer core is already the candidate. Nightly must not move.
refuses "packages for an overtaken core" promote --core-snapshot sdk-snapshot-aaa
check "the channel would still be moved by the current one" packages_building "$(field status)"

run promote --core-snapshot sdk-snapshot-bbb >/dev/null
check "the current pair promotes" promoted "$(field status)"

# One input builds once. A second run that describes the same revision is
# refused the candidacy, which is what stops it repeating a build already
# under way -- the case the six-hourly backstop hits when it fires during an
# announced build of the same head.
check "a third input takes the candidacy" 3 "$(run record --build-id sha256:ccc --version 0.20260826.3 --run 103)"
refuses "a second run of an input already being built" \
	record --build-id sha256:ccc --version 0.20260826.3 --run 104
check "and the refusal left the generation alone" 3 "$(field generation)"
check "the run building it is still the one that said so" 103 "$(field run)"

# A candidate recorded before any of this existed names no run, and nobody can
# ask whether a run that was never written down is still going. It holds
# nothing: the alternative is a document that no build may ever take on.
python3 - "$remote" <<'PYEOF'
import json, subprocess, sys, tempfile
remote = sys.argv[1]
root = tempfile.mkdtemp()
subprocess.run(["git", "clone", "--quiet", "--branch", "state", remote, root], check=True)
path = f"{root}/state/vita.json"
document = json.load(open(path))
del document["candidate"]["run"]
json.dump(document, open(path, "w"), indent=2, sort_keys=True)
for command in (["add", "-A"], ["-c", "user.name=t", "-c", "user.email=t@t",
                                "commit", "--quiet", "-m", "older document"],
                ["push", "--quiet", "origin", "HEAD:state"]):
    subprocess.run(["git", *command], cwd=root, check=True)
PYEOF
check "a candidate with no run recorded does not hold the input" 4 \
	"$(run record --build-id sha256:ccc --version 0.20260826.3 --run 104)"
check "and the run that took it is written down" 104 "$(field run)"

# A re-run is the same run, and it has to be able to take its candidacy back:
# refusing it would leave a failed build unrepeatable.
check "the run that holds it may record again" 5 \
	"$(run record --build-id sha256:ccc --version 0.20260826.3 --run 104)"

# And when the holder is over -- cancelled, failed, out of time -- somebody
# has to be able to take the input on. The state branch cannot know that a
# run has stopped, so the caller establishes it and says so here.
refuses "a second run while 104 still holds it" \
	record --build-id sha256:ccc --version 0.20260826.3 --run 105
check "taking over a dead holder records a generation" 6 \
	"$(run record --build-id sha256:ccc --version 0.20260826.3 --run 105 --take-over)"
check "and the new run is the one building it" 105 "$(field run)"

# Only the same input is refused: a different one is a newer candidate, which
# is the whole point of the pointer and must never be blocked.
check "a different input is never refused" 7 \
	"$(run record --build-id sha256:ddd --version 0.20260826.4 --run 106)"

# Once it is published it is no longer being built, so the guard lets go: the
# published-snapshot check is what stops a rebuild from there on.
run publish --generation 7 --core-snapshot sdk-snapshot-ddd >/dev/null
check "a published candidate does not hold the input" 8 \
	"$(run record --build-id sha256:ddd --version 0.20260826.4 --run 107)"

# Concurrent writers: a rejected push is the compare-and-swap failing, so the
# writer re-reads and decides again. No update may be lost.
before=$(field generation)
pids=()
for writer in 1 2 3 4; do
	run record --build-id "sha256:race$writer" --version "0.20260826.1$writer" --run "20$writer" >"$work/race$writer" 2>&1 &
	pids+=($!)
done
succeeded=0
for pid in "${pids[@]}"; do
	if wait "$pid"; then succeeded=$((succeeded + 1)); fi
done
check "every writer that succeeded moved the generation exactly once" \
	"$((before + succeeded))" "$(field generation)"
if (( succeeded < 4 )); then
	printf 'note: %d of 4 concurrent writers gave up retrying\n' "$((4 - succeeded))" >&2
fi

if (( failures )); then
	printf '%d state check(s) failed\n' "$failures" >&2
	exit 1
fi

printf 'state branch tests passed\n'
