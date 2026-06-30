#!/bin/sh
set -eu

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
herm_root=$(CDPATH= cd "$script_dir/.." && pwd -P)
. "$script_dir/lib/cpsl-xcframework.sh"

link_path="$herm_root/scripts/cpsl-xcframework-placeholder/cpsl.xcframework"

if [ -d "$link_path" ] && cpsl_xcframework_is_placeholder "$link_path"; then
	exit 0
fi

if [ -e "$link_path" ]; then
	rm -rf "$link_path"
fi

if git -C "$herm_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	if git -C "$herm_root" checkout -- "$link_path" 2>/dev/null && \
		[ -d "$link_path" ] && cpsl_xcframework_is_placeholder "$link_path"; then
		printf 'Restored tracked CPSL XCFramework placeholder: %s\n' "$link_path"
		exit 0
	fi
fi

"$herm_root/scripts/bootstrap-cpsl-xcframework-placeholder.sh"