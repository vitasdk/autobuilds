#!/usr/bin/env python3
"""Do this core and this package set belong to the same series?

A manifest points a channel at two releases, and the only thing compared so
far was the package set's own claim about which core it was built against.
Nothing opened the core. So a tag typed by hand could name a release that
does not exist, or one that belongs to another line: publishing a patch of
2026.08 to nightly moves every nightly user onto the target runtime of a
series they are not on, and publishing a nightly core to 2026.08 does the
same to the people who chose a series precisely so it would not move.

The core's lock says which series it belongs to -- null for a build whose
version is derived from history, which is what nightly is. That is the field
this reads, and the rule is symmetric: nightly takes cores with no series,
and a series channel takes only its own. A channel named anything else is
refused rather than guessed at.
"""

import argparse
import json
import subprocess
import sys


def read_release_file(repository, release, name, local_path):
    """The named JSON asset of a release, or a local copy of it."""
    if local_path:
        with open(local_path, encoding="utf-8") as handle:
            return json.load(handle)
    completed = subprocess.run(
        ["gh", "release", "download", release, "--repo", repository,
         "--pattern", name, "--output", "-"],
        capture_output=True, text=True)
    if completed.returncode != 0:
        raise SystemExit(
            f"ERROR: cannot read {name} from {repository} release {release!r}: "
            f"{completed.stderr.strip()}")
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise SystemExit(
            f"ERROR: {name} in {repository} release {release!r} is not JSON: {error}")


def check_series(lock, channel, core_release):
    """The core belongs to the line the channel is."""
    series = lock.get("series")
    version = lock.get("version", "?")
    if channel == "nightly":
        if series is not None:
            raise SystemExit(
                f"ERROR: {core_release} is version {version} of series {series}, "
                "and nightly is the channel for builds that belong to no series. "
                f"Publishing it here would move every nightly user onto {series}.")
        return
    if series is None:
        raise SystemExit(
            f"ERROR: {core_release} is version {version}, which belongs to no "
            f"series, and channel {channel!r} is one. A series may only be "
            "pointed at a core that declares it.")
    if series != channel:
        raise SystemExit(
            f"ERROR: {core_release} belongs to series {series}, not to "
            f"{channel!r}.")


def check_provenance(provenance, core_release, packages_release):
    built_against = provenance.get("core_snapshot", "")
    if built_against != core_release:
        raise SystemExit(
            f"ERROR: packages release {packages_release!r} was built against "
            f"{built_against or '<nothing recorded>'}, but this channel would "
            f"offer it beside {core_release!r}.")


def check_world(lock, world, core_release):
    """The pair belongs to the world the series is of.

    Two worlds are built from the same sources with different target ABIs, so
    a core of the wrong one installs and then miscompiles everything it
    touches. The lock says which one it was built as.
    """
    if not world:
        return
    profile = lock.get("profile")
    if profile != world:
        raise SystemExit(
            f"ERROR: {core_release} was built as the {profile!r} world, and "
            f"this channel serves {world!r}.")


def check_buildscripts_revision(lock, provenance, expected):
    """Both halves name the same buildscripts revision, when they name one.

    The packages side records an empty string today, so this is a check that
    holds when there is something to hold, and says so when there is not.
    """
    core_revision = lock.get("buildscripts_revision", "")
    packages_revision = provenance.get("buildscripts_revision", "")
    if packages_revision and packages_revision != core_revision:
        raise SystemExit(
            f"ERROR: the core was built from buildscripts {core_revision}, the "
            f"packages from {packages_revision}.")
    for name, revision in (("core", core_revision), ("packages", packages_revision)):
        if expected and revision and revision != expected:
            raise SystemExit(
                f"ERROR: the {name} names buildscripts {revision}, not the "
                f"{expected} this publish asked for.")
    if not packages_revision:
        print("note: the packages release records no buildscripts revision")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--core-release", required=True)
    parser.add_argument("--core-repository", default="vitasdk/autobuilds")
    parser.add_argument("--packages-release", required=True)
    parser.add_argument("--packages-repository", default="vitasdk/packages")
    parser.add_argument("--channel", required=True)
    parser.add_argument("--world", default="",
                        help="World the channel serves; the core must be of it")
    parser.add_argument("--buildscripts-sha", default="",
                        help="Exact buildscripts commit both halves must name")
    parser.add_argument("--core-lock", help="Local lock.json, instead of downloading it")
    parser.add_argument("--packages-provenance",
                        help="Local provenance.json, instead of downloading it")
    args = parser.parse_args()

    lock = read_release_file(args.core_repository, args.core_release,
                             "lock.json", args.core_lock)
    provenance = read_release_file(args.packages_repository, args.packages_release,
                                   "provenance.json", args.packages_provenance)

    check_provenance(provenance, args.core_release, args.packages_release)
    check_series(lock, args.channel, args.core_release)
    check_world(lock, args.world, args.core_release)
    check_buildscripts_revision(lock, provenance, args.buildscripts_sha)

    print(f"{args.channel}: core {args.core_release} (version "
          f"{lock.get('version', '?')}, series {lock.get('series')}) and packages "
          f"{args.packages_release} are the same release")


if __name__ == "__main__":
    main()
