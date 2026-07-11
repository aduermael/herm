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

cpsl_patch_already_integrated() {
	name=$1

	case "$name" in
	0001-ffi-support-composed-mounts.patch)
		ffi_lib="$cpsl_root/ffi/src/lib.rs"
		shrt_runtime="$cpsl_root/runtime/shrt.luau"
		[ -f "$ffi_lib" ] && [ -f "$shrt_runtime" ] || return 1
		grep -q 'struct ValidatedMountConfig' "$ffi_lib" &&
			grep -q 'fn shell_root_for' "$ffi_lib" &&
			grep -q 'fn icloud_mounts_are_visible_and_enforce_modes' "$ffi_lib" &&
			grep -q 'local exit_code = tonumber(code) or 0' "$shrt_runtime"
		;;
	*)
		return 1
		;;
	esac
}

for patch in "$patch_dir"/*.patch; do
	[ -f "$patch" ] || continue
	name=$(basename "$patch")

	if git -C "$cpsl_root" apply --check "$patch" >/dev/null 2>&1; then
		printf 'Applying CPSL patch: %s\n' "$name"
		git -C "$cpsl_root" apply "$patch"
	elif git -C "$cpsl_root" apply --reverse --check "$patch" >/dev/null 2>&1; then
		printf 'CPSL patch already applied: %s\n' "$name"
	elif cpsl_patch_already_integrated "$name"; then
		printf 'CPSL patch already integrated: %s\n' "$name"
	else
		die "CPSL patch does not apply cleanly: $name"
	fi
done
