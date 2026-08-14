#!/usr/bin/env bash

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/vitasdk-autobuilds-repository.XXXXXXXX")
pacman_image='archlinux@sha256:c1829f370be8434135f43fb3acaef1256780804ac3b2d2eec90dfb1232e1ffdf'

cleanup() {
	chmod -R u+rwX "$temporary_root" 2>/dev/null || true
	rm -rf -- "$temporary_root"
}
trap cleanup EXIT

docker run --rm \
	--platform linux/amd64 \
	--mount "type=bind,source=$repository_root,target=/workspace,readonly" \
	--mount "type=bind,source=$temporary_root,target=/work" \
	--env SOURCE_DATE_EPOCH=1700000000 \
	"$pacman_image" \
	bash -euc '
		export LC_ALL=C
		create_package() {
			local architecture=$1 name=$2 depends=$3 payload=$4
			local root="/work/package-$name-$architecture"
			local output="/work/$name-0.1-1-$architecture.pkg.tar.xz"
			install -d "$root/bin"
			printf "#!/bin/sh\nexit 0\n" > "$root/bin/$payload"
			chmod +x "$root/bin/$payload"
			cat > "$root/.PKGINFO" <<EOF
pkgname = $name
pkgbase = $name
pkgver = 0.1-1
pkgdesc = VitaSDK core repository fixture
url = https://vitasdk.org/
builddate = 1700000000
packager = VitaSDK Tests
size = 32
arch = $architecture
license = custom
xdata = pkgtype=pkg
EOF
			[ -z "$depends" ] || printf "depend = %s\n" "$depends" >> "$root/.PKGINFO"
			printf "format = 2\n" > "$root/.BUILDINFO"
			(
				cd "$root"
				find . -mindepth 1 ! -name .MTREE -print0 | sort -z |
					bsdtar -cnf - --format=mtree \
						--options="!all,use-set,type,uid,gid,mode,time,size,sha256,link" \
						--uid 0 --gid 0 --null -T - | gzip -n > .MTREE
				find . -exec touch -h -d @1700000000 {} +
				find . -mindepth 1 -printf "%P\n" | sort |
					bsdtar --format=gnutar --uid 0 --gid 0 \
						--uname root --gname root -cnf - -T - | xz -9 -c > "$output"
			)
		}

		for architecture in x86_64-linux-gnu aarch64-linux-gnu; do
			create_package "$architecture" vdpm "" vdpm
			create_package "$architecture" vitasdk-core "vdpm>=0.1-1" \
				arm-vita-eabi-gcc
		done
		mkdir /work/sdk-archives
		printf "bootstrap fixture\n" > \
			/work/sdk-archives/vitasdk-bootstrap-x86_64-linux-gnu.tar.bz2
		printf "bootstrap fixture\n" > \
			/work/sdk-archives/vitasdk-bootstrap-aarch64-linux-gnu.tar.bz2
		printf "compatibility fixture\n" > \
			/work/sdk-archives/vitasdk-x86_64-linux-gnu-fixture.tar.bz2
		packages=(/work/*-0.1-1-*.pkg.tar.xz)
		export SDK_ARCHIVE_DIRECTORY=/work/sdk-archives
		/workspace/scripts/create-core-repositories.sh \
			/work/repository-one "${packages[@]}"
		/workspace/scripts/create-core-repositories.sh \
			/work/repository-two "${packages[@]}"
		diff -ru /work/repository-one /work/repository-two
		test -f /work/repository-one/vitasdk-bootstrap-x86_64-linux-gnu.tar.bz2

		cat > /work/pacman.conf <<EOF
[options]
Architecture = x86_64-linux-gnu vita
SigLevel = Never
[x86_64-linux-gnu]
Server = file:///work/repository-one
EOF
		install -d /sdk/var/lib/pacman /sdk/var/cache/pacman/pkg
		pacman --config /work/pacman.conf --root /sdk \
			--dbpath /sdk/var/lib/pacman --cachedir /sdk/var/cache/pacman/pkg \
			--logfile /sdk/var/log/pacman.log --noscriptlet \
			--sync --refresh --refresh --noconfirm
		pacman --config /work/pacman.conf --root /sdk \
			--dbpath /sdk/var/lib/pacman --cachedir /sdk/var/cache/pacman/pkg \
			--logfile /sdk/var/log/pacman.log --noscriptlet \
			--sync --noconfirm vitasdk-core
		test -x /sdk/bin/arm-vita-eabi-gcc
		# Asking for the toolchain has to bring the client that installs it,
		# straight out of the published host repository.
		test -x /sdk/bin/vdpm
		pacman --config /work/pacman.conf --root /sdk \
			--dbpath /sdk/var/lib/pacman --query vdpm

		cp -a /work/repository-one /work/corrupted-repository
		printf corruption >> /work/corrupted-repository/x86_64-linux-gnu.db
		if /workspace/scripts/validate-core-repositories.sh \
			/work/corrupted-repository; then
			printf "corrupted host database was unexpectedly accepted\n" >&2
			exit 1
		fi
	'

printf 'VitaSDK grouped core repository contracts passed\n'
