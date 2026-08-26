#!/usr/bin/env bash
# Nothing may publish a channel past the candidate check.
#
# The check makes a whole run into a no-op when the pair it was handed is no
# longer the current candidate, and it does that by every later step asking
# whether it should run. A step added below it without that question would
# publish for a pair the check just rejected, and the run would be green.

set -euo pipefail

directory=$(cd "$(dirname "$0")/.." && pwd -P)
failures=0

report()
{
	printf 'FAIL: %s\n' "$1" >&2
	failures=$((failures + 1))
}

while IFS= read -r problem; do
	report "$problem"
done < <(python3 - "$directory" <<'PYEOF'
import sys, yaml

directory = sys.argv[1]
channel = yaml.safe_load(open(f"{directory}/.github/workflows/channel.yml"))
steps = channel["jobs"]["update-channel"]["steps"]

names = [step.get("name") or step.get("uses") or step.get("id") for step in steps]
guard = next((i for i, step in enumerate(steps) if step.get("id") == "candidate"), None)
if guard is None:
    print("update-channel has no step with id 'candidate'")
    sys.exit()

# The guard itself is nightly's question: a series has a commit, not a candidate.
if "nightly" not in str(steps[guard].get("if", "")):
    print("the candidate check no longer limits itself to nightly")

for step, name in zip(steps[guard + 1:], names[guard + 1:]):
    if "steps.candidate.outputs.stale" not in str(step.get("if", "")):
        print(f"step {name!r} runs even when the candidate check rejected the pair")

build = yaml.safe_load(open(f"{directory}/.github/workflows/build.yml"))
prepare = build["jobs"]["prepare"]["steps"]
record = next((s for s in prepare if s.get("id") == "candidate"), None)
if record is None:
    print("the prepare job no longer records a candidate")
else:
    condition = str(record.get("if", ""))
    for required in ("refs/heads/master", "pull_request", "duplicate"):
        if required not in condition:
            print(f"the candidate is recorded without checking {required}")
    permissions = build["jobs"]["prepare"].get("permissions") or {}
    if permissions.get("contents") != "write":
        print("the prepare job cannot push the candidate it records")

# The version guard has to come after the deduplication: an input that was
# already built answers with the version it answered with last time, so asked
# first, the six-hourly backstop on an untouched master refuses itself instead
# of stopping at "already published".
def index_of(steps, predicate, description):
    for position, step in enumerate(steps):
        if predicate(step):
            return position
    print(f"the prepare job has no {description}")
    return None

dedup = index_of(prepare, lambda s: s.get("id") == "dedup", "deduplication step")
guard = index_of(prepare, lambda s: "backwards" in (s.get("name") or ""), "version guard")
made = index_of(prepare, lambda s: s.get("id") == "candidate", "candidate step")
if None not in (dedup, guard, made):
    if guard < dedup:
        print("the version guard runs before the deduplication that would stop it")
    if made < guard:
        print("the candidate is recorded before its version is checked")
PYEOF
)

if (( failures )); then
	printf '%d candidate wiring check(s) failed\n' "$failures" >&2
	exit 1
fi

printf 'candidate wiring tests passed\n'
