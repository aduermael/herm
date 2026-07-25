#!/bin/sh
set -eu

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
. "$script_dir/lib/cpsl-xcframework.sh"
. "$script_dir/lib/cpsl-apple-build-state.sh"

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

project_file="$script_dir/../app/apple/herm.xcodeproj/project.pbxproj"
build_phase=$(sed -n '/85A100072FEA000000000007 \/\* Build CPSL XCFramework \*\/ = {/,/^\t\t};/p' "$project_file")
case "$build_phase" in
*'alwaysOutOfDate = 1;'*) ;;
*) fail "Build CPSL XCFramework phase must run on every Xcode build" ;;
esac

for launcher in "$script_dir/dev-apple-ios.sh" "$script_dir/dev-apple-macos.sh"; do
	if grep -q '^export HERM_CPSL_REBUILD' "$launcher"; then
		fail "launcher must not export HERM_CPSL_REBUILD into xcodebuild: $launcher"
	fi
	grep -q 'HERM_CPSL_REBUILD=1 PLATFORM_NAME=' "$launcher" || \
		fail "launcher must scope forced CPSL rebuild to preflight: $launcher"
done

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

assert_eq "default Apple build system" bazel "$(unset CPSL_APPLE_BUILD_SYSTEM; cpsl_apple_build_system_from_environment)"
assert_eq "explicit Cargo fallback" cargo "$(CPSL_APPLE_BUILD_SYSTEM=cargo cpsl_apple_build_system_from_environment)"
assert_eq "Debug Bazel mode" dbg "$(cpsl_apple_bazel_compilation_mode_from_configuration Debug)"
assert_eq "Release Bazel mode" opt "$(cpsl_apple_bazel_compilation_mode_from_configuration Release)"
assert_eq "iOS device Bazel platform" //bazel/platforms:ios_arm64 \
	"$(cpsl_apple_bazel_platform_for_rust_target aarch64-apple-ios)"
assert_eq "iOS simulator Bazel platform" //bazel/platforms:ios_sim_x86_64 \
	"$(cpsl_apple_bazel_platform_for_rust_target x86_64-apple-ios)"
assert_eq "macOS Bazel platform" //bazel/platforms:macos_arm64 \
	"$(cpsl_apple_bazel_platform_for_rust_target aarch64-apple-darwin)"

assert_eq "debug configuration cargo profile" debug "$(cpsl_apple_cargo_profile_from_configuration Debug)"
assert_eq "release configuration cargo profile" release "$(cpsl_apple_cargo_profile_from_configuration Release)"
assert_eq "default cargo profile" release "$(cpsl_apple_cargo_profile_from_configuration "")"
if cpsl_apple_cargo_profile_from_configuration Staging >/dev/null 2>&1; then
	fail "unsupported configuration should be rejected"
fi

incremental=$(unset CARGO_INCREMENTAL; CONFIGURATION=Debug cpsl_apple_cargo_incremental_from_environment)
assert_eq "Debug Cargo incremental setting" 1 "$incremental"
incremental=$(unset CARGO_INCREMENTAL; CONFIGURATION=Release cpsl_apple_cargo_incremental_from_environment)
assert_eq "Release Cargo incremental setting" 0 "$incremental"
incremental=$(unset CARGO_INCREMENTAL CONFIGURATION; cpsl_apple_cargo_incremental_from_environment)
assert_eq "manual Cargo incremental setting" 0 "$incremental"
incremental=$(CARGO_INCREMENTAL=1 cpsl_apple_cargo_incremental_from_environment)
assert_eq "explicit Cargo incremental setting" 1 "$incremental"
if CARGO_INCREMENTAL=invalid cpsl_apple_cargo_incremental_from_environment >/dev/null 2>&1; then
	fail "invalid Cargo incremental setting should be rejected"
fi

cache_namespace=$(cpsl_apple_cargo_cache_namespace_content rustc-test cargo-test xcode-test)
assert_eq "stable Cargo cache namespace" "$cache_namespace" \
	"$(cpsl_apple_cargo_cache_namespace_content rustc-test cargo-test xcode-test)"
