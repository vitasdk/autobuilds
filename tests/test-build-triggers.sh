#!/usr/bin/env bash
# What a build is of -- which revision, which world -- comes from whoever
# asked for it, and a dispatch cannot write anything else into the run.

set -euo pipefail

directory=$(cd "$(dirname "$0")/.." && pwd -P)
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

# The step that reads the trigger, run exactly as Actions runs it.
python3 - "$workflow" "$work" <<'PYEOF'
import sys, yaml
workflow, work = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(open(workflow))
steps = doc["jobs"]["prepare"]["steps"]
step = next((s for s in steps if s.get("id") == "ref"), None)
if step is None:
    sys.exit("the prepare job no longer has a step with id 'ref'")
open(f"{work}/ref-step.sh", "w").write(step["run"])
open(f"{work}/default-profile", "w").write(doc["env"]["DEFAULT_PROFILE"])
PYEOF

default_profile=$(cat "$work/default-profile")

run_ref_step() {
	local output="$work/output"
	: > "$output"
	env -i PATH="$PATH" HOME="$HOME" \
		GITHUB_OUTPUT="$output" \
		DEFAULT_PROFILE="$default_profile" \
		REQUESTED_REF="${1-}" REQUESTED_PROFILE="${2-}" \
		bash "$work/ref-step.sh" > "$work/stdout" 2>&1
}

output_value() {
	sed -n "s/^$1=//p" "$work/output"
}

run_ref_step "" ""
check "an unasked build takes the development branch" \
	[ "$(output_value ref)" = "master" ]
check "an unasked build takes the policy default world" \
	[ "$(output_value profile)" = "$default_profile" ]

run_ref_step "8c1e5f9d2b" "vita_softfp"
check "a trigger that names a revision is obeyed" \
	[ "$(output_value ref)" = "8c1e5f9d2b" ]
check "a trigger that names a world is obeyed" \
	[ "$(output_value profile)" = "vita_softfp" ]

# An output of this step decides whether the build runs at all, so a
# payload that carries a newline must not get to write a second one.
if run_ref_step "master" "vita
duplicate=true"; then
	printf 'FAIL: a profile carrying a newline was accepted\n' >&2
	failures=$((failures + 1))
else
	printf 'PASS: a profile carrying a newline is refused\n'
fi
check "the refused profile wrote no output" \
	[ -z "$(output_value duplicate)" ]

if run_ref_step "master
duplicate=true" ""; then
	printf 'FAIL: a ref carrying a newline was accepted\n' >&2
	failures=$((failures + 1))
else
	printf 'PASS: a ref carrying a newline is refused\n'
fi
check "the refused ref wrote no output" \
	[ -z "$(output_value duplicate)" ]

# The triggers themselves: an announcement from buildscripts, and a
# schedule for the announcement that never arrives.
python3 - "$workflow" <<'PYEOF'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
# YAML reads a bare `on` as the boolean True.
triggers = doc.get("on", doc.get(True))
missing = [name for name in ("schedule", "repository_dispatch", "workflow_dispatch")
           if name not in triggers]
if missing:
    sys.exit("build.yml declares no " + ", ".join(missing))
if "run_build" not in triggers["repository_dispatch"]["types"]:
    sys.exit("build.yml does not listen for the run_build announcement")
if not triggers["schedule"]:
    sys.exit("build.yml declares an empty schedule")
inputs = triggers["workflow_dispatch"]["inputs"]
for name in ("buildscripts_ref", "profile"):
    if name not in inputs:
        sys.exit(f"a manual run cannot name {name}")
PYEOF
printf 'PASS: the triggers are declared\n'

if [[ $failures -gt 0 ]]; then
	printf '%s check(s) failed\n' "$failures" >&2
	exit 1
fi
printf 'build triggers: all checks passed\n'
