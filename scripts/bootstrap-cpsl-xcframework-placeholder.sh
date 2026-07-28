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

cpsl_xcframework_remove_stray_links "$out_dir" "$xcframework_path"
if [ -L "$xcframework_path" ]; then
	rm "$xcframework_path"
elif [ -e "$xcframework_path" ]; then
	rm -rf "$xcframework_path"
fi

cpsl_xcframework_clear_skip_worktree "$herm_root"
if ! cpsl_xcframework_restore_tracked_placeholder "$herm_root" "$xcframework_path"; then
	mkdir -p "$out_dir"
	cpsl_xcframework_bootstrap_placeholder "$xcframework_path" "$header_source"
fi

# Xcode can scan the tracked XCFramework before the CPSL build target runs.
# Keep every bootstrap slice's import surface in sync with the canonical stub
# header so that early Swift module generation sees the CPSL C API.
for slice_header in "$xcframework_path"/*/Headers/cpsl.h; do
	cp "$header_source" "$slice_header"
done
printf 'Bootstrapped CPSL XCFramework placeholder: %s\n' "$xcframework_path"