changed_cache_namespace=$(cpsl_apple_cargo_cache_namespace_content rustc-new cargo-test xcode-test)
if [ "$cache_namespace" = "$changed_cache_namespace" ]; then
	fail "Cargo cache namespace should change with the Rust toolchain"
fi
changed_cache_namespace=$(cpsl_apple_cargo_cache_namespace_content rustc-test cargo-test xcode-new)
if [ "$cache_namespace" = "$changed_cache_namespace" ]; then
	fail "Cargo cache namespace should change with Xcode"
fi

artifact_dir=$(CONFIGURATION=Debug cpsl_apple_default_artifact_dir /tmp/cpsl-work)
assert_eq "debug artifact dir" /tmp/cpsl-work/artifacts/apple/Debug "$artifact_dir"
artifact_dir=$(CONFIGURATION=Release cpsl_apple_default_artifact_dir /tmp/cpsl-work)
assert_eq "release artifact dir" /tmp/cpsl-work/artifacts/apple/Release "$artifact_dir"
artifact_dir=$(unset CONFIGURATION; cpsl_apple_default_artifact_dir /tmp/cpsl-work)
assert_eq "manual artifact dir" /tmp/cpsl-work/artifacts/apple "$artifact_dir"

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cpsl-xcframework-test.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

identity_root="$tmp_dir/identity-root"
identity_source="$identity_root/source"
mkdir -p "$identity_root/scripts/lib" "$identity_root/scripts/cpsl-patches" "$identity_source"
for identity_input in \
	rust-toolchain.toml \
	scripts/build-cpsl-apple-xcframework.sh \
	scripts/apply-cpsl-patches.sh \
	scripts/lib/build-manifest.sh \
	scripts/lib/cpsl-apple-build-state.sh \
	scripts/lib/cpsl-xcframework.sh \
	scripts/lib/host-path.sh
do
	mkdir -p "$(dirname "$identity_root/$identity_input")"
	printf '%s\n' "$identity_input" >"$identity_root/$identity_input"
done
printf '%s\n' 0001-test.patch >"$identity_root/scripts/cpsl-patches/series"
printf '%s\n' patch-v1 >"$identity_root/scripts/cpsl-patches/0001-test.patch"
printf '%s\n' source-v1 >"$identity_source/input.rs"
APPLE_PLATFORMS=ios
IOS_DEVICE_TARGETS=
IOS_SIMULATOR_TARGETS=aarch64-apple-ios-sim
MACOS_TARGETS=
CONFIGURATION=Debug
export APPLE_PLATFORMS IOS_DEVICE_TARGETS IOS_SIMULATOR_TARGETS MACOS_TARGETS CONFIGURATION
identity=$(cpsl_apple_build_stamp_content \
	"$identity_root" "$identity_source" apple-app debug 1 rustc-test cargo-test xcode-test cargo unused unused)
identity_stamp=$(cpsl_apple_build_stamp_path "$identity_root/out")
cpsl_apple_build_stamp_write_value "$identity_stamp" "$identity"
cpsl_apple_build_stamp_matches_value "$identity_stamp" "$identity" || \
	fail "build identity should match unchanged inputs"
touch "$identity_source/input.rs"
unchanged_identity=$(cpsl_apple_build_stamp_content \
	"$identity_root" "$identity_source" apple-app debug 1 rustc-test cargo-test xcode-test cargo unused unused)
cpsl_apple_build_stamp_matches_value "$identity_stamp" "$unchanged_identity" || \
	fail "build identity should ignore mtime-only changes"
printf '%s\n' unlisted >"$identity_root/scripts/cpsl-patches/local-only.patch"
unchanged_identity=$(cpsl_apple_build_stamp_content \
	"$identity_root" "$identity_source" apple-app debug 1 rustc-test cargo-test xcode-test cargo unused unused)
cpsl_apple_build_stamp_matches_value "$identity_stamp" "$unchanged_identity" || \
	fail "build identity should ignore patches absent from the ordered series"
IOS_SIMULATOR_TARGETS=x86_64-apple-ios
changed_identity=$(cpsl_apple_build_stamp_content \
	"$identity_root" "$identity_source" apple-app debug 1 rustc-test cargo-test xcode-test cargo unused unused)
if cpsl_apple_build_stamp_matches_value "$identity_stamp" "$changed_identity"; then
	fail "build identity should reject a different exact architecture"
