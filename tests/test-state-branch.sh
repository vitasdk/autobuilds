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

check "the first candidate is generation 1" 1 "$(run record --build-id sha256:aaa --version 0.20260826.1)"
check "and it is the one recorded" sha256:aaa "$(field build_id)"
check "with nothing published yet" "" "$(field core_snapshot)"

check "a second input takes the candidacy" 2 "$(run record --build-id sha256:bbb --version 0.20260826.2)"
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

# Concurrent writers: a rejected push is the compare-and-swap failing, so the
# writer re-reads and decides again. No update may be lost.
before=$(field generation)
pids=()
for writer in 1 2 3 4; do
	run record --build-id "sha256:race$writer" --version "0.20260826.1$writer" >"$work/race$writer" 2>&1 &
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
