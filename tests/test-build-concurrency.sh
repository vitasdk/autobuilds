#!/usr/bin/env bash
# A build that was asked for must not be evicted by one that was not.
#
# A run held in an occupied concurrency group is cancelled, not delayed: only
# one run waits per group, and the next arrival replaces it. So two triggers
# sharing a group are two builds where one silently disappears -- which is
# what a group keyed on the branch did, because a repository_dispatch and a
# push to master both run on refs/heads/master. The group has to be the build,
# and the build is the lock's build_id.

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
import re
import sys

import yaml

directory = sys.argv[1]
workflow = yaml.safe_load(open(f"{directory}/.github/workflows/build.yml"))


# Enough of the expression language for a concurrency group: context lookups,
# string literals, ==, and the && / || pair Actions uses as a conditional.
# Actions returns operands, not booleans: `a && b || c` is b when a is truthy
# and c otherwise.
def evaluate(expression, context):
    tokens = re.findall(r"'[^']*'|\|\||&&|==|[A-Za-z0-9_.-]+", expression)
    position = 0

    def peek():
        return tokens[position] if position < len(tokens) else None

    def take():
        nonlocal position
        position += 1
        return tokens[position - 1]

    def primary():
        token = take()
        if token.startswith("'"):
            return token[1:-1]
        value = context
        for part in token.split("."):
            value = value.get(part, "") if isinstance(value, dict) else ""
        return value

    def comparison():
        left = primary()
        if peek() == "==":
            take()
            return left == primary()
        return left

    def conjunction():
        value = comparison()
        while peek() == "&&":
            take()
            right = comparison()
            value = right if value else value
        return value

    def disjunction():
        value = conjunction()
        while peek() == "||":
            take()
            right = conjunction()
            value = value if value else right
        return value

    return disjunction()


def group(template, context):
    return re.sub(
        r"\$\{\{(.+?)\}\}",
        lambda match: str(evaluate(match.group(1).strip(), context)),
        template,
    )


def context(**overrides):
    github = {
        "workflow": "Build SDK snapshots",
        "ref": "refs/heads/master",
        "event_name": "push",
        "run_id": "1",
    }
    github.update(overrides.pop("github", {}))
    return {"github": github, **overrides}


concurrency = workflow.get("concurrency")
if not concurrency:
    print("build.yml declares no concurrency group")
    sys.exit()

template = concurrency["group"]
announced = group(template, context(github={"event_name": "repository_dispatch", "run_id": "2"}))
pushed = group(template, context(github={"event_name": "push", "run_id": "3"}))
scheduled = group(template, context(github={"event_name": "schedule", "run_id": "4"}))

if announced == pushed:
    print("a push to this repository queues in the same group as an announced revision, and evicts it")
if announced == scheduled:
    print("the schedule backstop queues in the same group as an announced revision, and evicts it")

# A pull request is the one case where sharing a group is the point: the
# newest push to a branch should cancel the run it superseded.
first = group(template, context(github={"event_name": "pull_request", "ref": "refs/pull/7/merge", "run_id": "5"}))
second = group(template, context(github={"event_name": "pull_request", "ref": "refs/pull/7/merge", "run_id": "6"}))
other = group(template, context(github={"event_name": "pull_request", "ref": "refs/pull/8/merge", "run_id": "7"}))
if first != second:
    print("two runs of one pull request no longer share a group, so neither cancels the other")
if first == other:
    print("two different pull requests share a group")
if str(concurrency.get("cancel-in-progress", "")).find("pull_request") < 0:
    print("cancel-in-progress is no longer limited to pull requests")

# And the group the build does belong in, which prepare has named by then.
build = workflow["jobs"].get("build", {})
build_concurrency = build.get("concurrency")
if not build_concurrency:
    print("the build job declares no concurrency group, so one input can build twice at once")
    sys.exit()

template = build_concurrency["group"]
if "build_id" not in template:
    print("the build job's group is not the build_id")


def build_context(build_id, run_id, event_name="push"):
    return context(
        github={"run_id": run_id, "event_name": event_name},
        needs={"prepare": {"outputs": {"build_id": build_id}}},
    )


if group(template, build_context("abc", "1")) != group(template, build_context("abc", "2")):
    print("two runs of one input do not share a group, so the same build can run twice")
if group(template, build_context("abc", "1")) == group(template, build_context("def", "2")):
    print("two different inputs share the build job's group")
if build_concurrency.get("cancel-in-progress"):
    print("the build job cancels a build of its own input that is already running")

# A pull request's build_id is whatever buildscripts master holds, so keying
# it the same way puts every pull request in the queue of the master builds
# of that revision -- and a job held in an occupied group is cancelled, not
# delayed. That is how a candidate ended up with no run producing it.
pull_request = group(template, build_context("abc", "9", event_name="pull_request"))
if pull_request == group(template, build_context("abc", "1")):
    print("a pull request shares the build group of a master build of the same input, and evicts it")
if pull_request == group(template, build_context("abc", "8", event_name="pull_request")):
    print("two pull request runs share a build group, so one cancels the other's build")
PYEOF
)

if [[ $failures -gt 0 ]]; then
	printf '%s check(s) failed\n' "$failures" >&2
	exit 1
fi
printf 'build concurrency: all checks passed\n'
