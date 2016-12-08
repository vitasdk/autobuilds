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
cmake ..
make -j4 tarball
      ;;
esac
