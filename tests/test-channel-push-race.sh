#!/usr/bin/env bash
# Two channels that publish at the same moment both reach the Pages branch.
#
# nightly and nightly-softfp are announced together and push to one branch.
# The second push used to be rejected and the run failed, so that channel
# kept serving its previous snapshot until somebody ran it again by hand.

set -euo pipefail

directory=$(cd "$(dirname "$0")/.." && pwd -P)
push="$directory/scripts/push-channel.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

report()
{
	printf 'FAIL: %s\n' "$1" >&2
	failures=$((failures + 1))
}

git init --quiet --bare --initial-branch=master "$work/pages.git"

clone()
{
	git clone --quiet "$work/pages.git" "$work/$1" 2>/dev/null
	git -C "$work/$1" config user.name test
	git -C "$work/$1" config user.email test@example.invalid
}

clone seed
mkdir "$work/seed/channels"
echo 'index 0' > "$work/seed/channels/index.json"
"$push" "$work/seed" 'seed' >/dev/null

# Both check out the same commit, then each writes its own manifest and the
# index, which is signed and so differs between them.
clone first
clone second
echo 'nightly 1' > "$work/first/channels/nightly.json"
echo 'index from first' > "$work/first/channels/index.json"
echo 'softfp 1' > "$work/second/channels/nightly-softfp.json"
echo 'index from second' > "$work/second/channels/index.json"

"$push" "$work/first" 'channel: update nightly' >/dev/null ||
	report "the first channel did not push"
"$push" "$work/second" 'channel: update nightly-softfp' >/dev/null ||
	report "the second channel did not push after the first one had"

clone result
[[ $(cat "$work/result/channels/nightly.json" 2>/dev/null) == 'nightly 1' ]] ||
	report "the first channel's manifest is gone"
[[ $(cat "$work/result/channels/nightly-softfp.json" 2>/dev/null) == 'softfp 1' ]] ||
	report "the second channel's manifest never arrived"
[[ $(cat "$work/result/channels/index.json") == 'index from second' ]] ||
	report "the index is not the one the last channel published"
[[ $(git -C "$work/result" rev-list --count HEAD) == 3 ]] ||
	report "expected the seed and one commit per channel"

# Nothing changed: no commit, and no failure for having nothing to say.
before=$(git -C "$work/result" rev-parse HEAD)
"$push" "$work/result" 'channel: nothing' >/dev/null ||
	report "publishing nothing was treated as a failure"
[[ $(git -C "$work/result" rev-parse HEAD) == "$before" ]] ||
	report "an empty publication made a commit"

# A branch that can never be pushed to fails instead of looping.
clone stuck
echo 'x' > "$work/stuck/channels/x.json"
git -C "$work/stuck" remote set-url --push origin "$work/missing.git"
if PUSH_CHANNEL_ATTEMPTS=2 "$push" "$work/stuck" 'channel: stuck' >/dev/null 2>&1; then
	report "a push that cannot succeed was reported as done"
fi

# The workflow has to be the caller, or none of this is what runs.
grep -q 'scripts/push-channel.sh' "$directory/.github/workflows/channel.yml" ||
	report "channel.yml does not publish through scripts/push-channel.sh"
if grep -q 'git push origin master' "$directory/.github/workflows/channel.yml"; then
	report "channel.yml still pushes on its own, without the retry"
fi

if ((failures)); then
	exit 1
fi
echo "test-channel-push-race: ok"
