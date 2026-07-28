#!/bin/sh
set -eu

fail() {
	printf '%s\n' "error: $*" >&2
	exit 1
}

assert_contains() {
	name=$1
	pattern=$2
	path=$3

	grep -F "$pattern" "$path" >/dev/null || fail "$name: missing '$pattern' in $path"
}

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
repo_root=$(CDPATH= cd "$script_dir/.." && pwd -P)
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cpsl-apple-build-integration.XXXXXX")
cleanup() {
	status=$?
	rm -rf "$tmp_dir"
	exit "$status"
}
trap cleanup EXIT HUP INT TERM

fixture_root="$tmp_dir/herm"
fixture_scripts="$fixture_root/scripts"
cpsl_root="$fixture_root/external/cpsl"
fake_bin="$tmp_dir/bin"
fake_state="$tmp_dir/state"
work_dir="$tmp_dir/work"
home_dir="$tmp_dir/home"

mkdir -p \
	"$fixture_scripts/lib" \
	"$fixture_scripts/cpsl-patches" \
	"$cpsl_root/ffi/include" \
	"$cpsl_root/ffi/src" \
	"$cpsl_root/core/scripts" \
	"$fake_bin" \
	"$fake_state" \
	"$home_dir" \
	"$tmp_dir/sdks/iphoneos" \
	"$tmp_dir/sdks/iphonesimulator" \
	"$tmp_dir/sdks/macosx"

for path in \
	scripts/build-cpsl-apple-xcframework.sh \
	scripts/ensure-cpsl-apple-xcframework.sh \
	scripts/apply-cpsl-patches.sh \
	scripts/lib/build-manifest.sh \
	scripts/lib/cpsl-apple-build-state.sh \
	scripts/lib/cpsl-xcframework.sh \
	scripts/lib/host-path.sh
do
	cp "$repo_root/$path" "$fixture_root/$path"
done
cp "$repo_root/rust-toolchain.toml" "$fixture_root/rust-toolchain.toml"
for path in .bazelrc .bazelversion BUILD.bazel MODULE.bazel MODULE.bazel.lock; do
	cp "$repo_root/$path" "$fixture_root/$path"
done
cp -R "$repo_root/bazel" "$fixture_root/bazel"
printf '%s\n' '# no integration patches in the synthetic CPSL fixture' \
	>"$fixture_scripts/cpsl-patches/series"

printf '%s\n' '[workspace]' 'members = ["ffi"]' >"$cpsl_root/Cargo.toml"
printf '%s\n' '[package]' 'name = "cpsl-ffi"' 'version = "0.1.0"' >"$cpsl_root/ffi/Cargo.toml"
printf '%s\n' 'void cpsl_fixture(void);' >"$cpsl_root/ffi/include/cpsl.h"
printf '%s\n' 'allow_webview_pdf_rendering(webview_pdf_rendering_allowed(config))' \
	>"$cpsl_root/ffi/src/lib.rs"

cat >"$cpsl_root/core/scripts/download-pdfium.sh" <<'EOF'
#!/bin/sh
set -eu

target=
output=
while [ "$#" -gt 0 ]; do
	case "$1" in
	--version) shift ;;
	--target) shift; target=$1 ;;
	--output) shift; output=$1 ;;
	esac
	shift
done

case "$target" in
ios-device-arm64 | ios-simulator-arm64) arches=arm64 ;;
ios-simulator-x64) arches=x86_64 ;;
mac-univ) arches="arm64 x86_64" ;;
*) printf '%s\n' "unsupported fake PDFium target: $target" >&2; exit 1 ;;
esac
mkdir -p "$output/lib"
printf '%s\n' "$arches" >"$output/lib/libpdfium.dylib"
EOF
chmod +x "$cpsl_root/core/scripts/download-pdfium.sh"

cat >"$fake_bin/uname" <<'EOF'
#!/bin/sh
case "${1:-}" in
-s) printf '%s\n' Darwin ;;
-m) printf '%s\n' arm64 ;;
*) printf '%s\n' Darwin ;;
esac
EOF

cat >"$fake_bin/rustc" <<'EOF'
#!/bin/sh
case "${1:-}" in
-vV) printf '%s\n' 'rustc 1.95.0 (fake)' 'host: aarch64-apple-darwin' ;;
*) printf '%s\n' 'rustc 1.95.0 (fake)' ;;
esac
EOF

