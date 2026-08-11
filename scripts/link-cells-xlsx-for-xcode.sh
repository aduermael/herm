#!/bin/sh
# Xcode run-script phase: build cells_xlsx for the active SDK and expose paths.
set -eu

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
herm_root=$(CDPATH= cd "$script_dir/.." && pwd -P)
. "$script_dir/lib/cells-xlsx-apple.sh"

platform=$(cells_xlsx_platform_from_xcode "${PLATFORM_NAME:-}" "${SDK_NAME:-}")
archs=$(cells_xlsx_archs_from_xcode "${ARCHS:-}" "${CURRENT_ARCH:-}")
work_dir=${CELLS_WORK_DIR:-"$herm_root/.herm-cells"}
out_dir=${OUT_DIR:-"$work_dir/artifacts/apple/$platform"}

"$script_dir/build-cells-xlsx-apple.sh" --platform "$platform" --archs "$archs"

# Ensure Xcode picks up the staged library even when only the stamp is listed
# as an output. The app target already points HEADER/LIBRARY search paths here.
stamp_path=${SCRIPT_OUTPUT_FILE_0:-}
if [ -n "$stamp_path" ]; then
	mkdir -p "$(dirname "$stamp_path")"
	printf 'linked %s platform=%s archs=%s\n' \
		"$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$platform" "$archs" >"$stamp_path"
fi

printf 'cells_xlsx ready for Xcode (%s)\n' "$out_dir"
