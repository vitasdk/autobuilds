#!/usr/bin/env bash
# An input that already has a published snapshot is not built again, and
# what publishes the snapshot writes the record the next run reads.

set -euo pipefail

directory=$(cd "$(dirname "$0")/.." && pwd -P)
finder="$directory/scripts/find-built-snapshot.py"
workflow="$directory/.github/workflows/build.yml"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0

check() {
	local description=$1
	shift
	if "$@"; then
		printf 'PASS: %s\n' "$description"
	else
		printf 'FAIL: %s\n' "$description" >&2
		failures=$((failures + 1))
	fi
}

find_snapshot() {
	python3 "$finder" --build-id "$1" --releases "$2"
}

published='sha256:1111111111111111111111111111111111111111111111111111111111111111'
other='sha256:2222222222222222222222222222222222222222222222222222222222222222'

cat > "$work/releases.json" <<JSONEOF
[
  {"tag_name": "sdk-snapshot-20260825.3.1", "draft": false,
   "body": "Preview built from buildscripts revision aaaa.\n\nbuild_id: $other\nprofile: vita\n"},
  {"tag_name": "sdk-snapshot-20260825.2.1", "draft": true,
   "body": "Preview built from buildscripts revision bbbb.\n\nbuild_id: $published\nprofile: vita\n"},
  {"tag_name": "sdk-snapshot-20260825.1.1", "draft": false,
   "body": "Preview built from buildscripts revision cccc.\n\nbuild_id: $published\nprofile: vita\n"}
]
JSONEOF

check "a published snapshot for the input is found" \
	[ "$(find_snapshot "$published" "$work/releases.json")" = "sdk-snapshot-20260825.1.1" ]

# A draft is a snapshot whose upload may have died halfway through.
cat > "$work/draft-only.json" <<JSONEOF
[
  {"tag_name": "sdk-snapshot-20260825.2.1", "draft": true,
   "body": "build_id: $published\n"}
]
JSONEOF
check "a draft does not count as published" \
	[ -z "$(find_snapshot "$published" "$work/draft-only.json")" ]

check "an unbuilt input finds nothing" \
	[ -z "$(find_snapshot "sha256:3333" "$work/releases.json")" ]

check "an empty listing finds nothing" \
	bash -c "echo '[]' | python3 '$finder' --build-id '$published' | grep -q . && exit 1 || exit 0"

# The record is a line, not a mention: a note about some other snapshot
# must not stop a build that has to happen.
cat > "$work/prose.json" <<JSONEOF
[
  {"tag_name": "sdk-snapshot-20260825.4.1", "draft": false,
   "body": "Rebuilt because build_id: $published was wrong.\n"}
]
JSONEOF
check "a build_id quoted in prose is not a record" \
	[ -z "$(find_snapshot "$published" "$work/prose.json")" ]

check "a listing that is not an array fails loudly" \
	bash -c "echo '{}' | python3 '$finder' --build-id '$published' 2>/dev/null && exit 1 || exit 0"

# What publish writes has to be what the finder reads. Take the notes the
# workflow builds, fill in what Actions would fill in, and look for it.
python3 - "$workflow" "$published" > "$work/rendered-notes.md" <<'PYEOF'
import re, sys
text = open(sys.argv[1]).read()
match = re.search(r"<<NOTES\n(.*?)\n\s*NOTES\n", text, re.DOTALL)
if not match:
    sys.exit("the publish step no longer builds its notes with a NOTES heredoc")
lines = match.group(1).split("\n")
indent = min(len(line) - len(line.lstrip()) for line in lines if line.strip())
body = "\n".join(line[indent:] for line in lines)
body = body.replace("${{ needs.prepare.outputs.build_id }}", sys.argv[2])
sys.stdout.write(re.sub(r"\$\{\{[^}]*\}\}", "filled-in", body) + "\n")
PYEOF
python3 - "$work/rendered-notes.md" > "$work/rendered.json" <<'PYEOF'
import json, sys
body = open(sys.argv[1]).read()
json.dump([{"tag_name": "sdk-snapshot-rendered", "draft": False, "body": body}], sys.stdout)
PYEOF
check "the snapshot notes record the build_id the finder looks for" \
	[ "$(find_snapshot "$published" "$work/rendered.json")" = "sdk-snapshot-rendered" ]

# Deduplication must not reach a pull request: what it describes there is
# whatever buildscripts master holds, which is exactly what is published.
check "deduplication is skipped on pull requests" \
	grep -q "if: github.event_name != 'pull_request'" "$workflow"
check "the build is gated on the deduplication result" \
	grep -q "if: needs.prepare.outputs.duplicate != 'true'" "$workflow"

if [[ $failures -gt 0 ]]; then
	printf '%s check(s) failed\n' "$failures" >&2
	exit 1
fi
printf 'build deduplication: all checks passed\n'
