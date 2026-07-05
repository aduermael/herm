#!/bin/sh
set -eu

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
. "$script_dir/lib/cpsl-xcframework.sh"

fail() {
	printf '%s\n' "error: $*" >&2
	exit 1
}

assert_eq() {
	name=$1
	want=$2
	got=$3

	[ "$want" = "$got" ] || fail "$name: expected '$want', got '$got'"
}

resolve_xcode_request() (
	PLATFORM_NAME=$1
	SDK_NAME=$2
	ARCHS=$3
	export PLATFORM_NAME SDK_NAME ARCHS
	unset APPLE_PLATFORMS IOS_DEVICE_TARGETS IOS_SIMULATOR_TARGETS MACOS_TARGETS CURRENT_ARCH NATIVE_ARCH_ACTUAL
	cpsl_apple_request_from_environment
)

resolve_xcode_request_with_native_arch() (
	PLATFORM_NAME=$1
	SDK_NAME=$2
	NATIVE_ARCH_ACTUAL=$3
	export PLATFORM_NAME SDK_NAME NATIVE_ARCH_ACTUAL
	unset ARCHS APPLE_PLATFORMS IOS_DEVICE_TARGETS IOS_SIMULATOR_TARGETS MACOS_TARGETS CURRENT_ARCH
	cpsl_apple_request_from_environment
)

resolve_xcode_request_with_undefined_current_arch() (
	PLATFORM_NAME=$1
	SDK_NAME=$2
	CURRENT_ARCH=undefined_arch
	NATIVE_ARCH_ACTUAL=$3
	export PLATFORM_NAME SDK_NAME CURRENT_ARCH NATIVE_ARCH_ACTUAL
	unset ARCHS APPLE_PLATFORMS IOS_DEVICE_TARGETS IOS_SIMULATOR_TARGETS MACOS_TARGETS
	cpsl_apple_request_from_environment
)

request=$(resolve_xcode_request iphonesimulator iphonesimulator17.0 arm64)
eval "$request"
assert_eq "sim arm64 apple platforms" ios "$APPLE_PLATFORMS"
assert_eq "sim arm64 device targets" "" "$IOS_DEVICE_TARGETS"
assert_eq "sim arm64 simulator targets" aarch64-apple-ios-sim "$IOS_SIMULATOR_TARGETS"
assert_eq "sim arm64 PDFium" ios-simulator "$CPSL_PDFIUM_SLICES"

request=$(resolve_xcode_request iphonesimulator iphonesimulator17.0 "arm64 x86_64")
eval "$request"
assert_eq "sim universal targets" "aarch64-apple-ios-sim x86_64-apple-ios" "$IOS_SIMULATOR_TARGETS"
assert_eq "sim universal PDFium" ios-simulator "$CPSL_PDFIUM_SLICES"

request=$(resolve_xcode_request iphoneos iphoneos17.0 arm64)
eval "$request"
assert_eq "device target" aarch64-apple-ios "$IOS_DEVICE_TARGETS"
assert_eq "device PDFium" ios-arm64 "$CPSL_PDFIUM_SLICES"

request=$(resolve_xcode_request macosx macosx14.0 x86_64)
eval "$request"
assert_eq "macOS target" x86_64-apple-darwin "$MACOS_TARGETS"
assert_eq "macOS PDFium" macos "$CPSL_PDFIUM_SLICES"

request=$(resolve_xcode_request_with_native_arch macosx macosx14.0 arm64)
eval "$request"
assert_eq "native arch fallback macOS target" aarch64-apple-darwin "$MACOS_TARGETS"

request=$(resolve_xcode_request_with_undefined_current_arch macosx macosx14.0 arm64)
eval "$request"
assert_eq "undefined current arch fallback macOS target" aarch64-apple-darwin "$MACOS_TARGETS"

if resolve_xcode_request iphoneos iphoneos17.0 x86_64 >/dev/null 2>&1; then
	fail "iphoneos x86_64 should be rejected"
fi

request=$(cpsl_apple_request_from_build_vars ios "" aarch64-apple-ios-sim "")
eval "$request"
assert_eq "manual sim-only device targets" "" "$IOS_DEVICE_TARGETS"
assert_eq "manual sim-only simulator targets" aarch64-apple-ios-sim "$IOS_SIMULATOR_TARGETS"