fi
IOS_SIMULATOR_TARGETS=aarch64-apple-ios-sim
changed_identity=$(cpsl_apple_build_stamp_content \
	"$identity_root" "$identity_source" minimum debug 1 rustc-test cargo-test xcode-test cargo unused unused)
if cpsl_apple_build_stamp_matches_value "$identity_stamp" "$changed_identity"; then
	fail "build identity should reject a different CPSL feature profile"
fi
changed_identity=$(cpsl_apple_build_stamp_content \
	"$identity_root" "$identity_source" apple-app debug 1 rustc-new cargo-test xcode-test cargo unused unused)
if cpsl_apple_build_stamp_matches_value "$identity_stamp" "$changed_identity"; then
	fail "build identity should reject a different Rust toolchain"
fi
printf '%s\n' source-v2 >"$identity_source/input.rs"
changed_identity=$(cpsl_apple_build_stamp_content \
	"$identity_root" "$identity_source" apple-app debug 1 rustc-test cargo-test xcode-test cargo unused unused)
if cpsl_apple_build_stamp_matches_value "$identity_stamp" "$changed_identity"; then
	fail "build identity should reject changed CPSL source content"
fi
printf '%s\n' source-v1 >"$identity_source/input.rs"
printf '%s\n' patch-v2 >"$identity_root/scripts/cpsl-patches/0001-test.patch"
changed_identity=$(cpsl_apple_build_stamp_content \
	"$identity_root" "$identity_source" apple-app debug 1 rustc-test cargo-test xcode-test cargo unused unused)
if cpsl_apple_build_stamp_matches_value "$identity_stamp" "$changed_identity"; then
	fail "build identity should reject changed listed patch content"
fi
unset APPLE_PLATFORMS IOS_DEVICE_TARGETS IOS_SIMULATOR_TARGETS MACOS_TARGETS CONFIGURATION

patch_fixture="$tmp_dir/patch-fixture"
patch_scripts="$patch_fixture/scripts"
patch_checkout="$patch_fixture/cpsl"
mkdir -p "$patch_scripts/cpsl-patches" "$patch_checkout/ffi/src"
cp "$script_dir/apply-cpsl-patches.sh" "$patch_scripts/apply-cpsl-patches.sh"
printf '%s\n' '# ordered patches' '' '0001-test.patch' >"$patch_scripts/cpsl-patches/series"
cat >"$patch_scripts/cpsl-patches/0001-test.patch" <<'EOF'
diff --git a/value.txt b/value.txt
--- a/value.txt
+++ b/value.txt
@@ -1 +1 @@
-old
+new
EOF
printf '%s\n' 'this is not a patch' >"$patch_scripts/cpsl-patches/0002-local-copy 2.patch"
printf '%s\n' old >"$patch_checkout/value.txt"
printf '%s\n' 'allow_webview_pdf_rendering(webview_pdf_rendering_allowed(config))' \
	>"$patch_checkout/ffi/src/lib.rs"
git -C "$patch_checkout" init --quiet
git -C "$patch_checkout" add value.txt
apply_output=$(sh "$patch_scripts/apply-cpsl-patches.sh" "$patch_checkout")
assert_eq "listed patch application" new "$(cat "$patch_checkout/value.txt")"
case "$apply_output" in
	*"Applying CPSL patch: 0001-test.patch"*) ;;
	*) fail "listed patch should be applied" ;;
esac
apply_output=$(sh "$patch_scripts/apply-cpsl-patches.sh" "$patch_checkout")
case "$apply_output" in
	*"CPSL patch already applied: 0001-test.patch"*) ;;
	*) fail "listed patch should be idempotent" ;;
esac
printf '%s\n' missing.patch >"$patch_scripts/cpsl-patches/series"
if sh "$patch_scripts/apply-cpsl-patches.sh" "$patch_checkout" >/dev/null 2>&1; then
	fail "missing listed patch should be rejected"
fi
printf '%s\n' '# no patches' >"$patch_scripts/cpsl-patches/series"
printf '%s\n' 'missing required policy' >"$patch_checkout/ffi/src/lib.rs"
if sh "$patch_scripts/apply-cpsl-patches.sh" "$patch_checkout" >/dev/null 2>&1; then
	fail "CPSL checkout without the PDF network policy should be rejected"