cat >"$fake_bin/cargo" <<'EOF'
#!/bin/sh
set -eu

if [ "${1:-}" = --version ]; then
	printf '%s\n' 'cargo 1.95.0 (fake)'
	exit 0
fi

target_dir=
target=
profile=debug
while [ "$#" -gt 0 ]; do
	case "$1" in
	--target-dir) shift; target_dir=$1 ;;
	--target) shift; target=$1 ;;
	--release) profile=release ;;
	esac
	shift
done

case "$target" in
aarch64-apple-ios | aarch64-apple-ios-sim | aarch64-apple-darwin) arch=arm64 ;;
x86_64-apple-ios | x86_64-apple-darwin) arch=x86_64 ;;
*) printf '%s\n' "unsupported fake Cargo target: $target" >&2; exit 1 ;;
esac
[ -n "$target_dir" ] || exit 1
mkdir -p "$target_dir/$target/$profile"
printf '%s\n' "$arch" >"$target_dir/$target/$profile/libcpsl.dylib"
printf '%s\t%s\t%s\n' "$target" "$profile" "${CARGO_INCREMENTAL:-unset}" \
	>>"$FAKE_TOOL_STATE/cargo.log"
EOF

cat >"$fake_bin/bazel" <<'EOF'
#!/bin/sh
set -eu

if [ "${1:-}" = --version ]; then
	printf '%s\n' 'bazel 8.4.2 (fake)'
	exit 0
fi

[ "${1:-}" != mod ] || exit 0
[ "${1:-}" = build ] || exit 1
platform=
mode=
config=
symlink_prefix=
for arg in "$@"; do
	case "$arg" in
	--platforms=*) platform=${arg#*=} ;;
	--compilation_mode=*) mode=${arg#*=} ;;
	--config=*) config=${arg#*=} ;;
	--symlink_prefix=*) symlink_prefix=${arg#*=} ;;
	esac
done
case "$platform" in
//bazel/platforms:ios_arm64 | //bazel/platforms:ios_sim_arm64 | //bazel/platforms:macos_arm64) arch=arm64 ;;
//bazel/platforms:ios_sim_x86_64 | //bazel/platforms:macos_x86_64) arch=x86_64 ;;
*) printf '%s\n' "unsupported fake Bazel platform: $platform" >&2; exit 1 ;;
esac
[ -n "$symlink_prefix" ] || exit 1
mkdir -p "${symlink_prefix}bin"
printf '%s\n' "$arch" >"${symlink_prefix}bin/libcpsl.dylib"
printf '%s\t%s\t%s\n' "$platform" "$mode" "$config" >>"$FAKE_TOOL_STATE/bazel.log"
EOF

cat >"$fake_bin/rustup" <<'EOF'
#!/bin/sh
if [ "${1:-}" = target ] && [ "${2:-}" = list ] && [ "${3:-}" = --installed ]; then
	printf '%s\n' \
		aarch64-apple-ios \
		aarch64-apple-ios-sim \
		x86_64-apple-ios \
		aarch64-apple-darwin \
		x86_64-apple-darwin
	exit 0
fi
exit 1
EOF

cat >"$fake_bin/xcode-select" <<'EOF'
#!/bin/sh
[ "${1:-}" = -p ] || exit 1
printf '%s\n' "$FAKE_DEVELOPER_DIR"
EOF

cat >"$fake_bin/xcrun" <<'EOF'
#!/bin/sh
set -eu

if [ "${1:-}" = --sdk ]; then
	sdk=$2
	action=$3
	case "$action" in
	--show-sdk-path) printf '%s/%s\n' "$FAKE_SDK_ROOT" "$sdk" ;;
	--find) printf '%s/%s\n' "$FAKE_BIN" "$4" ;;
	*) exit 1 ;;
	esac
	exit 0
fi
if [ "${1:-}" = clang ] && [ "${2:-}" = --version ]; then
	printf '%s\n' 'Apple clang version 21.0.0 (fake)'
	exit 0
fi
if [ "${1:-}" = lipo ]; then
	shift
	exec "$FAKE_BIN/lipo" "$@"
fi
exit 1
EOF

cat >"$fake_bin/lipo" <<'EOF'
#!/bin/sh
set -eu

if [ "${1:-}" = -archs ]; then
	cat "$2"
	exit 0
