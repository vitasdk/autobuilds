#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 2 ]]; then
	printf 'usage: %s <output-directory> <vitasdk-core-package>...\n' "$0" >&2
	exit 2
fi

output_directory=$1
shift
source_date_epoch=${SOURCE_DATE_EPOCH:-}
script_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

[[ -n $source_date_epoch && $source_date_epoch =~ ^[0-9]+$ ]] || {
	printf 'SOURCE_DATE_EPOCH must be set to a non-negative integer\n' >&2
	exit 1
}
[[ ! -e $output_directory ]] || {
	printf 'output path already exists: %s\n' "$output_directory" >&2
	exit 1
}
command -v repo-add >/dev/null
command -v bsdtar >/dev/null

output_parent=$(cd "$(dirname "$output_directory")" && pwd -P)
output_name=$(basename "$output_directory")
staging_directory=$(mktemp -d "$output_parent/.${output_name}.XXXXXXXX")
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/vitasdk-core-repositories.XXXXXXXX")
cleanup() {
	rm -rf -- "$staging_directory" "$temporary_directory"
}
trap cleanup EXIT

declare -A architectures=()
for package in "$@"; do
	[[ -f $package && ! -L $package ]] || {
		printf 'core package is not a regular file: %s\n' "$package" >&2
		exit 1
	}
	package_filename=${package##*/}
	pkginfo=$(bsdtar -xOf "$package" .PKGINFO)
	pkgname=$(awk -F ' = ' '$1 == "pkgname" { print $2; exit }' <<< "$pkginfo")
	pkgver=$(awk -F ' = ' '$1 == "pkgver" { print $2; exit }' <<< "$pkginfo")
	architecture=$(awk -F ' = ' '$1 == "arch" { print $2; exit }' <<< "$pkginfo")
	[[ $pkgname == vitasdk-core && -n $pkgver && -n $architecture ]] || {
		printf 'invalid core package metadata: %s\n' "$package_filename" >&2
		exit 1
	}
	[[ $package_filename == "vitasdk-core-$pkgver-$architecture.pkg.tar."* ]] || {
		printf 'core package filename does not match metadata: %s\n' \
			"$package_filename" >&2
		exit 1
	}
	[[ -z ${architectures[$architecture]+present} ]] || {
		printf 'duplicate core architecture: %s\n' "$architecture" >&2
		exit 1
	}
	architectures[$architecture]=$package_filename
	cp -p "$package" "$staging_directory/$package_filename"
done

normalize_database() {
	local source_archive=$1 output_archive=$2 extraction_directory list_file
	extraction_directory=$(mktemp -d "$temporary_directory/database.XXXXXXXX")
	list_file=$(mktemp "$temporary_directory/list.XXXXXXXX")
	bsdtar -xf "$source_archive" -C "$extraction_directory"
	find "$extraction_directory" -exec touch -h -d "@$source_date_epoch" {} +
	(
		cd "$extraction_directory"
		find . -mindepth 1 -printf '%P\n' | LC_ALL=C sort > "$list_file"
		bsdtar --format=gnutar --uid 0 --gid 0 --uname root --gname root \
			-cnf - -T "$list_file" | gzip -9 -n > "$output_archive"
	)
}

mapfile -t sorted_architectures < <(printf '%s\n' "${!architectures[@]}" | LC_ALL=C sort)
for architecture in "${sorted_architectures[@]}"; do
	package="$staging_directory/${architectures[$architecture]}"
	repo-add "$staging_directory/$architecture.db.tar.gz" "$package"
	normalize_database "$staging_directory/$architecture.db.tar.gz" \
		"$temporary_directory/$architecture.db"
	normalize_database "$staging_directory/$architecture.files.tar.gz" \
		"$temporary_directory/$architecture.files"
	rm -f "$staging_directory/$architecture.db" \
		"$staging_directory/$architecture.db.tar.gz" \
		"$staging_directory/$architecture.files" \
		"$staging_directory/$architecture.files.tar.gz"
	mv "$temporary_directory/$architecture.db" "$staging_directory/$architecture.db"
	mv "$temporary_directory/$architecture.files" "$staging_directory/$architecture.files"
done

(
	cd "$staging_directory"
	while IFS= read -r asset; do
		sha256sum -- "$asset"
	done < <(
		find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%P\n' |
			LC_ALL=C sort
	) > SHA256SUMS
)

"$script_directory/validate-core-repositories.sh" "$staging_directory"
mv "$staging_directory" "$output_directory"
printf 'created grouped core repositories: %s\n' "$output_directory"
