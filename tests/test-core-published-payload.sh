#!/usr/bin/env bash
#
# A published core says which world it belongs to.
#
# The catalogue side pins a core per world and matches on the world and the
# series together. Told only the series, it finds whichever world happens to
# be first in it: a softfp core was pinned as the default world's, which
# dropped 133 staged packages and would have rebuilt them with the wrong ABI
# under the right name.

set -euo pipefail

directory=$(cd "$(dirname "$0")/.." && pwd -P)
workflow="$directory/.github/workflows/build.yml"

failures=0

for field in core_snapshot series world; do
	grep -q "client_payload\[$field\]" "$workflow" || {
		printf 'FAIL: the core_published payload does not carry %s\n' "$field" >&2
		failures=$((failures + 1))
	}
done

# The world it carries has to be the one that was built, which is the profile
# the lock named and the build ran with.
grep -q 'client_payload\[world\]="${{ needs.prepare.outputs.profile }}"' "$workflow" || {
	printf 'FAIL: the payload names a world that is not the profile it built\n' >&2
	failures=$((failures + 1))
}

if (( failures )); then
	printf '%d core_published payload check(s) failed\n' "$failures" >&2
	exit 1
fi
printf 'core_published payload tests passed\n'