fi
[ "${1:-}" = -create ] || exit 1
shift
inputs=
output=
while [ "$#" -gt 0 ]; do
	case "$1" in
	-output) shift; output=$1 ;;
	*) inputs="${inputs:+$inputs }$1" ;;
	esac
	shift
done
[ -n "$output" ] || exit 1
arches=
for input in $inputs; do
	for arch in $(cat "$input"); do
		case " $arches " in
		*" $arch "*) ;;
		*) arches="${arches:+$arches }$arch" ;;
		esac
	done
done
mkdir -p "$(dirname "$output")"
printf '%s\n' "$arches" >"$output"
EOF

cat >"$fake_bin/xcodebuild" <<'EOF'
#!/bin/sh
set -eu

if [ "${1:-}" = -version ]; then
	printf '%s\n' 'Xcode 26.5' 'Build version 17F90'
	exit 0
fi
[ "${1:-}" = -create-xcframework ] || exit 1
shift
records="$FAKE_TOOL_STATE/xcframework-inputs"
: >"$records"
library=
output=
while [ "$#" -gt 0 ]; do
	case "$1" in
	-library) shift; library=$1 ;;
	-headers) shift; printf '%s|%s\n' "$library" "$1" >>"$records" ;;
	-output) shift; output=$1 ;;
	esac
	shift
done
[ -n "$output" ] || exit 1
rm -rf "$output"
mkdir -p "$output"
info="$output/Info.plist"
printf '%s\n' '<?xml version="1.0"?><plist version="1.0"><dict><key>AvailableLibraries</key><array>' >"$info"
while IFS='|' read -r library headers; do
	slice=$(basename "$(dirname "$library")")
	arches=$(cat "$library")
	arch_id=$(printf '%s' "$arches" | tr ' ' '_')
	case "$slice" in
	ios-arm64) identifier="ios-$arch_id"; platform=ios; variant= ;;
	ios-simulator) identifier="ios-$arch_id-simulator"; platform=ios; variant=simulator ;;
	macos) identifier="macos-$arch_id"; platform=macos; variant= ;;
	*) exit 1 ;;
	esac
	mkdir -p "$output/$identifier/Headers"
	cp "$headers/cpsl.h" "$output/$identifier/Headers/cpsl.h"
	cp "$headers/module.modulemap" "$output/$identifier/Headers/module.modulemap"
	cp "$library" "$output/$identifier/libcpsl.dylib"
	{
		printf '%s\n' '<dict><key>LibraryIdentifier</key>' "<string>$identifier</string>"
		printf '%s\n' '<key>SupportedArchitectures</key><array>'
		for arch in $arches; do printf '<string>%s</string>\n' "$arch"; done
		printf '%s\n' '</array><key>SupportedPlatform</key>' "<string>$platform</string>"
		if [ -n "$variant" ]; then
			printf '%s\n' '<key>SupportedPlatformVariant</key>' "<string>$variant</string>"
		fi
		printf '%s\n' '</dict>'
	} >>"$info"
done <"$records"
printf '%s\n' '</array></dict></plist>' >>"$info"
EOF

for tool in clang clang++ ar; do
	cat >"$fake_bin/$tool" <<'EOF'
