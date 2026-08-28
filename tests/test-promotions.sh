#!/usr/bin/env bash
# A release is a commit, so a commit has to be readable as a release.
#
# channels.json says which exact pair each series serves. What a change to it
# means -- which series moved, and to what -- is what the promotion check
# validates before the merge and what the publish reads afterwards, so both
# of them read it from here.

set -euo pipefail

directory=$(cd "$(dirname "$0")/.." && pwd -P)
promotions="$directory/scripts/promotions.py"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0

moved()
{
	python3 "$promotions" --before "$work/before.json" --after "$work/after.json" \
		--format lines 2>&1
}

check()
{
	local description=$1 expected=$2 actual
	actual=$(moved) || {
		printf 'FAIL: %s: refused\n  %s\n' "$description" "$actual" >&2
		failures=$((failures + 1))
		return
	}
	if [[ $actual != "$expected" ]]; then
		printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' \
			"$description" "$expected" "$actual" >&2
		failures=$((failures + 1))
	fi
}

refuses()
{
	local description=$1 expected=$2 output
	if output=$(moved); then
		printf 'FAIL: %s was accepted\n' "$description" >&2
		failures=$((failures + 1))
	elif ! grep -q -- "$expected" <<<"$output"; then
		printf 'FAIL: %s was refused without saying %s\n  %s\n' \
			"$description" "$expected" "$output" >&2
		failures=$((failures + 1))
	fi
}

series()
{
	printf '{"2026.08":{"status":"supported","summary":"s"%s},"nightly":{"status":"development","summary":"n"%s}}\n' \
		"$1" "${2:-}"
}

# A commit that touches something else about a series moves no pair.
series ',"core":"core-1","packages":"pkgs-1","world":"vita"' > "$work/before.json"
series ',"core":"core-1","packages":"pkgs-1","world":"vita","summary":"reworded"' > "$work/after.json"
check "a change that is not a promotion" ""

# The promotion itself.
series ',"core":"core-2","packages":"pkgs-2","world":"vita"' > "$work/after.json"
check "a series repointed at a new pair" "2026.08 core-2 pkgs-2 vita"

# Packages-only: the catalogue moved, the core did not.
series ',"core":"core-1","packages":"pkgs-9","world":"vita"' > "$work/after.json"
check "a catalogue-only move is still a promotion" "2026.08 core-1 pkgs-9 vita"

# A series that had no pair and gets one is the first promotion of a new line.
series '' > "$work/before.json"
series ',"core":"core-1","packages":"pkgs-1","world":"vita"' > "$work/after.json"
check "the first pair a series serves" "2026.08 core-1 pkgs-1 vita"

# Half a pointer publishes a manifest that names a release nobody built.
series ',"core":"core-1"' > "$work/after.json"
refuses "a core with no packages beside it" "not packages"

series ',"packages":"pkgs-1","world":"vita"' > "$work/after.json"
refuses "packages with no core" "not core"

# nightly moves several times a day; storing its pair means a bot commit per
# build, which is the thing the state branch exists to avoid.
series ',"core":"core-1","packages":"pkgs-1","world":"vita"' ',"core":"core-1","packages":"pkgs-1","world":"vita"' > "$work/after.json"
refuses "nightly carrying a pair" "moves on its own"

# A world is what a channel is, not what it serves: an automatic channel says
# which one it is without pinning anything, the same way it says its status.
series ',"core":"core-1","packages":"pkgs-1","world":"vita"' ',"world":"vita_softfp"' > "$work/after.json"
check "an automatic channel naming only its world" "2026.08 core-1 pkgs-1 vita"

series ',"core":"core-1","packages":"pkgs-1","world":"vita"' ',"core":"c","packages":"p","world":"vita_softfp"' > "$work/after.json"
refuses "an automatic channel carrying a pair beside its world" "moves on its own"

# Emptying a pointer leaves the served manifest pointing where nobody looks.
series ',"core":"core-1","packages":"pkgs-1","world":"vita"' > "$work/before.json"
series '' > "$work/after.json"
refuses "a pair taken away" "keeps its pair"

