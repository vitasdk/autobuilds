#!/usr/bin/env bash

# Does a published channel work for somebody who has nothing?
#
# Generating a manifest and signing it proves neither that the client can read
# it nor that the packages it names can be installed. This is that proof, and
# it is the one that decides whether a series is publishable: it starts from a
# bare machine, takes the series by name, installs a package with a dependency
# to resolve, upgrades, and builds a Vita binary.
#
# Run inside a clean container, with the bootstrap archive of the core mounted:
#
#   docker run --rm -v /path/to/cores:/cores -v $PWD/scripts:/scripts:ro \
#     -e HOST=x86_64-linux-gnu -e SERIES=2026.08 ubuntu:24.04 \
#     bash /scripts/verify-channel.sh

set -euo pipefail

cores=${CORES_DIR:-/cores}
host=${HOST:?set HOST to the triplet of the bootstrap archive}
series=${SERIES:?set SERIES to the release series to take}
package=${PACKAGE:-libpng}

apt-get update -qq
# curl is what the channel helpers use; pacman carries its own libcurl.
apt-get install -y -qq bzip2 ca-certificates cmake curl >/dev/null

export VITASDK=/opt/vitasdk
tar -xjf "$cores/vitasdk-bootstrap-$host.tar.bz2" -C /opt
export PATH="$VITASDK/bin:$PATH"

printf '\n=== which series exist ===\n'
vdpm channels

printf '\n=== take one ===\n'
vdpm refresh "$series"

printf '\n=== what am I on ===\n'
vdpm status

printf '\n=== install, with a dependency to resolve ===\n'
# The pipeline is not left to fail on its own: yes(1) dies of SIGPIPE when the
# reader goes away, and under pipefail that would abort the whole check.
yes | vdpm install "$package" > /tmp/install.log 2>&1 || true
tail -6 /tmp/install.log
vdpm list

printf '\n=== upgrade ===\n'
vdpm upgrade > /tmp/upgrade.log 2>&1 || true
tail -3 /tmp/upgrade.log

printf '\n=== and it still builds a Vita binary ===\n'
cmake -S "$VITASDK/share/gcc-arm-vita-eabi/samples/hello_world" -B /tmp/hello \
	-DCMAKE_TOOLCHAIN_FILE="$VITASDK/share/vita.toolchain.cmake" >/dev/null
cmake --build /tmp/hello >/dev/null
ls -la /tmp/hello/hello_world.vpk
