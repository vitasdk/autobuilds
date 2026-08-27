#!/usr/bin/env bash
# The manifest is what a client actually trusts, so its shape for a
# non-default world has to be checked the same way the channel index is:
# locally, without touching the network.

set -euo pipefail

directory=$(cd "$(dirname "$0")/.." && pwd -P)
generator="$directory/scripts/generate-channel-manifest.py"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0

# generate-channel-manifest.py fetches one database per host architecture
# plus the packages database; --core-dir/--packages-dir point it at local
# fixtures instead of the network.
core_dir="$work/core"
packages_dir="$work/packages"
mkdir -p "$core_dir" "$packages_dir"
for host in aarch64-linux-gnu arm64-apple-darwin x86_64-linux-gnu x86_64-w64-mingw32; do
	printf 'fixture' > "$core_dir/$host.db"
done

generate()
{
	local world=$1 packages_db=$2
	printf 'fixture' > "$packages_dir/$packages_db"
	python3 "$generator" \
		--core-release sdk-snapshot-20260819.1.1 \
		--packages-release packages-snapshot-20260819.1.1 \
		--channel nightly \
		--sequence 1 \
		--core-dir "$core_dir" \
		--packages-dir "$packages_dir" \
		--world "$world" \
		--output-dir "$work/out-$world" >/dev/null
}

generate vita vita.db
if ! grep -q '"schema_version":1' "$work/out-vita/nightly.json"; then
	echo "default world: expected schema_version 1" >&2
	failures=$((failures + 1))
fi
if ! grep -q '"world":"vita"' "$work/out-vita/nightly.json"; then
	echo "default world: manifest does not declare its world" >&2
	failures=$((failures + 1))
fi
if ! grep -q '"name":"vita.db"' "$work/out-vita/nightly.json"; then
	echo "default world: packages database should be vita.db" >&2
	failures=$((failures + 1))
fi

generate vita-softfp vita-softfp.db
if ! grep -q '"schema_version":2' "$work/out-vita-softfp/nightly.json"; then
	echo "softfp world: expected schema_version 2, so an older client fails closed" >&2
	failures=$((failures + 1))
fi
if ! grep -q '"world":"vita-softfp"' "$work/out-vita-softfp/nightly.json"; then
	echo "softfp world: manifest does not declare its world" >&2
	failures=$((failures + 1))
fi
if ! grep -q '"name":"vita-softfp.db"' "$work/out-vita-softfp/nightly.json"; then
	echo "softfp world: packages database should be vita-softfp.db, not vita.db" >&2
	failures=$((failures + 1))
fi

if python3 "$generator" \
	--core-release sdk-snapshot-20260819.1.1 \
	--packages-release packages-snapshot-20260819.1.1 \
	--core-dir "$core_dir" --packages-dir "$packages_dir" \
	--world does-not-exist --output-dir "$work/out-bad" \
	>/dev/null 2>&1; then
	echo "an unknown world should have been refused" >&2
	failures=$((failures + 1))
fi

[ "$failures" -eq 0 ] || exit 1
echo "channel manifest OK"
