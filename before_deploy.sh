#!/bin/bash

git config --global user.email "builds@travis-ci.com"
git config --global user.name "Travis CI"

if [ "$TOXENV" == "WIN" ]; then
	BUILDTYPE="win"
else
	BUILDTYPE=$TRAVIS_OS_NAME
fi

export GIT_TAG=$TRAVIS_BRANCH-$BUILDTYPE-v$TRAVIS_BUILD_NUMBER

echo $GIT_TAG
git tag $GIT_TAG -a -m "Generated tag from TravisCI for build $TRAVIS_BUILD_NUMBER"
git push -q https://$TAGPERM@github.com/$TRAVIS_REPO_SLUG --tags
