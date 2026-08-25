#!/usr/bin/env python3
"""Answers whether a build input already has a published snapshot."""

import argparse
import json
import re
import sys

# Only a line of its own counts: a build_id quoted in prose, or in a note
# about some other snapshot, must never pass for the record of this one.
MARKER = re.compile(r"^build_id:[ \t]*(\S+)[ \t]*$", re.MULTILINE)


class LookupError_(Exception):
    pass


def find_snapshot(releases, build_id):
    if not isinstance(releases, list):
        raise LookupError_("the release listing is not a JSON array")
    for release in releases:
        if not isinstance(release, dict):
            raise LookupError_(f"the release listing holds a {type(release).__name__}")
        # A draft is a snapshot that was never published: whoever was
        # uploading it may have died halfway, so it proves nothing.
        if release.get("draft"):
            continue
        match = MARKER.search(release.get("body") or "")
        if match and match.group(1) == build_id:
            tag = release.get("tag_name")
            if not tag:
                raise LookupError_(f"a release recording {build_id} has no tag")
            return tag
    return None


def main(argv):
    parser = argparse.ArgumentParser(prog="find-built-snapshot")
    parser.add_argument("--build-id", required=True)
    parser.add_argument("--releases", default="-", help="GitHub release listing, or - for stdin")
    args = parser.parse_args(argv)

    try:
        if args.releases == "-":
            releases = json.load(sys.stdin)
        else:
            with open(args.releases, encoding="utf-8") as handle:
                releases = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"find-built-snapshot: {args.releases} is not readable JSON: {exc}", file=sys.stderr)
        return 1

    try:
        tag = find_snapshot(releases, args.build_id)
    except LookupError_ as exc:
        print(f"find-built-snapshot: {exc}", file=sys.stderr)
        return 1

    if tag:
        print(tag)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
