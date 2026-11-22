#!/usr/bin/env bash
# Commits channels/ in a checkout of the Pages repository and pushes it.
#
# Two channels that move together push to the same branch, and the second
# push is rejected. Its commit is replayed on what the first one published
# and pushed again; where both wrote a file, such as the index, this one's
# copy stands.
#
# usage: push-channel.sh <checkout> <commit message> [branch]

set -euo pipefail

checkout=$1
message=$2
branch=${3:-master}
attempts=${PUSH_CHANNEL_ATTEMPTS:-5}

cd "$checkout"
git add channels/
if git diff --cached --quiet; then
	echo "channels/ is already what the branch serves"
	exit 0
fi
git commit --quiet -m "$message"

for attempt in $(seq 1 "$attempts"); do
	if git push --quiet origin "HEAD:$branch"; then
		echo "pushed on attempt $attempt"
		exit 0
	fi
	echo "::notice::push rejected on attempt $attempt; replaying on what was published meanwhile"
	# In a rebase "theirs" is the commit being replayed, which is this one.
	git pull --quiet --rebase -X theirs origin "$branch"
done

echo "::error::could not push $message after $attempts attempts" >&2
exit 1
