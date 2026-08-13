#!/usr/bin/env python3
"""Publishes which release series exist and what state each one is in.

Without this a release is undiscoverable: you would have to be told its name
by somebody before you could ask for it, and a series that has ended has no
way of telling the people on it. Ubuntu publishes the same thing as
meta-release, and for the same reasons.

The status of a series is a decision, not something to derive, so the source
of truth is a file in this repository that a maintainer edits. This turns it
into the canonical form the client parses, and signs it with the same key as
the manifests, because it decides where people are told they may move to.
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys
import tempfile

CHANNEL_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")

# What a series can be. A release that has ended still installs exactly as it
# did; the point of saying so is that nobody discovers it by accident.
STATUSES = ("development", "supported", "deprecated", "end-of-life")


def canonical(document):
    """The exact serialization the client accepts: sorted keys, no spaces."""

    return json.dumps(document, sort_keys=True, separators=(",", ":")) + "\n"


def build_index(source):
    channels = {}
    for name, entry in source.items():
        if not CHANNEL_NAME.match(name) or ".." in name:
            raise SystemExit(f"ERROR: invalid channel name: {name!r}")
        status = entry.get("status", "")
        if status not in STATUSES:
            raise SystemExit(
                f"ERROR: {name}: status must be one of {', '.join(STATUSES)}, "
                f"not {status!r}")
        channels[name] = {"status": status, "summary": entry.get("summary", "")}
    if not channels:
        raise SystemExit("ERROR: the index would list no series at all")
    return {"schema_version": 1, "channels": channels}


def sign(path, key, output):
    subprocess.run(
        ["openssl", "pkeyutl", "-sign", "-rawin", "-inkey", str(key),
         "-in", str(path), "-out", str(output)],
        check=True)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--source", default="channels.json",
                        help="the series and their status, edited by hand")
    parser.add_argument("--key", help="Ed25519 private key in PEM format")
    parser.add_argument("--output-dir", default="channels")
    arguments = parser.parse_args(argv[1:])

    source = json.loads(pathlib.Path(arguments.source).read_text())
    index = build_index(source)

    output_dir = pathlib.Path(arguments.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    path = output_dir / "index.json"
    path.write_text(canonical(index))
    print(f"Wrote {path} listing {len(index['channels'])} series")

    if arguments.key:
        sign(path, arguments.key, output_dir / "index.json.sig")
        print(f"Signed {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
