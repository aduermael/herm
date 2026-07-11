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

for patch in "$patch_dir"/*.patch; do
	[ -f "$patch" ] || continue
	name=$(basename "$patch")

	if git -C "$cpsl_root" apply --check "$patch" >/dev/null 2>&1; then
		printf 'Applying CPSL patch: %s\n' "$name"
		git -C "$cpsl_root" apply "$patch"
	elif git -C "$cpsl_root" apply --reverse --check "$patch" >/dev/null 2>&1; then
		printf 'CPSL patch already applied: %s\n' "$name"
	else
		die "CPSL patch does not apply cleanly: $name"
	fi
done
