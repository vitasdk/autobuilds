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

# Emptying a pointer leaves the served manifest pointing where nobody looks.
series ',"core":"core-1","packages":"pkgs-1","world":"vita"' > "$work/before.json"
series '' > "$work/after.json"
refuses "a pair taken away" "keeps its pair"

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

if (( failures )); then
	printf '%d promotion check(s) failed\n' "$failures" >&2
	exit 1
fi

printf 'promotion tests passed\n'
