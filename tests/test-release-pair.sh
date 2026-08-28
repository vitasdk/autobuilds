#!/usr/bin/env bash
# A channel may only be pointed at two halves of the same release.
#
# The check that existed asked the packages which core they were built
# against and believed the answer. Nobody opened the core, so the series it
# belongs to -- the one thing that says who a publish moves -- was never
# compared with the channel being published.

set -euo pipefail

directory=$(cd "$(dirname "$0")/.." && pwd -P)
verifier="$directory/scripts/verify-release-pair.py"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0

lock()
{
	printf '{"schema":1,"version":"%s","series":%s,"buildscripts_revision":"%s"}\n' \
		"$1" "$2" "${3:-45c0a932f}" > "$work/lock.json"
}

provenance()
{
	printf '{"schema_version":2,"core_snapshot":"%s","buildscripts_revision":"%s"}\n' \
		"$1" "${2:-}" > "$work/provenance.json"
}

# A snapshot holding more than one world records the core each of them was
# built against, and repeats the first one in the singular field.
provenance_worlds()
{
	printf '{"schema_version":2,"core_snapshot":"%s","buildscripts_revision":"",' \
		"$1" > "$work/provenance.json"
	printf '"worlds":[{"arch":"vita","core":"%s"},{"arch":"vita_softfp","core":"%s"}]}\n' \
		"$1" "$2" >> "$work/provenance.json"
}

# A lock that also says which world the core was built as.
lock_profile()
{
	printf '{"schema":1,"version":"%s","series":%s,"buildscripts_revision":"45c0a932f","profile":"%s"}\n' \
		"$1" "$2" "$3" > "$work/lock.json"
}

verify()
{
	python3 "$verifier" \
		--core-release "${core:-sdk-snapshot-1.1.1}" \
		--packages-release "${packages:-packages-snapshot-1.1.1}" \
		--channel "$1" \
		--core-lock "$work/lock.json" \
		--packages-provenance "$work/provenance.json" \
		"${@:2}" 2>&1
}

accepts()
{
	local description=$1
	shift
	if ! output=$(verify "$@"); then
		printf 'FAIL: %s\n  %s\n' "$description" "$output" >&2
		failures=$((failures + 1))
	fi
}

refuses()
{
	local description=$1 expected=$2
	shift 2
	if output=$(verify "$@"); then
		printf 'FAIL: %s was accepted\n' "$description" >&2
		failures=$((failures + 1))
	elif ! grep -q -- "$expected" <<<"$output"; then
		printf 'FAIL: %s was refused without naming %s\n  %s\n' \
			"$description" "$expected" "$output" >&2
		failures=$((failures + 1))
	fi
}

# The two shapes that exist today, both taken from what is published.
lock 0.20260825.285 null
provenance sdk-snapshot-1.1.1
accepts "a derived version publishes to nightly" nightly

lock 2026.08.1 '"2026.08"'
provenance sdk-snapshot-1.1.1
accepts "a declared version publishes to its own series" 2026.08

# What the series field was added for: an announcement with no series names
# the unnamed one, and nightly is the unnamed one.
lock 2026.08.1 '"2026.08"'
provenance sdk-snapshot-1.1.1
refuses "a patch published to nightly" "2026.08" nightly

# And the same mistake the other way, which is worse: the people on a series
# chose it so it would not move.
lock 0.20260825.285 null
provenance sdk-snapshot-1.1.1
refuses "a nightly core published to a series" "belongs to no" 2026.08

lock 2026.08.1 '"2026.08"'
provenance sdk-snapshot-1.1.1
refuses "a core of another series" "not to" 2026.09

# A channel that is neither nightly nor the core's series is a typo, not a
# third kind of thing.
refuses "a channel no core declares" "not to" stable

# The check that already existed, kept and tested.
lock 2026.08.1 '"2026.08"'
provenance sdk-snapshot-9.9.9
refuses "packages built against another core" "sdk-snapshot-9.9.9" 2026.08

# A snapshot serves one repository per world, each built against its own
# core, so which core the packages must match depends on the world the
# channel serves. Comparing the singular field would hold every world to the
# first one's core.
core=sdk-core-2.2.2-softfp
lock_profile 2026.08.1 '"2026.08"' vita_softfp
provenance_worlds sdk-snapshot-1.1.1 sdk-core-2.2.2-softfp
accepts "a softfp channel matched against the softfp core" 2026.08 --world vita_softfp

core=sdk-snapshot-1.1.1
lock_profile 2026.08.1 '"2026.08"' vita
provenance_worlds sdk-snapshot-1.1.1 sdk-core-2.2.2-softfp
accepts "the default channel matched against its own core" 2026.08 --world vita

core=sdk-snapshot-1.1.1
lock_profile 2026.08.1 '"2026.08"' vita_softfp
provenance_worlds sdk-snapshot-1.1.1 sdk-core-2.2.2-softfp
refuses "a softfp channel offered the default world's core" "sdk-core-2.2.2-softfp" \
	2026.08 --world vita_softfp

# Asking for a world the packages do not carry is the mistake this replaces:
# before, it silently compared against whichever core came first.
core=sdk-snapshot-1.1.1
lock_profile 2026.08.1 '"2026.08"' vita-scelibc
provenance_worlds sdk-snapshot-1.1.1 sdk-core-2.2.2-softfp
refuses "a world the snapshot does not carry" "carries no" 2026.08 --world vita-scelibc

# A snapshot from before worlds were recorded still answers, through the
# field it does have.
core=sdk-snapshot-1.1.1
lock_profile 2026.08.1 '"2026.08"' vita
provenance sdk-snapshot-1.1.1
accepts "a snapshot that predates worlds" 2026.08 --world vita
unset core

# Both halves record a buildscripts revision only sometimes; disagreeing is a
# mismatched pair, silence is today's normal.
lock 2026.08.1 '"2026.08"' 45c0a932f
provenance sdk-snapshot-1.1.1 deadbeef
refuses "halves built from different buildscripts" "deadbeef" 2026.08

lock 2026.08.1 '"2026.08"' 45c0a932f
provenance sdk-snapshot-1.1.1
accepts "a packages release that records no revision" 2026.08
refuses "a publish pinned to a revision neither half names" "0badc0de" \
	2026.08 --buildscripts-sha 0badc0de

# The release itself may simply not be there, which is what a mistyped tag
# looks like from here.
mkdir -p "$work/bin"
printf '#!/bin/sh\nprintf "release not found\\n" >&2\nexit 1\n' > "$work/bin/gh"
chmod +x "$work/bin/gh"
if output=$(PATH="$work/bin:$PATH" python3 "$verifier" \
		--core-release sdk-snapshot-typo --packages-release packages-snapshot-1.1.1 \
		--channel nightly 2>&1); then
	printf 'FAIL: a core release that does not exist was accepted\n' >&2
	failures=$((failures + 1))
elif ! grep -q "sdk-snapshot-typo" <<<"$output"; then
	printf 'FAIL: a missing release was refused without naming it\n  %s\n' "$output" >&2
	failures=$((failures + 1))
fi

if (( failures )); then
	printf '%d release pair check(s) failed\n' "$failures" >&2
	exit 1
fi

printf 'release pair tests passed\n'
