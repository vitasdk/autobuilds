# VitaSDK autobuilds

This repository builds and publishes host-specific VitaSDK snapshots from an
exact `vitasdk/buildscripts` revision.

Each package-managed snapshot is assembled as one release transaction. It
contains:

- one versioned `vitasdk-core` package for every package-client-capable host;
- one pacman database and files database named for each host triplet;
- `SHA256SUMS` covering every release asset;
- temporary legacy SDK archives during the migration period.

Published tags are unique (`sdk-snapshot-<date>.<run>.<attempt>`). The workflow
creates a draft release, uploads every asset without replacement, downloads and
compares it with the validated build output, and only then publishes it. A
published snapshot is never modified.

The current package-managed preview covers Linux x86_64, Linux aarch64 and
macOS arm64. Windows remains available as a legacy archive until the static
rootless package client passes its native MinGW contract; preview releases are
therefore marked as prereleases and cannot be promoted to stable.

Channel selection is intentionally outside this build workflow. A stable or
nightly channel manifest points to an exact immutable SDK release and an exact
immutable `vitasdk/packages` release after the pair has passed its promotion
gates.
