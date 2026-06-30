#!/bin/sh
set -eu

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
herm_root=$(CDPATH= cd "$script_dir/.." && pwd -P)
. "$script_dir/lib/cpsl-xcframework.sh"

link_path="$herm_root/scripts/cpsl-xcframework-placeholder/cpsl.xcframework"
built_path="$herm_root/.herm-cpsl/artifacts/apple/cpsl.xcframework"

if [ ! -e "$link_path" ]; then
	"$herm_root/scripts/bootstrap-cpsl-xcframework-placeholder.sh"
fi

"$herm_root/scripts/ensure-cpsl-apple-xcframework.sh" "$@"

[ -d "$built_path" ] || {
	printf '%s\n' "error: missing built CPSL XCFramework: $built_path" >&2
	exit 1
}

if [ -L "$link_path" ]; then
	rm "$link_path"
elif [ -e "$link_path" ]; then
	rm -rf "$link_path"
fi

ln -sfn "$built_path" "$link_path"