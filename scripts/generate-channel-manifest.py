#!/usr/bin/env python3
"""
Generates and signs canonical channel manifests for VitaSDK.
Matches the strict schema required by vdpm-channel.
"""

import argparse
import re
import hashlib
import json
import os
import subprocess
import sys
import urllib.request

HOST_ARCHITECTURES = [
    "aarch64-linux-gnu",
    "arm64-apple-darwin",
    "x86_64-linux-gnu",
    "x86_64-w64-mingw32",
]

def fetch_sha256(url: str) -> str:
    """Download a file or sidecar and compute/extract SHA256 digest."""
    req = urllib.request.Request(url, headers={"User-Agent": "vitasdk-manifest-generator"})
    with urllib.request.urlopen(req) as resp:
        content = resp.read()
    if url.endswith(".sha256"):
        return content.decode("utf-8").strip().split()[0].lower()
    return hashlib.sha256(content).hexdigest().lower()

def get_digest(base_url: str, asset_name: str, local_dir: str = None) -> str:
    if local_dir:
        local_file = os.path.join(local_dir, asset_name)
        if os.path.isfile(local_file):
            with open(local_file, "rb") as f:
                return hashlib.sha256(f.read()).hexdigest().lower()
        sidecar = local_file + ".sha256"
        if os.path.isfile(sidecar):
            with open(sidecar, "r", encoding="utf-8") as f:
                return f.read().strip().split()[0].lower()

    # Try downloading .sha256 sidecar first, fallback to computing from asset
    sidecar_url = f"{base_url}/{asset_name}.sha256"
    try:
        return fetch_sha256(sidecar_url)
    except Exception:
        asset_url = f"{base_url}/{asset_name}"
        return fetch_sha256(asset_url)

def read_deprecated(path):
    """The deprecated packages published with the snapshot, if it carries any.

    A snapshot from before this existed simply has none, which is different
    from an unreadable one: that is a mistake worth stopping for, because the
    result would silently claim nothing is deprecated.
    """

    if not path:
        return {}
    with open(path, encoding="utf-8") as handle:
        entries = json.load(handle)
    if not isinstance(entries, dict) or not all(
            isinstance(k, str) and isinstance(v, str) for k, v in entries.items()):
        raise SystemExit(f"ERROR: {path} is not a package to reason mapping")
    return entries


def build_manifest(
    core_release: str,
    packages_release: str,
    channel: str,
    sequence: int,
    core_dir: str = None,
    packages_dir: str = None,
    core_repository: str = "vitasdk/autobuilds",
    packages_repository: str = "vitasdk/packages",
    deprecated: dict = None,
) -> str:
    # Which repository holds the packages is written into the manifest and the
    # client builds its URLs from it, so moving the catalogue to another
    # repository is a matter of saying so here.
    core_base = f"https://github.com/{core_repository}/releases/download/{core_release}"
    packages_base = f"https://github.com/{packages_repository}/releases/download/{packages_release}"

    architectures = {}
    for host in HOST_ARCHITECTURES:
        db_name = f"{host}.db"
        digest = get_digest(core_base, db_name, core_dir)
        architectures[host] = {
            "database": {
                "name": db_name,
                "sha256": digest,
            }
        }

    vita_db_digest = get_digest(packages_base, "vita.db", packages_dir)

    manifest_dict = {
        "channel": channel,
        "core": {
            "architectures": architectures,
            "release": core_release,
            "repository": core_repository,
        },
        "packages": {
            "database": {
                "name": "vita.db",
                "sha256": vita_db_digest,
            },
            # Rides inside the manifest rather than in a file of its own: it
            # is a handful of lines, and this way it is signed and already
            # on disk when somebody runs an install.
            "deprecated": dict(sorted((deprecated or {}).items())),
            "release": packages_release,
            "repository": packages_repository,
        },
        "schema_version": 1,
        "sequence": int(sequence),
    }

    # Format canonical JSON (sorted keys, compact separators, single trailing newline)
    canonical_json = json.dumps(manifest_dict, sort_keys=True, separators=(",", ":")) + "\n"
    return canonical_json

def sign_manifest(manifest_path: str, signature_path: str, private_key_path: str):
    cmd = [
        "openssl", "pkeyutl",
        "-sign", "-rawin",
        "-inkey", private_key_path,
        "-in", manifest_path,
        "-out", signature_path,
    ]
    subprocess.run(cmd, check=True)

CHANNEL_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def channel_name(value):
    """A channel name, which is not one of a fixed list.

    A release series is a channel that lives as long as the release does, so
    2026.09 has to be nameable the same way nightly is. It is still checked,
    because the name ends up in a URL and in the file this writes.
    """

    if not CHANNEL_NAME.match(value) or ".." in value:
        raise argparse.ArgumentTypeError(
            f"invalid channel name: {value!r}")
    return value


def main():
    parser = argparse.ArgumentParser(description="Generate and sign VitaSDK channel manifest")
    parser.add_argument("--core-release", required=True, help="Release tag from vitasdk/autobuilds")
    parser.add_argument("--packages-release", required=True, help="Release tag holding the packages")
    parser.add_argument("--deprecated",
                        help="deprecated.json from the packages release")
    parser.add_argument("--packages-repository", default="vitasdk/packages",
                        help="Repository holding the packages release")
    parser.add_argument("--core-repository", default="vitasdk/autobuilds",
                        help="Repository holding the core release")
    parser.add_argument("--channel", default="nightly", type=channel_name,
                        help="Target channel name: nightly, stable, or a "
                             "release series such as 2026.09")
    parser.add_argument("--sequence", type=int, default=1, help="Monotonic channel sequence number")
    parser.add_argument("--key", help="Path to Ed25519 private key in PEM format")
    parser.add_argument("--core-dir", help="Optional local directory containing core databases")
    parser.add_argument("--packages-dir", help="Optional local directory containing packages database")
    parser.add_argument("--output-dir", default=".", help="Output directory for generated manifest and signature")
    args = parser.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)
    manifest_file = os.path.join(args.output_dir, f"{args.channel}.json")
    signature_file = os.path.join(args.output_dir, f"{args.channel}.json.sig")

    print(f"Generating manifest for channel '{args.channel}' (sequence {args.sequence})...")
    manifest_content = build_manifest(
        core_release=args.core_release,
        packages_release=args.packages_release,
        packages_repository=args.packages_repository,
        core_repository=args.core_repository,
        channel=args.channel,
        sequence=args.sequence,
        core_dir=args.core_dir,
        packages_dir=args.packages_dir,
        deprecated=read_deprecated(args.deprecated),
    )

    with open(manifest_file, "w", encoding="utf-8") as f:
        f.write(manifest_content)
    print(f"Wrote canonical manifest to {manifest_file}")

    if args.key:
        print(f"Signing manifest with {args.key}...")
        sign_manifest(manifest_file, signature_file, args.key)
        print(f"Wrote signature to {signature_file}")

if __name__ == "__main__":
    main()
