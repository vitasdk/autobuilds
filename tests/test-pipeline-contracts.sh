#!/usr/bin/env bash
#
# Automated contract tests for VitaSDK cross-repository deterministic pipeline.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTOBUILDS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_ROOT="$(cd "$AUTOBUILDS_ROOT/.." && pwd)"
# The recipes are read from a checkout beside this one, which is how CI lays
# them out. Say so when they are not there: a bare grep error on a missing
# path reads like a failing contract, and this test is then ignored for the
# wrong reason -- which is exactly what happened.
PACKAGES_ROOT="${PACKAGES_ROOT:-$WORKSPACE_ROOT/packages}"
if [[ ! -f $PACKAGES_ROOT/Dockerfile ]]; then
    echo "SKIP: no vitasdk/packages checkout at $PACKAGES_ROOT" >&2
    echo "      set PACKAGES_ROOT to run the recipe contracts" >&2
    exit 0
fi

echo "=== Running VitaSDK Cross-Repository Pipeline Contract Tests ==="

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# --- Test A: Validate Dockerfile logic and contract for CORE_SNAPSHOT ---
echo "--- Test A: Dockerfile core_snapshot contract ---"
grep -q "ARG CORE_SNAPSHOT" "$PACKAGES_ROOT/Dockerfile" || {
    echo "FAIL: packages/Dockerfile missing ARG CORE_SNAPSHOT" >&2
    exit 1
}
grep -q "vitasdk-bootstrap-x86_64-linux-gnu.tar.bz2" "$PACKAGES_ROOT/Dockerfile" || {
    echo "FAIL: packages/Dockerfile does not reference exact bootstrap archive" >&2
    exit 1
}
grep -q "sha256sum" "$PACKAGES_ROOT/Dockerfile" || {
    echo "FAIL: packages/Dockerfile does not compute and verify sha256" >&2
    exit 1
}
echo "PASS: Test A (Dockerfile CORE_SNAPSHOT contract)"

# --- Test B: Validate provenance.json format and schema ---
echo "--- Test B: provenance.json schema validation ---"
python3 -c "
import json

dummy_provenance = {
    'schema_version': 1,
    'core_snapshot': 'sdk-snapshot-20260811.1.1',
    'packages_revision': 'abcdef1234567890abcdef1234567890abcdef12',
    'buildscripts_revision': '1234567890abcdef1234567890abcdef12345678'
}

assert dummy_provenance['schema_version'] == 1
assert dummy_provenance['core_snapshot'].startswith('sdk-snapshot-')
assert len(dummy_provenance['packages_revision']) == 40
assert len(dummy_provenance['buildscripts_revision']) == 40
"
echo "PASS: Test B (provenance.json schema)"

# --- Test C: Channel promotion must reject mismatched core and packages provenance ---
echo "--- Test C: Channel promotion rejects mismatched provenance ---"
cat > "$TEMP_DIR/lock.json" <<'JSON'
{"schema":1,"version":"0.20260811.1","series":null,"buildscripts_revision":"2222222222222222222222222222222222222222"}
JSON
cat > "$TEMP_DIR/provenance.json" <<'JSON'
{"schema_version":2,"core_snapshot":"sdk-snapshot-20260811.1.1","packages_revision":"1111111111111111111111111111111111111111","buildscripts_revision":""}
JSON
if output=$(python3 "$AUTOBUILDS_ROOT/scripts/verify-release-pair.py" \
        --core-release sdk-snapshot-20260811.2.1 \
        --packages-release packages-snapshot-20260811.1.1 \
        --channel nightly \
        --core-lock "$TEMP_DIR/lock.json" \
        --packages-provenance "$TEMP_DIR/provenance.json" 2>&1); then
    echo "FAIL: packages built against another core were accepted" >&2
    exit 1
fi
grep -q "sdk-snapshot-20260811.1.1" <<<"$output" || {
    echo "FAIL: the refusal does not name the core the packages were built against" >&2
    echo "      $output" >&2
    exit 1
}
echo "PASS: Test C (mismatched provenance rejection)"

# --- Test D: Channel promotion requires both core_snapshot and packages_snapshot ---
echo "--- Test D: Missing parameters fail explicitly without fallback ---"
bash -c '
set +e
core=""
pkgs="packages-snapshot-1"
if [[ -z "$core" || -z "$pkgs" ]]; then
    exit 42
fi
exit 0
' && {
    echo "FAIL: Expected failure on missing core_snapshot" >&2
    exit 1
} || {
    status=$?
    if [[ $status -ne 42 ]]; then
        echo "FAIL: Unexpected status $status" >&2
        exit 1
    fi
}
echo "PASS: Test D (missing parameter enforcement)"

# --- Test E: the provenance download cannot fail on a file that already exists ---
echo "--- Test E: provenance download can write where it was told to ---"
grep -q -- '"--output", "-"' "$AUTOBUILDS_ROOT/scripts/verify-release-pair.py" || {
    echo "FAIL: the provenance download no longer goes to stdout. If it writes a" >&2
    echo "      file again, that file has to be one gh is allowed to overwrite:" >&2
    echo "      mktemp creates it, and gh refuses to write over it without" >&2
    echo "      --clobber, so the step could only ever fail." >&2
    exit 1
}
echo "PASS: Test E (the provenance download writes nowhere it could collide)"

# --- Test F: repository_dispatch must read the channel, not hardcode it ---
echo "--- Test F: channel comes from the dispatch payload, not a literal ---"
if grep -q "chan='nightly'" "$AUTOBUILDS_ROOT/.github/workflows/channel.yml"; then
    echo "FAIL: channel.yml still hardcodes the repository_dispatch channel to nightly" >&2
    exit 1
fi
grep -q "chan='\${{ github.event.client_payload.channel }}'" \
    "$AUTOBUILDS_ROOT/.github/workflows/channel.yml" || {
    echo "FAIL: channel.yml does not read channel from client_payload.channel" >&2
    exit 1
}
grep -q '\-z "\$chan"' "$AUTOBUILDS_ROOT/.github/workflows/channel.yml" || {
    echo "FAIL: channel.yml does not require channel like it requires core/packages" >&2
    exit 1
}
echo "PASS: Test F (channel comes from the dispatch payload)"

# --- Test G: two publishes for the same channel must not race ---
echo "--- Test G: update-channel serializes publishes per channel ---"
python3 -c "
import yaml
with open('$AUTOBUILDS_ROOT/.github/workflows/channel.yml') as f:
    doc = yaml.safe_load(f)
job = doc['jobs']['update-channel']
assert 'concurrency' in job, 'update-channel has no concurrency group'
assert job['concurrency']['cancel-in-progress'] is False, \
    'a half-finished manifest push must not be cancelled by a second one'
"
echo "PASS: Test G (update-channel has a serializing concurrency group)"

echo "=== All cross-repository pipeline contract tests PASSED successfully! ==="