request=$(cpsl_apple_request_from_build_vars macos aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin)
eval "$request"
assert_eq "manual mac-only platforms" macos "$APPLE_PLATFORMS"
assert_eq "manual mac-only ignores iOS device" "" "$IOS_DEVICE_TARGETS"
assert_eq "manual mac-only ignores iOS simulator" "" "$IOS_SIMULATOR_TARGETS"
assert_eq "manual mac-only target" aarch64-apple-darwin "$MACOS_TARGETS"

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cpsl-xcframework-test.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
info="$tmp_dir/Info.plist"
cat >"$info" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
<key>AvailableLibraries</key>
<array>
<dict>
<key>LibraryIdentifier</key>
<string>ios-arm64-simulator</string>
<key>SupportedArchitectures</key>
<array>
<string>arm64</string>
</array>
<key>SupportedPlatform</key>
<string>ios</string>
<key>SupportedPlatformVariant</key>
<string>simulator</string>
</dict>
<dict>
<key>LibraryIdentifier</key>
<string>macos-x86_64</string>
<key>SupportedArchitectures</key>
<array>
<string>x86_64</string>
</array>
<key>SupportedPlatform</key>
<string>macos</string>
</dict>
</array>
</dict>
</plist>
EOF

cpsl_xcframework_satisfies_targets "$info" "" "aarch64-apple-ios-sim" "" || \
	fail "Info.plist should satisfy arm64 simulator"
cpsl_xcframework_satisfies_targets "$info" "" "" "x86_64-apple-darwin" || \
	fail "Info.plist should satisfy x86_64 macOS"
if cpsl_xcframework_satisfies_targets "$info" "" "x86_64-apple-ios" ""; then
	fail "Info.plist should not satisfy x86_64 simulator"
fi
if cpsl_xcframework_satisfies_targets "$info" "aarch64-apple-ios" "" ""; then
	fail "Info.plist should not satisfy iOS device"
fi

source_a="$tmp_dir/source-a"
source_b="$tmp_dir/source-b"
mkdir -p "$source_a" "$source_b"
stamp="$tmp_dir/source.stamp"
cpsl_xcframework_write_source_stamp_value "$stamp" "$source_a" rev-a
cpsl_xcframework_source_stamp_matches_value "$stamp" "$source_a" rev-a || \
	fail "source stamp should match same source and revision"
if cpsl_xcframework_source_stamp_matches_value "$stamp" "$source_b" rev-a; then
	fail "source stamp should reject different source path"
fi
if cpsl_xcframework_source_stamp_matches_value "$stamp" "$source_a" rev-b; then
	fail "source stamp should reject different source revision"
fi

lipo_stub="$tmp_dir/lipo"
cat >"$lipo_stub" <<'EOF'
#!/bin/sh
if [ "$1" != "-archs" ]; then
	exit 2
fi
cat "$2"
EOF
chmod +x "$lipo_stub"
pdfium_root="$tmp_dir/pdfium"
mkdir -p \
	"$pdfium_root/ios-arm64/lib" \
	"$pdfium_root/ios-simulator/lib" \
	"$pdfium_root/macos/lib"
printf '%s\n' arm64 >"$pdfium_root/ios-arm64/lib/libpdfium.dylib"
printf '%s\n' arm64 >"$pdfium_root/ios-simulator/lib/libpdfium.dylib"
printf '%s\n' x86_64 >"$pdfium_root/macos/lib/libpdfium.dylib"
CPSL_LIPO=$lipo_stub
export CPSL_LIPO
cpsl_pdfium_satisfies_targets "$pdfium_root" "aarch64-apple-ios" "aarch64-apple-ios-sim" "x86_64-apple-darwin" || \
	fail "PDFium should satisfy requested archs"
if cpsl_pdfium_satisfies_targets "$pdfium_root" "" "x86_64-apple-ios" ""; then
	fail "PDFium should reject missing simulator x86_64"
fi
if cpsl_pdfium_satisfies_targets "$pdfium_root" "" "" "aarch64-apple-darwin"; then
	fail "PDFium should reject missing macOS arm64"
fi
unset CPSL_LIPO

printf '%s\n' "CPSL XCFramework helper tests passed"
