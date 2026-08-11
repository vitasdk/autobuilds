#!/usr/bin/env python3
"""
Generates and signs canonical channel manifests for VitaSDK.
Matches the strict schema required by vdpm-channel.
"""

import argparse
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

def build_manifest(
    core_release: str,
    packages_release: str,
    channel: str,
    sequence: int,
    core_dir: str = None,
    packages_dir: str = None,
) -> str:
    core_base = f"https://github.com/vitasdk/autobuilds/releases/download/{core_release}"
    packages_base = f"https://github.com/vitasdk/packages/releases/download/{packages_release}"

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
            "repository": "vitasdk/autobuilds",
        },
        "packages": {
            "database": {
                "name": "vita.db",
                "sha256": vita_db_digest,
            },
            "release": packages_release,
            "repository": "vitasdk/packages",
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

def main():
    parser = argparse.ArgumentParser(description="Generate and sign VitaSDK channel manifest")
    parser.add_argument("--core-release", required=True, help="Release tag from vitasdk/autobuilds")
    parser.add_argument("--packages-release", required=True, help="Release tag from vitasdk/packages")
    parser.add_argument("--channel", default="nightly", choices=["nightly", "stable", "rc"], help="Target channel name")
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
        channel=args.channel,
        sequence=args.sequence,
        core_dir=args.core_dir,
        packages_dir=args.packages_dir,
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
