#!/usr/bin/env python3
"""Which series a commit repoints, and whether the entries make sense.

A release is a human decision, and the auditable form of one is a commit:
channels.json says which exact pair each series serves, and moving a series
is an edit to it. That makes the promotion reviewable before it happens
rather than a dispatch somebody typed, and it makes the current pointer
readable without asking a workflow what it did last.

nightly is deliberately not in here. It moves on its own, several times a
day, and storing its pair would mean a bot commit per build; its pair lives
in the signed manifest and in the state branch. What nightly keeps here is
its name and status, for the index.
"""

import argparse
import json
import pathlib
import sys

# What a series serves: an exact core and an exact package set. The world is
# not part of it -- it says what the channel is, like its status does, and an
# automatic channel declares one without pinning anything.
PAIR = ("core", "packages")
POINTER = PAIR + ("world",)
# Channels whose pair is not written down: they follow whatever the builder
# published last, so it arrives by dispatch and lives in the signed manifest.
# One per world, because a channel serves exactly one.
AUTOMATIC = ("nightly", "nightly-softfp")


class PromotionError(Exception):
    pass


def read(path):
    if path is None:
        return {}
    text = pathlib.Path(path).read_text(encoding="utf-8")
    if not text.strip():
        return {}
    document = json.loads(text)
    if not isinstance(document, dict):
        raise PromotionError(f"{path} is not an object of series")
    return document


def pointer_of(name, entry):
    """The pair a series serves, or None when it has none at all."""
    if not isinstance(entry, dict):
        raise PromotionError(f"{name} is not an object")
    present = [field for field in PAIR if entry.get(field)]
    if not present:
        return None
    if name in AUTOMATIC:
        raise PromotionError(
            f"{name} moves on its own and its pair lives in the signed "
            f"manifest; remove {', '.join(present)} from it")
    missing = [field for field in POINTER if not entry.get(field)]
    if missing:
        raise PromotionError(
            f"{name} names {', '.join(present)} but not {', '.join(missing)}: "
            "a series serves an exact pair or none at all")
    return {field: entry[field] for field in POINTER}


def promotions(before, after):
    """Every series whose pair this change moved, in file order."""
    moved = []
    for name, entry in after.items():
        new = pointer_of(name, entry)
        old = pointer_of(name, before.get(name, {}))
        if new is None:
            if old is not None:
                raise PromotionError(
                    f"{name} used to serve {old['core']} and now serves "
                    "nothing; a series keeps its pair until it is deleted")
            continue
        if new != old:
            moved.append({"name": name, **new})
    return moved


def serving(channels, name):
    """The pair a series serves right now, or None when it serves nothing."""
    if name in AUTOMATIC:
        raise PromotionError(
            f"{name} moves on its own; its pair lives in the signed manifest")
    entry = channels.get(name)
    if entry is None:
        return None
    return pointer_of(name, entry)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--before", help="channels.json as it was, omitted when there was none")
    parser.add_argument("--after", required=True, help="channels.json as it is now")
    parser.add_argument("--format", choices=("json", "lines"), default="json")
    parser.add_argument("--serving", metavar="SERIES",
                        help="Print what this series serves now and stop; "
                             "prints nothing when it serves nothing yet")
    args = parser.parse_args(argv)

    if args.serving:
        try:
            pair = serving(read(args.after), args.serving)
        except (PromotionError, json.JSONDecodeError) as error:
            print(f"ERROR: {error}", file=sys.stderr)
            return 1
        if pair is not None:
            print(f"{pair['core']} {pair['packages']} {pair['world']}")
        return 0

    try:
        moved = promotions(read(args.before), read(args.after))
    except (PromotionError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1

    if args.format == "json":
        json.dump(moved, sys.stdout, sort_keys=True)
        print()
    else:
        for promotion in moved:
            print(f"{promotion['name']} {promotion['core']} "
                  f"{promotion['packages']} {promotion['world']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