# A channel with no pair in the file moves on its own, and the publisher asks
# this to decide whether to check it is still the newest candidate. The two
# have to agree, or a channel gets published without that check.
for name in $(python3 -c "
import json
for name, entry in json.load(open('$directory/channels.json')).items():
    print(name)
"); do
	pinned=$(python3 -c "
import json
entry = json.load(open('$directory/channels.json'))['$name']
print('yes' if entry.get('core') or entry.get('packages') else 'no')
")
	answer=$(python3 "$promotions" --after "$directory/channels.json" --automatic "$name")
	case "$pinned:$answer" in
		yes:false|no:true) ;;
		*)
			printf 'FAIL: %s is pinned=%s but reported automatic=%s\n' \
				"$name" "$pinned" "$answer" >&2
			failures=$((failures + 1))
			;;
	esac
done

# And the file in this repository has to be one of the valid ones.
cp "$directory/channels.json" "$work/after.json"
cp "$directory/channels.json" "$work/before.json"
check "the committed channels.json is a valid one" ""
if ! python3 -c "
import json, sys
entry = json.load(open('$directory/channels.json'))['2026.08']
missing = [f for f in ('core', 'packages', 'world') if not entry.get(f)]
sys.exit('2026.08 serves no pair: missing ' + ', '.join(missing) if missing else 0)
"; then
	failures=$((failures + 1))
fi

# What a series serves right now, which is the number a patch of it may not
# go back past. Nothing read this before, so a version typed into VERSION by
# hand was compared against nothing at all.
serving()
{
	python3 "$promotions" --after "$work/serving.json" --serving "$1" 2>&1
}

serves()
{
	local description=$1 series=$2 expected=$3 actual
	actual=$(serving "$series") || {
		printf 'FAIL: %s: refused\n  %s\n' "$description" "$actual" >&2
		failures=$((failures + 1))
		return
	}
	if [[ $actual != "$expected" ]]; then
		printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' \
			"$description" "$expected" "$actual" >&2
		failures=$((failures + 1))
	fi
}

cat > "$work/serving.json" <<'JSON'
{
  "2026.08": {"core": "core-1", "packages": "pkgs-1", "world": "vita"},
  "2026.09": {"status": "development"},
  "nightly": {"status": "development"}
}
JSON

serves "a series that serves a pair names it" 2026.08 "core-1 pkgs-1 vita"
serves "a series that has published nothing yet says nothing" 2026.09 ""
serves "a series nobody declared says nothing" 2026.10 ""

# nightly has no pointer here, and asking as if it did has to be refused
# rather than answered with silence: silence reads as "no previous version",
# which waves anything through.
if output=$(serving nightly); then
	printf 'FAIL: nightly was answered as if it served a pair\n' >&2
	failures=$((failures + 1))
elif [[ $output != *"moves on its own"* ]]; then
	printf 'FAIL: nightly was refused for the wrong reason: %s\n' "$output" >&2
	failures=$((failures + 1))
fi

# And the commit has to reach the thing that publishes it.
while IFS= read -r problem; do
	printf 'FAIL: %s\n' "$problem" >&2
	failures=$((failures + 1))
done < <(python3 - "$directory/.github/workflows/channel.yml" <<'PYEOF'
import sys, yaml

document = yaml.safe_load(open(sys.argv[1]))
triggers = document[True] if True in document else document["on"]

push = triggers.get("push")
if not push:
    print("a commit to channels.json publishes nothing: there is no push trigger")
else:
    if push.get("paths") != ["channels.json"]:
        print(f"the push trigger watches {push.get('paths')}, not channels.json alone")
    if push.get("branches") != ["master"]:
        print(f"the push trigger watches {push.get('branches')}, not master alone")

publish = document["jobs"].get("update-channel", {})
if "promotions" not in (publish.get("needs") or []):
    print("what publishes does not wait for what decides which series moved")
matrix = ((publish.get("strategy") or {}).get("matrix") or {}).get("entry", "")
if "needs.promotions.outputs.entries" not in str(matrix):
    print("what publishes does not read the series from the promotions it found")
if "!= '[]'" not in str(publish.get("if", "")):
    print("a commit that repoints nothing would still try to publish")
PYEOF
)

if (( failures )); then
	printf '%d promotion check(s) failed\n' "$failures" >&2
	exit 1
fi

printf 'promotion tests passed\n'
