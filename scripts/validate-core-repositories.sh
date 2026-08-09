#!/usr/bin/env bash

set -euo pipefail

[[ $# -eq 1 ]] || {
	printf 'usage: %s <repository-directory>\n' "$0" >&2
	exit 2
}

repository_directory=$1
[[ -d $repository_directory ]] || {
	printf 'repository directory not found: %s\n' "$repository_directory" >&2
	exit 1
}
repository_directory=$(cd "$repository_directory" && pwd -P)

if find "$repository_directory" -mindepth 1 ! -type f -print -quit | grep -q .; then
	printf 'grouped repository contains a non-regular asset\n' >&2
	exit 1
fi

mapfile -d '' packages < <(
	find "$repository_directory" -maxdepth 1 -type f \
		-name 'vitasdk-core-*.pkg.tar.*' -print0 | LC_ALL=C sort -z
)
(( ${#packages[@]} > 0 )) || {
	printf 'grouped repository contains no core packages\n' >&2
	exit 1
}

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/vitasdk-core-validation.XXXXXXXX")
cleanup() {
	rm -rf -- "$temporary_directory"
}
trap cleanup EXIT

expected_assets="$temporary_directory/expected-assets"
printf 'SHA256SUMS\n' > "$expected_assets"
find "$repository_directory" -maxdepth 1 -type f -name 'vitasdk-*.tar.bz2' \
	-printf '%f\n' >> "$expected_assets"
declare -A architectures=()

for package in "${packages[@]}"; do
	package_filename=${package##*/}
	pkginfo=$(bsdtar -xOf "$package" .PKGINFO)
	pkgver=$(awk -F ' = ' '$1 == "pkgver" { print $2; exit }' <<< "$pkginfo")
	architecture=$(awk -F ' = ' '$1 == "arch" { print $2; exit }' <<< "$pkginfo")
	[[ -n $pkgver && -n $architecture ]] || exit 1
	[[ -z ${architectures[$architecture]+present} ]] || {
		printf 'duplicate architecture in grouped repository: %s\n' \
			"$architecture" >&2
		exit 1
	}
	architectures[$architecture]=1
	bootstrap="vitasdk-bootstrap-$architecture.tar.bz2"
	[[ -f $repository_directory/$bootstrap ]] || {
		printf 'missing host bootstrap archive: %s\n' "$bootstrap" >&2
		exit 1
	}

	for asset in "$architecture.db" "$architecture.files"; do
		[[ -f $repository_directory/$asset && ! -L $repository_directory/$asset ]] || {
			printf 'missing host repository asset: %s\n' "$asset" >&2
			exit 1
		}
		printf '%s\n' "$asset" >> "$expected_assets"
	done
	printf '%s\n' "$package_filename" >> "$expected_assets"

	description=$(bsdtar -tf "$repository_directory/$architecture.db" |
		grep '/desc$')
	database_filename=$(bsdtar -xOf "$repository_directory/$architecture.db" \
		"$description" | awk 'previous == "%FILENAME%" { print; exit } { previous = $0 }')
	[[ $database_filename == "$package_filename" ]] || {
		printf 'database/package mismatch for %s\n' "$architecture" >&2
		exit 1
	}
done

actual_assets="$temporary_directory/actual-assets"
find "$repository_directory" -maxdepth 1 -type f -printf '%f\n' |
	LC_ALL=C sort > "$actual_assets"
LC_ALL=C sort -o "$expected_assets" "$expected_assets"
diff -u "$expected_assets" "$actual_assets"

checksum_assets="$temporary_directory/checksum-assets"
awk '{ sub(/^\*/, "", $2); print $2 }' "$repository_directory/SHA256SUMS" |
	LC_ALL=C sort > "$checksum_assets"
grep -vx SHA256SUMS "$expected_assets" > "$temporary_directory/hashed-assets"
diff -u "$temporary_directory/hashed-assets" "$checksum_assets"
(
	cd "$repository_directory"
	sha256sum --check --strict SHA256SUMS
)

printf 'validated %d host repositories\n' "${#packages[@]}"
