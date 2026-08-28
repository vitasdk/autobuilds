#!/usr/bin/env bash
# Which hosts a channel offers comes off the core release, not a list here.
#
# The list here fell behind: the core published nine hosts and the channel
# kept offering four, so musl, FreeBSD and Intel macOS had a core sitting in
# a release that no client would ever be told about. A release carries one
# database per host it published, so that is what decides.

set -euo pipefail

directory=$(cd "$(dirname "$0")/.." && pwd -P)
generator="$directory/scripts/generate-channel-manifest.py"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0

# --core-dir keeps this off the network: the question is which names become
# architectures, not how a digest is fetched.
generate()
{
	rm -rf "$work/core" "$work/packages" "$work/out"
	mkdir -p "$work/core" "$work/packages"
	for host in $1; do
		printf 'database for %s\n' "$host" > "$work/core/$host.db"
	done
	printf 'packages\n' > "$work/packages/vita.db"
	python3 "$generator" \
		--core-release core-under-test --packages-release packages-under-test \
		--channel nightly --world vita --sequence 1 \
		--core-dir "$work/core" --packages-dir "$work/packages" \
		--output-dir "$work/out"
}

architectures_of()
{
	python3 -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1]))["core"]["architectures"])))' \
		"$work/out/nightly.json"
}

check()
{
	description=$1
	hosts=$2
	expected=$3

	if ! generate "$hosts" >/dev/null 2>&1; then
		printf 'FAIL: %s: the generator refused\n' "$description" >&2
		failures=$((failures + 1))
		return
	fi
	actual=$(architectures_of)
	if [[ $actual != "$expected" ]]; then
		printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' \
			"$description" "$expected" "$actual" >&2
		failures=$((failures + 1))
	fi
}

# The nine the core publishes today. The four this used to hardcode are a
# subset, so a wrong answer here is the exact bug that shipped.
nine="aarch64-linux-gnu aarch64-linux-musl aarch64-unknown-freebsd
	arm64-apple-darwin x86_64-apple-darwin x86_64-linux-gnu
	x86_64-linux-musl x86_64-unknown-freebsd x86_64-w64-mingw32"
check "every published host reaches the manifest" "$nine" \
	"aarch64-linux-gnu aarch64-linux-musl aarch64-unknown-freebsd arm64-apple-darwin x86_64-apple-darwin x86_64-linux-gnu x86_64-linux-musl x86_64-unknown-freebsd x86_64-w64-mingw32"

# A series pinned to an older core offers what that core has, and no more.
check "an older core offers only its own hosts" \
	"aarch64-linux-gnu arm64-apple-darwin x86_64-linux-gnu x86_64-w64-mingw32" \
	"aarch64-linux-gnu arm64-apple-darwin x86_64-linux-gnu x86_64-w64-mingw32"

# A core with no databases is not a channel with no hosts, it is a mistake.
rm -rf "$work/core" "$work/packages" "$work/out"
mkdir -p "$work/core" "$work/packages"
printf 'packages\n' > "$work/packages/vita.db"
if output=$(python3 "$generator" \
		--core-release empty-core --packages-release packages-under-test \
		--channel nightly --world vita --sequence 1 \
		--core-dir "$work/core" --packages-dir "$work/packages" \
		--output-dir "$work/out" 2>&1); then
	printf 'FAIL: a core with no host database was accepted\n' >&2
	failures=$((failures + 1))
elif ! grep -qi 'no host database' <<< "$output"; then
	printf 'FAIL: refusing an empty core did not say why: %s\n' "$output" >&2
	failures=$((failures + 1))
fi

if (( failures )); then
	printf '%d channel host check(s) failed\n' "$failures" >&2
	exit 1
fi

printf 'channel host derivation tests passed\n'
