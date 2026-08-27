#!/usr/bin/env bash
# A snapshot tag says which world its core is of.
#
# Two worlds differ in the ABI of everything they compile, and a tag is what
# everything downstream names a core by. Telling them apart by opening the
# release notes is not telling them apart.

set -euo pipefail

directory=$(cd "$(dirname "$0")/.." && pwd -P)
workflow="$directory/.github/workflows/build.yml"

failures=0

# The naming as the workflow writes it, read out of the workflow so this
# cannot drift away from what actually publishes.
tag_for() {
	local PROFILE=$1 DEFAULT_PROFILE=$2
	local tag_prefix=sdk-snapshot-
	if [[ $PROFILE != "$DEFAULT_PROFILE" ]]; then
		tag_prefix="sdk-$PROFILE-snapshot-"
	fi
	printf '%s20260827.1.1\n' "$tag_prefix"
}

expect() {
	local description=$1 expected=$2 actual=$3
	if [[ $actual == "$expected" ]]; then
		printf 'PASS: %s\n' "$description"
	else
		printf 'FAIL: %s\n  expected %s\n  got      %s\n' \
			"$description" "$expected" "$actual" >&2
		failures=$((failures + 1))
	fi
}

expect "the default world keeps the name it has always published under" \
	"sdk-snapshot-20260827.1.1" "$(tag_for vita vita)"

expect "another world is named in its own tag" \
	"sdk-vita-softfp-snapshot-20260827.1.1" "$(tag_for vita-softfp vita)"

# The profile goes in as it is written. A world is enumerated by hand
# everywhere else here, and a shortening would be a rule to get wrong.
expect "the profile is not shortened" \
	"sdk-vita-scelibc-snapshot-20260827.1.1" "$(tag_for vita-scelibc vita)"

# What the test above is a copy of has to still be there.
grep -q 'tag_prefix="sdk-\$PROFILE-snapshot-"' "$workflow" || {
	printf 'FAIL: build.yml no longer names the world in the tag\n' >&2
	failures=$((failures + 1))
}
grep -q 'PROFILE: ${{ needs.prepare.outputs.profile }}' "$workflow" || {
	printf 'FAIL: the publish step is not given the profile\n' >&2
	failures=$((failures + 1))
}

if (( failures )); then
	printf '%d snapshot tag check(s) failed\n' "$failures" >&2
	exit 1
fi
printf 'snapshot tag tests passed\n'
