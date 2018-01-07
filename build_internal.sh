#!/bin/bash
cd buildscripts
case "${TOXENV}" in
    WIN)
unset CXX
unset CC
mkdir build
cd build
cmake .. -DCMAKE_TOOLCHAIN_FILE=toolchain-x86_64-w64-mingw32.cmake
make -j4 tarball
      ;;
    *)
mkdir build
cd build
if [[ $(uname -s) = "Linux" ]]; then
	curl http://dl.vitasdk.org/static-musl-for-travis.tar.gz | tar xzv
	export PATH=$(pwd)/static-musl-for-travis/bin/:$PATH
	ln -s x86_64-linux-musl-gcc $(pwd)/static-musl-for-travis/bin/gcc
	export CC="x86_64-linux-musl-gcc -static --static"
	export CXX="x86_64-linux-musl-g++ -static --static"
	cmake ..
else
	cmake ..
fi
make -j4 tarball
      ;;
esac
