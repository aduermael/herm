#!/bin/sh
set -eu

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
herm_root=$(CDPATH= cd "$script_dir/.." && pwd -P)
. "$script_dir/lib/cpsl-xcframework.sh"

placeholder_dir="$herm_root/scripts/cpsl-xcframework-placeholder"
link_path="$placeholder_dir/cpsl.xcframework"
built_path="$herm_root/.herm-cpsl/artifacts/apple/cpsl.xcframework"
link_stamp="$herm_root/.herm-cpsl/artifacts/apple/.xcode-linked-xcframework.stamp"

cpsl_xcode_file_metadata() {
	path=$1

	if metadata=$(stat -f '%z %m' "$path" 2>/dev/null); then
		printf '%s\n' "$metadata"
		return 0
	fi

	if metadata=$(stat -c '%s %Y' "$path" 2>/dev/null); then
		printf '%s\n' "$metadata"
		return 0
	fi

	return 1
}

cpsl_xcode_artifact_fingerprint() {
	xcframework_path=$1

	[ -d "$xcframework_path" ] || return 1

	(
		cd "$xcframework_path" || exit 1
		find . -type f -print | LC_ALL=C sort | while IFS= read -r file; do
			metadata=$(cpsl_xcode_file_metadata "$file") || exit 1
			printf '%s\t%s\n' "${file#./}" "$metadata"
		done
	)
}

cpsl_xcode_link_is_current() {
	expected_fingerprint=$1
	linked_info=$(cpsl_xcframework_info_plist "$link_path")

	[ -f "$link_stamp" ] || return 1
	[ -d "$link_path" ] || return 1
	cpsl_xcframework_is_placeholder "$link_path" && return 1
	cpsl_xcframework_is_full "$linked_info" || return 1

	actual_fingerprint=$(cat "$link_stamp") || return 1
	[ "$actual_fingerprint" = "$expected_fingerprint" ]
}

cpsl_xcframework_remove_stray_links "$placeholder_dir" "$link_path"

# Xcode validates the linked XCFramework path before any build phase runs, so a
# tracked bootstrap directory must exist on fresh clones. Locally, repair broken
# symlinks or non-directory contents before building the real artifact. Existing
# directories may be either the bootstrap placeholder or a prior full local copy;
# stale directories are replaced after the cached artifact is validated.
if [ -L "$link_path" ]; then
	if [ ! -e "$link_path" ]; then
		rm "$link_path"
		"$herm_root/scripts/bootstrap-cpsl-xcframework-placeholder.sh"
	fi
elif [ ! -e "$link_path" ]; then
	"$herm_root/scripts/bootstrap-cpsl-xcframework-placeholder.sh"
elif [ -d "$link_path" ]; then
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
built_fingerprint=$(cpsl_xcode_artifact_fingerprint "$built_path") || {
	printf '%s\n' "error: failed to fingerprint CPSL XCFramework: $built_path" >&2
	exit 1
}

if cpsl_xcode_link_is_current "$built_fingerprint"; then
	printf 'Using linked CPSL XCFramework: %s\n' "$link_path"
	exit 0
fi

if [ -d "$link_path" ] && cpsl_xcframework_is_placeholder "$link_path"; then
	cpsl_xcframework_set_skip_worktree "$herm_root"
fi

if [ -L "$link_path" ]; then
	rm "$link_path"
elif [ -e "$link_path" ]; then
	rm -rf "$link_path"
fi
cp -R "$built_path" "$link_path"
mkdir -p "$(dirname "$link_stamp")"
printf '%s\n' "$built_fingerprint" >"$link_stamp"
printf 'Linked CPSL XCFramework: %s\n' "$link_path"