fi

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
cpsl_xcframework_matches_targets "$info" "" aarch64-apple-ios-sim x86_64-apple-darwin || \
	fail "Info.plist should exactly match its simulator and macOS architectures"
if cpsl_xcframework_matches_targets "$info" "" aarch64-apple-ios-sim ""; then
	fail "exact target matching should reject an extra macOS slice"
fi

compact_info="$tmp_dir/CompactInfo.plist"
cat >"$compact_info" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>AvailableLibraries</key><array>
<dict><key>LibraryIdentifier</key><string>macos-arm64_x86_64</string><key>SupportedArchitectures</key><array><string>arm64</string><string>x86_64</string></array><key>SupportedPlatform</key><string>macos</string></dict>
<dict><key>LibraryIdentifier</key><string>ios-arm64_x86_64-simulator</string><key>SupportedArchitectures</key><array><string>arm64</string><string>x86_64</string></array><key>SupportedPlatform</key><string>ios</string><key>SupportedPlatformVariant</key><string>simulator</string></dict>
<dict><key>LibraryIdentifier</key><string>ios-arm64</string><key>SupportedArchitectures</key><array><string>arm64</string></array><key>SupportedPlatform</key><string>ios</string></dict>
</array></dict></plist>
EOF
cpsl_xcframework_is_full "$compact_info" || \
	fail "compact Info.plist should satisfy full XCFramework checks"
cpsl_xcframework_satisfies_targets "$compact_info" "aarch64-apple-ios" "aarch64-apple-ios-sim x86_64-apple-ios" "aarch64-apple-darwin x86_64-apple-darwin" || \
	fail "compact Info.plist should satisfy all Apple targets"
cpsl_xcframework_matches_targets "$compact_info" "aarch64-apple-ios" "aarch64-apple-ios-sim x86_64-apple-ios" "aarch64-apple-darwin x86_64-apple-darwin" || \
	fail "compact Info.plist should exactly match all Apple targets"

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

binary_xcframework="$tmp_dir/binary-cpsl.xcframework"
mkdir -p \
	"$binary_xcframework/ios-arm64_x86_64-simulator/Headers" \
	"$binary_xcframework/macos-arm64_x86_64/Headers"
cp "$compact_info" "$binary_xcframework/Info.plist"
for binary_slice in ios-arm64_x86_64-simulator macos-arm64_x86_64; do
	printf '%s\n' header >"$binary_xcframework/$binary_slice/Headers/cpsl.h"
	printf '%s\n' module >"$binary_xcframework/$binary_slice/Headers/module.modulemap"
done
printf '%s\n' arm64 >"$binary_xcframework/ios-arm64_x86_64-simulator/libcpsl.dylib"
printf '%s\n' x86_64 >"$binary_xcframework/macos-arm64_x86_64/libcpsl.dylib"
CPSL_LIPO=$lipo_stub
export CPSL_LIPO
cpsl_xcframework_binaries_satisfy_targets \
	"$binary_xcframework" "" aarch64-apple-ios-sim x86_64-apple-darwin || \
	fail "XCFramework binaries should satisfy matching requested architectures"
printf '%s\n' x86_64 >"$binary_xcframework/ios-arm64_x86_64-simulator/libcpsl.dylib"
if cpsl_xcframework_binaries_satisfy_targets \
	"$binary_xcframework" "" aarch64-apple-ios-sim ""; then
	fail "XCFramework binary validation should reject an advertised but missing architecture"
fi
unset CPSL_LIPO

cpsl_xcode_arch_list_contains arm64 arm64 || fail "arch list should contain arm64"
if cpsl_xcode_arch_list_contains arm64 x86_64; then
	fail "arch list should not contain x86_64"
fi
missing_arches=
lib_arches=arm64
for arch in arm64 x86_64; do
	if ! cpsl_xcode_arch_list_contains "$lib_arches" "$arch"; then
		missing_arches="${missing_arches:+$missing_arches }$arch"
	fi
done
assert_eq "missing placeholder arches" x86_64 "$missing_arches"

printf '%s\n' "CPSL XCFramework helper tests passed"
