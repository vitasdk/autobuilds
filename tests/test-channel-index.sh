#!/usr/bin/env bash
# The release index says which series exist and what state each is in.
#
# It decides where people are told they may move to, so a bad status or a
# name that could climb out of a URL has to be refused here rather than
# discovered by a client.

set -euo pipefail

directory=$(cd "$(dirname "$0")/.." && pwd -P)
generator="$directory/scripts/generate-channel-index.py"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0

generate()
{
	printf '%s' "$1" > "$work/source.json"
	python3 "$generator" --source "$work/source.json" --output-dir "$work/out" >/dev/null 2>&1
}

accepts()
{
	if ! generate "$2"; then
		echo "$1: refused a valid index" >&2
		failures=$((failures + 1))
	fi
}

refuses()
{
	if generate "$2"; then
		echo "$1: accepted an index it should have refused" >&2
		failures=$((failures + 1))
	fi
}

accepts "a series" '{"2026.09":{"status":"supported","summary":"First release"}}'
accepts "every status" '{"a":{"status":"development"},"b":{"status":"supported"},"c":{"status":"deprecated"},"d":{"status":"end-of-life"}}'

refuses "an invented status" '{"2026.09":{"status":"probably fine"}}'
refuses "a missing status" '{"2026.09":{"summary":"no status"}}'
refuses "a name that escapes a path" '{"../evil":{"status":"supported"}}'
refuses "an empty index" '{}'

# The client parses only the canonical form, so key order is not cosmetic.
generate '{"nightly":{"status":"development"},"2026.09":{"status":"supported"}}'
if ! grep -q '{"channels":{"2026.09"' "$work/out/index.json"; then
	echo "canonical: keys were not sorted" >&2
	failures=$((failures + 1))
fi
if [ "$(tail -c 1 "$work/out/index.json" | wc -l | tr -d ' ')" != "1" ]; then
	echo "canonical: missing the trailing newline the manifests carry" >&2
	failures=$((failures + 1))
fi

[ "$failures" -eq 0 ] || exit 1
echo "channel index OK"