#!/bin/sh
exit 0
EOF
done
chmod +x "$fake_bin"/*

export FAKE_BIN="$fake_bin"
export FAKE_DEVELOPER_DIR="$tmp_dir/Developer"
export FAKE_SDK_ROOT="$tmp_dir/sdks"
export FAKE_TOOL_STATE="$fake_state"
mkdir -p "$FAKE_DEVELOPER_DIR"

run_ensure() {
	configuration=$1
	simulator_targets=$2
	log_path=$3
	build_system=${4:-bazel}

	if ! HOME="$home_dir" \
	PATH="$fake_bin:/usr/bin:/bin" \
	BAZEL="$fake_bin/bazel" \
	CPSL_ROOT="$cpsl_root" \
	CPSL_WORK_DIR="$work_dir" \
	APPLE_PLATFORMS=ios \
	IOS_DEVICE_TARGETS= \
	IOS_SIMULATOR_TARGETS="$simulator_targets" \
	MACOS_TARGETS= \
	CONFIGURATION="$configuration" \
	CPSL_APPLE_BUILD_SYSTEM="$build_system" \
		"$fixture_scripts/ensure-cpsl-apple-xcframework.sh" >"$log_path" 2>&1; then
		cat "$log_path" >&2
		fail "$configuration $build_system ensure failed"
	fi
}

debug_first="$tmp_dir/debug-first.log"
debug_second="$tmp_dir/debug-second.log"
debug_corrupt="$tmp_dir/debug-corrupt.log"
debug_stale="$tmp_dir/debug-stale.log"
debug_arch="$tmp_dir/debug-arch.log"
release_first="$tmp_dir/release-first.log"
release_second="$tmp_dir/release-second.log"
cargo_fallback="$tmp_dir/cargo-fallback.log"

run_ensure Debug aarch64-apple-ios-sim "$debug_first"
assert_contains "initial Debug build" "Building CPSL Apple XCFramework" "$debug_first"
assert_contains "Debug Bazel mode" '//bazel/platforms:ios_sim_arm64	dbg	cpsl-apple' "$fake_state/bazel.log"
debug_bazel_count=$(wc -l <"$fake_state/bazel.log" | tr -d '[:space:]')

run_ensure Debug aarch64-apple-ios-sim "$debug_second"
assert_contains "warm Debug build" "Using existing CPSL XCFramework" "$debug_second"
[ "$(wc -l <"$fake_state/bazel.log" | tr -d '[:space:]')" = "$debug_bazel_count" ] || \
	fail "warm Debug build unexpectedly invoked Bazel"

printf '%s\n' x86_64 \
	>"$work_dir/artifacts/apple/Debug/cpsl.xcframework/ios-arm64-simulator/libcpsl.dylib"
run_ensure Debug aarch64-apple-ios-sim "$debug_corrupt"
assert_contains "invalid binary rebuild" "missing or invalid CPSL binaries" "$debug_corrupt"

printf '%s\n' '// source changed' >>"$cpsl_root/ffi/src/lib.rs"
run_ensure Debug aarch64-apple-ios-sim "$debug_stale"
assert_contains "stale source rebuild" "CPSL build identity changed" "$debug_stale"

run_ensure Debug x86_64-apple-ios "$debug_arch"
assert_contains "architecture switch rebuild" "CPSL build identity changed" "$debug_arch"
assert_contains "x86_64 Bazel platform" '//bazel/platforms:ios_sim_x86_64	dbg	cpsl-apple' "$fake_state/bazel.log"
debug_info="$work_dir/artifacts/apple/Debug/cpsl.xcframework/Info.plist"
. "$fixture_scripts/lib/cpsl-xcframework.sh"
cpsl_xcframework_matches_targets "$debug_info" "" x86_64-apple-ios "" || \
	fail "Debug XCFramework did not exactly switch to x86_64 simulator"

run_ensure Release aarch64-apple-ios-sim "$release_first"
assert_contains "initial Release build" "Building CPSL Apple XCFramework" "$release_first"
assert_contains "Release Bazel mode" '//bazel/platforms:ios_sim_arm64	opt	cpsl-apple' "$fake_state/bazel.log"
release_bazel_count=$(wc -l <"$fake_state/bazel.log" | tr -d '[:space:]')

run_ensure Release aarch64-apple-ios-sim "$release_second"
assert_contains "warm Release build" "Using existing CPSL XCFramework" "$release_second"
[ "$(wc -l <"$fake_state/bazel.log" | tr -d '[:space:]')" = "$release_bazel_count" ] || \
	fail "warm Release build unexpectedly invoked Bazel"

debug_stamp="$work_dir/artifacts/apple/Debug/.cpsl-apple-build.stamp"
release_stamp="$work_dir/artifacts/apple/Release/.cpsl-apple-build.stamp"
assert_contains "Debug stamp build system" 'build_system=bazel' "$debug_stamp"
assert_contains "Debug stamp mode" 'bazel_compilation_mode=dbg' "$debug_stamp"
assert_contains "Release stamp build system" 'build_system=bazel' "$release_stamp"
assert_contains "Release stamp mode" 'bazel_compilation_mode=opt' "$release_stamp"

run_ensure Debug aarch64-apple-ios-sim "$cargo_fallback" cargo
assert_contains "Cargo fallback rebuild" "Building CPSL Apple XCFramework" "$cargo_fallback"
assert_contains "Cargo fallback profile" 'aarch64-apple-ios-sim	debug	1' "$fake_state/cargo.log"
assert_contains "Cargo fallback stamp" 'build_system=cargo' "$debug_stamp"

printf '%s\n' "CPSL Apple build integration tests passed"
