#!/bin/sh
set -eu

die() {
	printf '%s\n' "error: $*" >&2
	exit 1
}

if [ "$#" -ne 1 ]; then
	die "usage: scripts/apply-cpsl-patches.sh CPSL_ROOT"
fi

cpsl_root=$1
[ -d "$cpsl_root" ] || die "CPSL_ROOT is not a directory: $cpsl_root"

if ! command -v git >/dev/null 2>&1; then
	die "git is required to apply Herm CPSL patches"
fi

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
patch_dir="$script_dir/cpsl-patches"
[ -d "$patch_dir" ] || exit 0
series_file="$patch_dir/series"
[ -f "$series_file" ] || die "CPSL patch series is missing: $series_file"

while IFS= read -r name || [ -n "$name" ]; do
	case "$name" in
		''|'#'*) continue ;;
	esac
	case "$name" in
		*[!A-Za-z0-9._-]*|.*|*..*) die "invalid CPSL patch series entry: $name" ;;
		*.patch) ;;
		*) die "CPSL patch series entry must end in .patch: $name" ;;
	esac

	patch="$patch_dir/$name"
	[ -f "$patch" ] || die "CPSL patch listed in series is missing: $name"

	if git -C "$cpsl_root" apply --check "$patch" >/dev/null 2>&1; then
		printf 'Applying CPSL patch: %s\n' "$name"
		git -C "$cpsl_root" apply "$patch"
	elif git -C "$cpsl_root" apply --reverse --check "$patch" >/dev/null 2>&1; then
		printf 'CPSL patch already applied: %s\n' "$name"
	else
		die "CPSL patch does not apply cleanly: $name"
	fi
done <"$series_file"
