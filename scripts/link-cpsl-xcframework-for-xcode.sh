#!/bin/sh
set -eu

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
herm_root=$(CDPATH= cd "$script_dir/.." && pwd -P)
. "$script_dir/lib/cpsl-xcframework.sh"

placeholder_dir="$herm_root/scripts/cpsl-xcframework-placeholder"
link_path="$placeholder_dir/cpsl.xcframework"
built_path="$herm_root/.herm-cpsl/artifacts/apple/cpsl.xcframework"

cpsl_xcframework_remove_stray_links "$placeholder_dir" "$link_path"

# Xcode validates the linked XCFramework path before any build phase runs, so a
# tracked bootstrap directory must exist on fresh clones. Locally, repair broken
# symlinks or unexpected contents before building the real artifact.
if [ -L "$link_path" ]; then
	if [ ! -e "$link_path" ]; then
		rm "$link_path"
		"$herm_root/scripts/bootstrap-cpsl-xcframework-placeholder.sh"
	fi
elif [ ! -e "$link_path" ]; then
	"$herm_root/scripts/bootstrap-cpsl-xcframework-placeholder.sh"
elif [ -d "$link_path" ] && cpsl_xcframework_is_placeholder "$link_path"; then
	:
elif [ -e "$link_path" ]; then
	rm -rf "$link_path"
	"$herm_root/scripts/bootstrap-cpsl-xcframework-placeholder.sh"
fi

"$herm_root/scripts/ensure-cpsl-apple-xcframework.sh" "$@"

[ -d "$built_path" ] || {
	printf '%s\n' "error: missing built CPSL XCFramework: $built_path" >&2
	exit 1
}

if [ -L "$link_path" ]; then
	current_target=$(CDPATH= cd "$(dirname "$link_path")" && readlink "$link_path" || printf '')
	if [ "$current_target" = "$built_path" ]; then
		exit 0
	fi
fi

if [ -d "$link_path" ] && cpsl_xcframework_is_placeholder "$link_path"; then
	cpsl_xcframework_set_skip_worktree "$herm_root"
fi

rm -rf "$link_path"
ln -s "$built_path" "$link_path"