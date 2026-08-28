#!/usr/bin/env bash

# The world a channel serves has to reach every script that decides what it
# serves.
#
# It is carried as far as the matrix entry and then read by hand from there,
# once per script, and forgetting one is silent: the generator has a default,
# so a manifest missing --world publishes a channel that names the first
# world's core and the first world's database no matter which world it is for.
# That is one world's libraries against another world's ABI, and nothing
# downstream can tell.

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

import glob, os

directory = sys.argv[1]
channel = yaml.safe_load(open(f"{directory}/.github/workflows/channel.yml"))

# Every script that takes a --world must be given one, wherever it is run
# from. Reading only the workflow that publishes would say nothing about the
# next one somebody adds.
wants_world = ("generate-channel-manifest.py", "verify-release-pair.py")
seen = set()
for path in sorted(glob.glob(f"{directory}/.github/workflows/*.yml")):
    workflow = yaml.safe_load(open(path))
    where = os.path.basename(path)
    for job in (workflow.get("jobs") or {}).values():
        for step in job.get("steps", []):
            run = str(step.get("run", ""))
            for script in wants_world:
                if script not in run:
                    continue
                seen.add(script)
                if "--world" not in run:
                    print(f"{where} runs {script} without --world")
                elif "--world ''" in run or '--world ""' in run:
                    print(f"{where} runs {script} with an empty world")

for script in wants_world:
    if script not in seen:
        print(f"{script} is no longer run anywhere; this test needs updating")

# And in the publishing job specifically, the world has to be the entry's own
# rather than any value that happens to be in scope.
for job in channel["jobs"].values():
    for step in job.get("steps", []):
        run = str(step.get("run", ""))
        if "generate-channel-manifest.py" in run and "matrix.entry.world" not in run:
            print("the manifest is generated with a world that is not the entry's")

# And the entry has to carry one in the first place.
resolve = None
for job in channel["jobs"].values():
    for step in job.get("steps", []):
        if step.get("id") == "resolve":
            resolve = step
if resolve is None:
    print("channel.yml no longer resolves its entries in a step called 'resolve'")
else:
    script = str(resolve.get("run", ""))
    # Where the value comes from: an environment the step declares, not a
    # variable that happens to be named in its text.
    if "WORLD" not in (resolve.get("env") or {}):
        print("the resolve step is never given the world it was dispatched")
    # And where it goes: into the entry, and used there.
    if 'world: ""' in script or "world: ''" in script:
        print("the resolved entry hard-codes an empty world")
    if "--arg world" not in script:
        print("the resolved entry is built without being given a world")
    if "world: $world" not in script:
        print("the resolved entry does not carry the world it was given")
PYEOF
)

if (( failures )); then
	printf '%d wiring check(s) failed\n' "$failures" >&2
	exit 1
fi
printf 'the world reaches every script that needs it\n'
