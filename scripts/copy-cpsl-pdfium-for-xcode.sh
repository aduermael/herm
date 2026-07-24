#!/bin/sh
set -eu

die() {
	printf '%s\n' "error: $*" >&2
	exit 1
}

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
herm_root=$(CDPATH= cd "$script_dir/.." && pwd -P)
. "$script_dir/lib/cpsl-xcframework.sh"
work_dir=${CPSL_WORK_DIR:-"$herm_root/.herm-cpsl"}
out_dir=${OUT_DIR:-$(cpsl_apple_default_artifact_dir "$work_dir")}
pdfium_root="$out_dir/libs/pdfium"
placeholder_dir="$herm_root/scripts/cpsl-xcframework-placeholder"
link_path="$placeholder_dir/cpsl.xcframework"
link_stamp="$out_dir/.xcode-linked-xcframework.stamp"

cpsl_pdfium_restore_xcframework_placeholder() {
	status=$?

	if ! rm -f "$link_stamp" 2>/dev/null; then
		printf '%s\n' "warning: failed to remove CPSL XCFramework link stamp: $link_stamp" >&2
	fi

	if [ -e "$link_path" ] || [ -L "$link_path" ]; then
		if cpsl_xcframework_restore_tracked_placeholder "$herm_root" "$link_path"; then
			printf 'Restored CPSL XCFramework placeholder: %s\n' "$link_path"
		else
			printf '%s\n' "warning: failed to restore CPSL XCFramework placeholder: $link_path" >&2
		fi
	fi

	return "$status"
}

trap cpsl_pdfium_restore_xcframework_placeholder EXIT

request_assignments=$(cpsl_apple_request_from_xcode_env) || die "failed to resolve CPSL PDFium slice from Xcode environment"
eval "$request_assignments"
ios_device_targets=$IOS_DEVICE_TARGETS
ios_simulator_targets=$IOS_SIMULATOR_TARGETS
macos_targets=$MACOS_TARGETS

cpsl_pdfium_satisfies_targets "$pdfium_root" "$ios_device_targets" "$ios_simulator_targets" "$macos_targets" || \
	die "$pdfium_root does not contain requested PDFium target(s): $CPSL_REQUEST_DESCRIPTION"

pdfium_slice=
for slice in $CPSL_PDFIUM_SLICES; do
	pdfium_slice=$slice
	break
done
[ -n "$pdfium_slice" ] || die "no CPSL PDFium slice requested for ${PLATFORM_NAME:-<unset>}"

src="$pdfium_root/$pdfium_slice/lib/libpdfium.dylib"
[ -f "$src" ] || die "missing PDFium library: $src"

[ -n "${TARGET_BUILD_DIR:-}" ] || die "TARGET_BUILD_DIR is required"
[ -n "${FRAMEWORKS_FOLDER_PATH:-}" ] || die "FRAMEWORKS_FOLDER_PATH is required"
frameworks_dir="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
mkdir -p "$frameworks_dir"

dst="$frameworks_dir/libpdfium.dylib"
rm -f "$dst"
cp "$src" "$dst"
chmod u+w "$dst"

if [ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]; then
	sign_identity=${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}
	if [ -n "$sign_identity" ]; then
		codesign --force --sign "$sign_identity" --timestamp=none "$dst"
	fi
fi

printf 'Copied CPSL PDFium: %s\n' "$dst"
