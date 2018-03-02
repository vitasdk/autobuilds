#!/bin/bash

set -e

# We're using a musl toolchain
echo "==> Obtain static musl toolchain"
curl http://dl.vitasdk.org/static-musl-for-travis.tar.gz | tar xzv
export PATH=$(pwd)/static-musl-for-travis/bin/:$PATH
ln -s x86_64-linux-musl-gcc $(pwd)/static-musl-for-travis/bin/gcc

echo "==> Compile vitasdk"
# dynamic-linker is bogus, just to get the executable to run on travis
export LD_LIBRARY_PATH=$(pwd)/static-musl-for-travis/x86_64-linux-musl/lib/
LINKFLAGS="-Wl,--dynamic-linker,$LD_LIBRARY_PATH/libc.so"
export CC="x86_64-linux-musl-gcc $LINKFLAGS"
export CXX="x86_64-linux-musl-g++ $LINKFLAGS"
cmake ..
make -j4 tarball

# now comes the fun part
echo "==> Extract vitasdk"
mkdir -p patch
pushd patch
oldname=$(basename ../vitasdk-*.tar.bz2)
tar xvf ../$oldname

pushd vitasdk
echo "==> Patch executable binaries"
FILES=$(find . -type f -executable | xargs file | grep ELF | grep executable | cut -d':' -f1)

for file in $FILES; do
	if [[ $file != _* ]]; then
		echo "-- Patching $file"

		name=$(basename $file)
		dirpath=$(dirname $file)

		# Depending on where the executable is, different number of ../../ in the relative path
		relative=$(realpath --relative-to="$dirpath" "lib/libmusl_vitasdk.so")

		# Store "real" executable as _name, e.g. _vita-pack-vpk
		mv $file $dirpath/_$name

		# The wrapper script will execute our real executable providing full path to program interpreter
		echo -n "" > $file
		echo "#!/bin/sh" >> $file
		echo 'HERE=$(dirname "$0")' >> $file
		echo "\$HERE/$relative --argv0=$name -- \$HERE/_$name \"\$@\"" >> $file

		chmod +x $file
	fi;
done

echo "==> Deploy libmusl_vitasdk.so"
cp $LD_LIBRARY_PATH/libc.so lib/libmusl_vitasdk.so

popd

echo "==> Archive patched vitasdk"
tar cfvj $oldname vitasdk

# and replace it
mv $oldname ../

popd
