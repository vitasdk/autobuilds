#!/bin/bash

set -e
cd "$(dirname "$0")"

#
# This builds a statically-linked x86-64 musl-based toolchain
# suitable for producing a statically linked vitasdk toolchain.
#
# What that means is that you can run this .sh script on your
# host machine and the output x86-64 toolchain will work fine 
# on Travis or any somewhat modern linux distribution and will
# be capable of building statically linked binaries that also
# work somewhat everywhere.
#


VERSION=0.9.7
NCPU=$(grep -c ^processor /proc/cpuinfo)
BASE_CONFIG_MAK="
TARGET = x86_64-linux-musl
COMMON_CONFIG += CFLAGS=\"-g0 -Os\" CXXFLAGS=\"-g0 -Os\" LDFLAGS=\"-s\"
COMMON_CONFIG += --disable-nls
GCC_CONFIG += --enable-languages=c,c++
GCC_CONFIG += --disable-libquadmath --disable-decimal-float
GCC_CONFIG += --disable-multilib
"
OUTPUT="static-musl-for-travis"
BUILD_DIR="musl-cross-make-$VERSION"

if [ ! -d "$BUILD_DIR" ]; then
	# Download a release of musl-cross-make scripts
	curl -L https://github.com/richfelker/musl-cross-make/archive/v$VERSION.tar.gz | tar xvz
fi

pushd $BUILD_DIR
DIR=$(pwd)

# clean up previous build, if existed
make clean

echo "==> Step 1) Build an x86-64 musl toolchain linked against system libc"
echo "$BASE_CONFIG_MAK" > config.mak
echo "OUTPUT=$DIR/output-first" >> config.mak
make -j$NCPU
make install
make clean

echo "==> Step 2) Build a statically-linked x86-64 musl toolchain"
echo "$BASE_CONFIG_MAK" > config.mak
echo "OUTPUT=$DIR/$OUTPUT" >> config.mak
echo "COMMON_CONFIG += CC=\"x86_64-linux-musl-gcc -static --static\" CXX=\"x86_64-linux-musl-g++ -static --static\"" >> config.mak
export PATH=$DIR/output-first/bin/:$PATH
make -j$NCPU
make install
make clean

tar cvzf $OUTPUT.tar.gz $OUTPUT

popd

ls -la $DIR/$OUTPUT.tar.gz
