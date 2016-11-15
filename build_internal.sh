#!/bin/bash
cd buildscripts
mkdir build
cd build
cmake .. 
make -j4 tarball
