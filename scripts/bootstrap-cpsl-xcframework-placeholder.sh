#!/bin/sh
set -eu

die() {
	printf '%s\n' "error: $*" >&2
	exit 1
}

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
herm_root=$(CDPATH= cd "$script_dir/.." && pwd -P)
. "$script_dir/lib/cpsl-xcframework.sh"

out_dir=${OUT_DIR:-"$herm_root/scripts/cpsl-xcframework-placeholder"}
xcframework_path="$out_dir/cpsl.xcframework"
header_source="$script_dir/cpsl-xcframework-placeholder/cpsl.h"

[ -f "$header_source" ] || die "missing placeholder header: $header_source"

mkdir -p "$out_dir"
cpsl_xcframework_bootstrap_placeholder "$xcframework_path" "$header_source"
printf 'Bootstrapped CPSL XCFramework placeholder: %s\n' "$xcframework_path"