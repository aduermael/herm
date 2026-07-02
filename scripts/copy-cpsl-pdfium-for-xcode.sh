#!/bin/sh
set -eu

die() {
	printf '%s\n' "error: $*" >&2
	exit 1
}

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
herm_root=$(CDPATH= cd "$script_dir/.." && pwd -P)
pdfium_root="$herm_root/.herm-cpsl/artifacts/apple/libs/pdfium"

case "${PLATFORM_NAME:-}" in
iphoneos)
	pdfium_slice=ios-arm64
	;;
iphonesimulator)
	pdfium_slice=ios-simulator
	;;
macosx)
	pdfium_slice=macos
	;;
xros | xrsimulator)
	die "CPSL does not yet support visionOS. Supported platforms: iOS and macOS."
	;;
*)
	die "unsupported Apple platform for CPSL PDFium: ${PLATFORM_NAME:-<unset>}"
	;;
esac

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
