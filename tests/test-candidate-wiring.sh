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

# The guard is a question only the channels that move on their own have: a
# series has a commit, not a candidate. Asked by the flag the entry carries
# rather than by name, so a second automatic channel is covered by existing.
condition = str(steps[guard].get("if", ""))
if "matrix.entry.automatic" not in condition:
    print("the candidate check no longer limits itself to automatic channels")
if "nightly" in condition:
    print("the candidate check singles out a channel by name again")

for step, name in zip(steps[guard + 1:], names[guard + 1:]):
    if "steps.candidate.outputs.stale" not in str(step.get("if", "")):
        print(f"step {name!r} runs even when the candidate check rejected the pair")

# Both ways an entry is built have to say whether it is automatic. Absent,
# the flag reads as false and the guard silently stops running -- for the
# dispatch path, which is the only way an automatic channel is ever published.
resolve = next(
    (step
     for job in channel["jobs"].values()
     for step in job.get("steps", [])
     if step.get("id") == "resolve"),
    None)
if resolve is None:
    print("channel.yml no longer resolves its entries in a step called 'resolve'")
else:
    script = str(resolve.get("run", ""))
    if "automatic: false" not in script:
        print("the committed-pair path does not say its entries are not automatic")
    if "--automatic" not in script:
        print("the dispatch path does not ask whether the channel is automatic")
    # Both halves: the answer has to be given to jq and used by it.
    if "--argjson automatic" not in script:
        print("the dispatched entry is built without being given the answer")
    if "automatic: $automatic" not in script:
        print("the dispatched entry does not carry the answer it asked for")

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

# A patch is the one release whose version a person types, and it was the one
# the guard did not cover: it stopped at a declared version, because the only
# previous version it had was the world's last candidate, and every nightly
# sorts below every stable. The series' own version is the comparison that
# means something, and it is readable from channels.json.
if guard is not None:
    script = str(prepare[guard].get("run", ""))
    if "--serving" not in script:
        print("the version guard does not read what the series serves, so a patch's version is compared against nothing")
    # Once for the declared version, once for the derived one: a guard that
    # compares only one of them is the guard that was already there.
    if script.count("--previous-version") < 2:
        print("only one of the two kinds of version is compared against a previous one")
    if str(prepare[guard].get("env", {})).find("outputs.series") < 0:
        print("the version guard is not told which series this revision declares")

# Being refused the candidacy is a decision, not a failure. One input builds
# once: the second run of it is told so by the state branch, and has to turn
# that into "nothing to build" rather than into a red run -- or into a build
# that repeats the one already under way.
if record is not None:
    script = str(record.get("run", ""))
    if "--run" not in script:
        print("the candidate is recorded without naming the run building it, so a later one cannot ask whether it still is")
    if "held=true" not in script:
        print("the candidate step cannot report that another run is already building this input")
    if "take-over" not in script:
        print("an input whose holder died would stay held, and never build again")

outputs = build["jobs"]["prepare"].get("outputs") or {}
duplicate = str(outputs.get("duplicate", ""))
for source, reason in (
        ("steps.dedup.outputs.duplicate", "an input that is already published"),
        ("steps.candidate.outputs.held", "an input another run is already building")):
    if source not in duplicate:
        print(f"the prepare job's duplicate output ignores {reason}")
PYEOF
)

if (( failures )); then
	printf '%d candidate wiring check(s) failed\n' "$failures" >&2
	exit 1
fi

printf 'candidate wiring tests passed\n'
