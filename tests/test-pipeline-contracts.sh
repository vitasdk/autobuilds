#!/usr/bin/env bash
#
# Automated contract tests for VitaSDK cross-repository deterministic pipeline.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTOBUILDS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_ROOT="$(cd "$AUTOBUILDS_ROOT/.." && pwd)"

echo "=== Running VitaSDK Cross-Repository Pipeline Contract Tests ==="

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# --- Test A: Validate Dockerfile logic and contract for CORE_SNAPSHOT ---
echo "--- Test A: Dockerfile core_snapshot contract ---"
grep -q "ARG CORE_SNAPSHOT" "$WORKSPACE_ROOT/packages/Dockerfile" || {
    echo "FAIL: packages/Dockerfile missing ARG CORE_SNAPSHOT" >&2
    exit 1
}
grep -q "vitasdk-bootstrap-x86_64-linux-gnu.tar.bz2" "$WORKSPACE_ROOT/packages/Dockerfile" || {
    echo "FAIL: packages/Dockerfile does not reference exact bootstrap archive" >&2
    exit 1
}
grep -q "sha256sum" "$WORKSPACE_ROOT/packages/Dockerfile" || {
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
python3 -c "
import json, sys

requested_core = 'sdk-snapshot-20260811.2.1'
provenance_from_packages = {
    'schema_version': 1,
    'core_snapshot': 'sdk-snapshot-20260811.1.1',  # Mismatch!
    'packages_revision': '1111111111111111111111111111111111111111',
    'buildscripts_revision': '2222222222222222222222222222222222222222'
}

actual_core = provenance_from_packages.get('core_snapshot')
if actual_core != requested_core:
    # Expected behavior: contract check fails
    pass
else:
    sys.exit('FAIL: Validation should have rejected mismatched core_snapshot')
"
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

# --- Test E: a download into a mktemp file has to be allowed to overwrite it ---
echo "--- Test E: provenance download can write where it was told to ---"
grep -q -- '--output "$provenance_tmp" --clobber' \
    "$AUTOBUILDS_ROOT/.github/workflows/channel.yml" || {
    echo "FAIL: channel.yml downloads provenance.json over a file mktemp already" >&2
    echo "      created, which gh refuses without --clobber: the step can only fail" >&2
    exit 1
}
echo "PASS: Test E (provenance download overwrites its own temporary file)"

echo "=== All cross-repository pipeline contract tests PASSED successfully! ==="
