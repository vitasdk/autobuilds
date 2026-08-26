#!/usr/bin/env python3
"""Which build is the current candidate for a world, and who may move it.

Two builds can be in flight at once -- a push and the cron backstop, a
dispatch and a re-run -- and they finish in whatever order they finish. The
rule is latest-wins: the newest input becomes the candidate, and a result for
an older one must never move the channel afterwards. Deciding that needs a
pointer that several workflows read and write, and a pointer is mutable, so
it needs a real compare-and-swap rather than a file somebody overwrites.

It lives in a branch of this repository, one small document per world, and
every change is a commit pushed as a fast-forward. A rejected push *is* the
compare-and-swap failing: somebody else moved first, so re-read and decide
again from what is there now. No database, and the history of what was
current when is readable afterwards.
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile

BRANCH = "state"
SCHEMA = 1
ATTEMPTS = 5


class StateError(Exception):
    pass


class Stale(Exception):
    """A newer candidate exists, so this result no longer decides anything."""


def git(*arguments, cwd, check=True, capture=True):
    completed = subprocess.run(
        ["git", *arguments], cwd=cwd, text=True,
        capture_output=capture)
    if check and completed.returncode != 0:
        raise StateError(
            f"git {' '.join(arguments)}: {(completed.stderr or '').strip()}")
    return completed


def document_path(root, profile):
    return os.path.join(root, "state", f"{profile}.json")


def read_document(root, profile):
    path = document_path(root, profile)
    if not os.path.exists(path):
        return {"schema": SCHEMA, "profile": profile, "generation": 0,
                "candidate": None}
    with open(path, encoding="utf-8") as handle:
        document = json.load(handle)
    if document.get("schema") != SCHEMA:
        raise StateError(
            f"state/{profile}.json has schema {document.get('schema')}, "
            f"this tool speaks {SCHEMA}")
    return document


def write_document(root, profile, document, message):
    path = document_path(root, profile)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(document, handle, indent=2, sort_keys=True)
        handle.write("\n")
    git("add", path, cwd=root)
    if not git("diff", "--cached", "--quiet", cwd=root, check=False).returncode:
        return False
    git("-c", "user.name=autobuilds", "-c", "user.email=builds@ci.invalid",
        "commit", "--quiet", "-m", message, cwd=root)
    return True


def checkout(repository, root):
    """The state branch, or an empty tree when it does not exist yet."""
    git("init", "--quiet", "--initial-branch", BRANCH, root, cwd=None)
    git("remote", "add", "origin", repository, cwd=root)
    fetched = git("fetch", "--quiet", "--depth", "1", "origin", BRANCH,
                  cwd=root, check=False)
    if fetched.returncode == 0:
        git("checkout", "--quiet", "-B", BRANCH, "FETCH_HEAD", cwd=root)
        return True
    return False


def push(root):
    """Fast-forward only: a rejection is somebody else having moved first."""
    pushed = git("push", "--quiet", "origin", f"HEAD:refs/heads/{BRANCH}",
                 cwd=root, check=False)
    return pushed.returncode == 0


def mutate(repository, profile, change, message):
    """Read, decide, commit, push -- and start over if the push is rejected."""
    for attempt in range(ATTEMPTS):
        root = tempfile.mkdtemp(prefix="autobuilds-state-")
        checkout(repository, root)
        document = read_document(root, profile)
        result = change(document)
        if not write_document(root, profile, document, message):
            return result
        if push(root):
            return result
        print(f"state: somebody moved first, re-reading (attempt {attempt + 1})",
              file=sys.stderr)
    raise StateError(
        f"gave up after {ATTEMPTS} attempts: {profile} is being written to "
        "faster than this can read it")


def command_read(args):
    root = tempfile.mkdtemp(prefix="autobuilds-state-")
    checkout(args.repository, root)
    document = read_document(root, args.profile)
    if args.field:
        candidate = document.get("candidate") or {}
        value = document.get(args.field, candidate.get(args.field, ""))
        print("" if value is None else value)
    else:
        json.dump(document, sys.stdout, indent=2, sort_keys=True)
        print()


def command_record(args):
    def change(document):
        document["generation"] = int(document.get("generation", 0)) + 1
        document["candidate"] = {
            "build_id": args.build_id,
            "version": args.version,
            "core_snapshot": None,
            "status": "building",
        }
        return document["generation"]

    generation = mutate(args.repository, args.profile, change,
                        f"{args.profile}: candidate {args.build_id}")
    print(generation)


def command_publish(args):
    def change(document):
        if int(document.get("generation", 0)) != args.generation:
            raise Stale(
                f"generation is {document.get('generation')}, this build holds "
                f"{args.generation}: a newer candidate exists")
        candidate = document.get("candidate") or {}
        candidate["core_snapshot"] = args.core_snapshot
        candidate["status"] = "packages_building"
        document["candidate"] = candidate
        return None

    mutate(args.repository, args.profile, change,
           f"{args.profile}: {args.core_snapshot} published")


def command_promote(args):
    def change(document):
        candidate = document.get("candidate")
        # Nothing has ever claimed this pointer, which is what every world
        # looks like until its first build records one -- and what a core
        # published before any of this existed looks like forever. There is
        # nothing to be older than, so the channel moves.
        if not candidate:
            print(f"no candidate recorded for {args.profile}; nothing to compare",
                  file=sys.stderr)
            return None
        if candidate.get("core_snapshot") != args.core_snapshot:
            raise Stale(
                f"the candidate is {candidate.get('core_snapshot')}, this "
                f"result is for {args.core_snapshot}")
        candidate["status"] = "promoted"
        document["candidate"] = candidate
        return None

    mutate(args.repository, args.profile, change,
           f"{args.profile}: {args.core_snapshot} promoted")


def main(argv):
    parser = argparse.ArgumentParser(prog="state", description=__doc__.splitlines()[0])
    parser.add_argument("--repository", default=os.environ.get(
        "STATE_REPOSITORY", "."), help="Repository holding the state branch")
    parser.add_argument("--profile", required=True)
    subcommands = parser.add_subparsers(dest="command", required=True)

    read = subcommands.add_parser("read", help="Print the document, or one field of it")
    read.add_argument("--field", help="version, build_id, core_snapshot, generation, status")
    read.set_defaults(handler=command_read)

    record = subcommands.add_parser("record", help="Make this input the candidate")
    record.add_argument("--build-id", required=True)
    record.add_argument("--version", required=True)
    record.set_defaults(handler=command_record)

    publish = subcommands.add_parser("publish", help="Name the snapshot this candidate became")
    publish.add_argument("--generation", required=True, type=int)
    publish.add_argument("--core-snapshot", required=True)
    publish.set_defaults(handler=command_publish)

    promote = subcommands.add_parser("promote", help="Mark this candidate as the one that moved the channel")
    promote.add_argument("--core-snapshot", required=True)
    promote.set_defaults(handler=command_promote)

    args = parser.parse_args(argv)
    try:
        args.handler(args)
    except Stale as stale:
        print(f"stale: {stale}", file=sys.stderr)
        return 3
    except StateError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
