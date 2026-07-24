#!/bin/sh
set -eu

die() {
	printf '%s\n' "error: $*" >&2
	exit 1
}

need_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		if [ -n "${2:-}" ]; then
			die "$1 is required; $2"
		fi
		die "$1 is required"
	fi
}

usage() {
	cat <<EOF
Usage:
  build-cpsl-apple-xcframework.sh [--apple-app|--minimum]

Builds one CPSL XCFramework for Apple app targets.

By default this script builds CPSL with Bazel from Herm's external/cpsl
submodule. The output is one Apple-consumable
XCFramework containing the requested iOS device, iOS simulator, and/or macOS
slices.

Options:
  --apple-app Build the expanded iOS/macOS app profile. This is the default.
  --minimum   Build the minimal CPSL FFI profile.
  -h, --help  Show this help.

Environment:
  CPSL_APPLE_BUILD_SYSTEM Build system: bazel (default) or cargo (fallback).
  BAZEL                    Bazel or Bazelisk executable override.
  CPSL_ROOT                Existing CPSL checkout for the Cargo fallback. Bazel
                           builds use Herm's external/cpsl submodule.
  CPSL_WORK_DIR            Gitignored work/artifact root. Defaults to HERM_ROOT/.herm-cpsl.
  CPSL_TARGET_DIR          Cargo fallback target directory override. The default is a
                           toolchain-keyed directory under CPSL_WORK_DIR/cargo-target.
  CARGO_INCREMENTAL       Override Cargo incremental compilation with 0 or 1.
                          Defaults to 1 for Debug and 0 for Release.
  OUT_DIR                  Artifact directory. Defaults to CPSL_WORK_DIR/artifacts/apple,
                           or CPSL_WORK_DIR/artifacts/apple/CONFIGURATION for Xcode builds.
  CONFIGURATION            Xcode configuration. Debug uses Bazel dbg; Release uses Bazel opt.
  APPLE_PLATFORMS          Platforms to include. Defaults to "ios macos".
  IOS_DEPLOYMENT_TARGET    Minimum iOS version. Defaults to 17.0.
  MACOSX_DEPLOYMENT_TARGET Minimum macOS version. Defaults to 14.0.
  IOS_DEVICE_TARGETS       Rust device targets. Defaults to aarch64 iOS.
  IOS_SIMULATOR_TARGETS    Rust simulator targets. Defaults to arm64 and x86_64 simulator.
  MACOS_TARGETS            Rust macOS targets. Defaults to arm64 and x86_64 macOS.
  HERM_CPSL_FORCE_SUBMODULE=1
                           Ignore CPSL_ROOT and build from Herm's external/cpsl submodule.
  PDFIUM_VERSION           PDFium build number. Defaults to CPSL's downloader default.
EOF
}

profile=apple-app
while [ "$#" -gt 0 ]; do
	case "$1" in
	--apple-app)
		profile=apple-app
		;;
	--minimum)
		profile=minimum
		;;
	--all)
		die "--all is not supported for Apple XCFrameworks; use --apple-app for the iOS/macOS app sandbox profile"
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		die "unknown argument: $1"
		;;
	esac
	shift
done

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
herm_root=$(CDPATH= cd "$script_dir/.." && pwd -P)
. "$script_dir/lib/host-path.sh"
. "$script_dir/lib/cpsl-xcframework.sh"
. "$script_dir/lib/cpsl-apple-build-state.sh"
. "$script_dir/lib/build-manifest.sh"
herm_ensure_host_tools_path

[ "$(uname -s)" = Darwin ] || die "Apple XCFramework builds require macOS with Xcode"

work_dir=${CPSL_WORK_DIR:-"$herm_root/.herm-cpsl"}
mkdir -p "$work_dir"
work_dir=$(CDPATH= cd "$work_dir" && pwd -P)
default_cpsl_root="$herm_root/external/cpsl"
target_dir=${CPSL_TARGET_DIR:-}
build_system=$(cpsl_apple_build_system_from_environment) || die "failed to resolve CPSL Apple build system"
bazel_compilation_mode=$(cpsl_apple_bazel_compilation_mode_from_environment) || die "failed to resolve CPSL Bazel compilation mode"
if [ "$build_system" = cargo ]; then
	cargo_profile=$(cpsl_apple_cargo_profile_from_environment) || die "failed to resolve CPSL Cargo profile"
	cargo_incremental=$(cpsl_apple_cargo_incremental_from_environment) || die "failed to resolve CPSL incremental compilation setting"
else
	cargo_profile=unused
	cargo_incremental=unused
fi
out_dir=${OUT_DIR:-$(cpsl_apple_default_artifact_dir "$work_dir")}
ios_deployment_target=${IOS_DEPLOYMENT_TARGET:-${IPHONEOS_DEPLOYMENT_TARGET:-17.0}}
macos_deployment_target=${MACOSX_DEPLOYMENT_TARGET:-14.0}
lib_name=libcpsl.dylib
pdfium_lib_name=libpdfium.dylib
xcframework_name=cpsl.xcframework

request_assignments=$(cpsl_apple_request_from_environment) || die "failed to resolve CPSL Apple build targets"
eval "$request_assignments"
apple_platforms=$APPLE_PLATFORMS
ios_device_targets=$IOS_DEVICE_TARGETS
ios_simulator_targets=$IOS_SIMULATOR_TARGETS
macos_targets=$MACOS_TARGETS

include_ios_device=0
include_ios_simulator=0
include_macos=0
[ -n "$ios_device_targets" ] && include_ios_device=1
[ -n "$ios_simulator_targets" ] && include_ios_simulator=1
[ -n "$macos_targets" ] && include_macos=1

if [ "$build_system" = bazel ]; then
	bazel_command=$(cpsl_apple_bazel_command 2>/dev/null) || \
		die "Bazelisk or Bazel is required; install Bazelisk with: brew install bazelisk"
else
	need_cmd cargo "install Rust from https://rustup.rs, then restart Xcode so run scripts can find ~/.cargo/bin"
	need_cmd rustc "install Rust from https://rustup.rs, then restart Xcode so run scripts can find ~/.cargo/bin"
fi
need_cmd xcode-select "run: xcode-select --install"
need_cmd xcodebuild "install Xcode"
need_cmd xcrun "install Xcode command line tools"
need_cmd lipo "install Xcode command line tools"

xcode-select -p >/dev/null 2>&1 || die "Xcode Command Line Tools are required; run: xcode-select --install"
developer_dir=$(xcode-select -p)
if ! xcodebuild -version >/dev/null 2>&1; then
	die "selected developer directory is not full Xcode: $developer_dir; install full Xcode, open it once, then run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
fi
if [ "$build_system" = cargo ] && [ -z "$target_dir" ]; then
	cache_namespace=$(cpsl_apple_cargo_cache_namespace) || die "failed to derive CPSL Cargo cache namespace"
	target_dir="$work_dir/cargo-target/$cache_namespace"
fi
required_sdks=
if [ "$include_ios_device" -eq 1 ]; then
	required_sdks="${required_sdks:+$required_sdks }iphoneos"
fi
if [ "$include_ios_simulator" -eq 1 ]; then
	required_sdks="${required_sdks:+$required_sdks }iphonesimulator"
fi
if [ "$include_macos" -eq 1 ]; then
	required_sdks="${required_sdks:+$required_sdks }macosx"
fi
for sdk in $required_sdks; do
	if ! sdk_path=$(xcrun --sdk "$sdk" --show-sdk-path 2>/dev/null); then
		die "selected Xcode developer directory does not provide the $sdk SDK: $developer_dir; install full Xcode, open it once, then run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
	fi
	[ -d "$sdk_path" ] || die "$sdk SDK path does not exist: $sdk_path"
done

required_targets=
if [ "$include_ios_device" -eq 1 ]; then
	required_targets="${required_targets:+$required_targets }$ios_device_targets"
fi
if [ "$include_ios_simulator" -eq 1 ]; then
	required_targets="${required_targets:+$required_targets }$ios_simulator_targets"
fi
if [ "$include_macos" -eq 1 ]; then
	required_targets="${required_targets:+$required_targets }$macos_targets"
fi
if [ "$build_system" = cargo ] && command -v rustup >/dev/null 2>&1; then
	missing_targets=
	for target in $required_targets; do
		if ! rustup target list --installed | grep -qx "$target"; then
			missing_targets="${missing_targets:+$missing_targets }$target"
		fi
	done
	if [ -n "$missing_targets" ]; then
		die "missing Rust Apple target(s): $missing_targets; run: rustup target add $missing_targets"
	fi
fi

if [ "$build_system" = bazel ] && [ -n "${CPSL_ROOT:-}" ]; then
	requested_cpsl_root=$(CDPATH= cd "$CPSL_ROOT" && pwd -P) || die "CPSL_ROOT is not a directory: $CPSL_ROOT"
	[ "$requested_cpsl_root" = "$default_cpsl_root" ] || \
		die "Bazel builds use $default_cpsl_root; set CPSL_APPLE_BUILD_SYSTEM=cargo to build a different CPSL_ROOT"
fi

if [ "${HERM_CPSL_FORCE_SUBMODULE:-0}" = 1 ] || [ "$build_system" = bazel ]; then
	if [ -n "${CPSL_ROOT:-}" ]; then
		printf 'Ignoring CPSL_ROOT for Xcode CPSL build; using Herm submodule: %s\n' "$default_cpsl_root"
	fi
	if [ ! -f "$default_cpsl_root/Cargo.toml" ]; then
		need_cmd git "install Git"
		printf 'Initializing CPSL submodule in %s\n' "$default_cpsl_root"
		git -C "$herm_root" submodule update --init -- external/cpsl
	fi
	cpsl_root=$(CDPATH= cd "$default_cpsl_root" && pwd -P) || \
		die "missing CPSL submodule at $default_cpsl_root; run: git submodule update --init external/cpsl"
elif [ -n "${CPSL_ROOT:-}" ]; then
	cpsl_root=$(CDPATH= cd "$CPSL_ROOT" && pwd -P) || die "CPSL_ROOT is not a directory: $CPSL_ROOT"
else
	if [ ! -f "$default_cpsl_root/Cargo.toml" ]; then
		need_cmd git "install Git or set CPSL_ROOT to an existing CPSL checkout"
		printf 'Initializing CPSL submodule in %s\n' "$default_cpsl_root"
		git -C "$herm_root" submodule update --init -- external/cpsl
	fi
	cpsl_root=$(CDPATH= cd "$default_cpsl_root" && pwd -P) || \
		die "missing CPSL submodule at $default_cpsl_root; run: git submodule update --init external/cpsl"
fi

sh "$herm_root/scripts/apply-cpsl-patches.sh" "$cpsl_root"

[ -f "$cpsl_root/Cargo.toml" ] || die "missing CPSL Cargo.toml at $cpsl_root"
[ -f "$cpsl_root/ffi/Cargo.toml" ] || die "missing CPSL FFI crate at $cpsl_root/ffi"
[ -f "$cpsl_root/ffi/include/cpsl.h" ] || die "missing CPSL FFI header at $cpsl_root/ffi/include/cpsl.h"

build_identity_before=$(cpsl_apple_build_stamp_expected \
	"$herm_root" "$cpsl_root" "$profile" "$cargo_profile" "$cargo_incremental") || \
	die "failed to compute CPSL Apple build identity"

mkdir -p "$out_dir"
out_dir=$(CDPATH= cd "$out_dir" && pwd -P)
build_stamp_path=$(cpsl_apple_build_stamp_path "$out_dir")
include_dir="$out_dir/include"
slice_dir="$out_dir/slices"
ios_device_dir="$slice_dir/ios-arm64"
ios_simulator_dir="$slice_dir/ios-simulator"
macos_dir="$slice_dir/macos"
xcframework_path="$out_dir/$xcframework_name"
pdfium_dir="$out_dir/libs/pdfium"

rm -f "$build_stamp_path" "$out_dir/.cpsl-source.stamp"
rm -rf "$slice_dir" "$xcframework_path" "$pdfium_dir"
mkdir -p "$include_dir"
cp "$cpsl_root/ffi/include/cpsl.h" "$include_dir/cpsl.h"
cat >"$include_dir/module.modulemap" <<EOF
module CPSL {
  header "cpsl.h"
  export *
}
EOF

target_env_name() {
	printf '%s' "$1" | tr '-' '_'
}

target_env_name_upper() {
	printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_'
}

build_target() {
	target=$1
	sdk=$2
	deployment_env=$3
	deployment_target=$4
	output_dir=$5
	sdk_path=$(xcrun --sdk "$sdk" --show-sdk-path)

	printf 'Building CPSL FFI (%s, %s) for %s\n' "$profile" "$build_system" "$target"
	if [ "$build_system" = bazel ]; then
		bazel_platform=$(cpsl_apple_bazel_platform_for_rust_target "$target") || exit 1
		if [ "$profile" = apple-app ]; then
			bazel_config=cpsl-apple
		else
			bazel_config=cpsl-minimum
		fi
		set -- build //:cpsl \
			"--config=$bazel_config" \
			"--platforms=$bazel_platform" \
			"--compilation_mode=$bazel_compilation_mode" \
			"--symlink_prefix=$work_dir/bazel-" \
			"--repo_env=DEVELOPER_DIR=$developer_dir" \
			"--action_env=DEVELOPER_DIR=$developer_dir" \
			"--action_env=SDKROOT=$sdk_path" \
			"--action_env=$deployment_env=$deployment_target"
		case "$sdk" in
		iphoneos | iphonesimulator)
			set -- "$@" "--ios_minimum_os=$deployment_target"
			;;
		macosx)
			set -- "$@" "--macos_minimum_os=$deployment_target"
			;;
		esac
		"$bazel_command" "$@"
		target_lib="$work_dir/bazel-bin/$lib_name"
	else
		target_env=$(target_env_name "$target")
		target_env_upper=$(target_env_name_upper "$target")
		clang=$(xcrun --sdk "$sdk" --find clang)
		clangxx=$(xcrun --sdk "$sdk" --find clang++)
		ar=$(xcrun --sdk "$sdk" --find ar)
		install_name_flags="-C link-arg=-Wl,-install_name,@rpath/$lib_name"
		rustflags=${RUSTFLAGS:-}
		if [ -n "$rustflags" ]; then
			rustflags="$rustflags $install_name_flags"
		else
			rustflags=$install_name_flags
		fi
		if [ "$profile" = apple-app ]; then
			cargo_features=embedded-agent
		else
			cargo_features=ffi-minimal
		fi
		set -- build --manifest-path "$cpsl_root/Cargo.toml" --target-dir "$target_dir" -p cpsl-ffi
		if [ "$cargo_profile" = release ]; then
			set -- "$@" --release
		fi
		set -- "$@" --no-default-features --features "$cargo_features" --target "$target"
		env \
			"SDKROOT=$sdk_path" \
			"$deployment_env=$deployment_target" \
			"CC_$target_env=$clang" \
			"CXX_$target_env=$clangxx" \
			"AR_$target_env=$ar" \
			"CARGO_TARGET_${target_env_upper}_LINKER=$clang" \
			"CARGO_INCREMENTAL=$cargo_incremental" \
			"RUSTFLAGS=$rustflags" \
			cargo "$@"

		target_lib="$target_dir/$target/$cargo_profile/$lib_name"
	fi

	[ -f "$target_lib" ] || die "expected CPSL library not found: $target_lib"
	mkdir -p "$output_dir"
	cp "$target_lib" "$output_dir/$lib_name"
}

install_pdfium_target() {
	pdfium_target=$1
	output=$2

	[ -f "$cpsl_root/core/scripts/download-pdfium.sh" ] || die "missing CPSL PDFium downloader at $cpsl_root/core/scripts/download-pdfium.sh"
	if [ -n "${PDFIUM_VERSION:-}" ]; then
		"$cpsl_root/core/scripts/download-pdfium.sh" --version "$PDFIUM_VERSION" --target "$pdfium_target" --output "$output"
	else
		"$cpsl_root/core/scripts/download-pdfium.sh" --target "$pdfium_target" --output "$output"
	fi
	[ -f "$output/lib/$pdfium_lib_name" ] || die "expected PDFium library not found: $output/lib/$pdfium_lib_name"
}

copy_pdfium_library() {
	source_lib=$1
	output_lib=$2

	mkdir -p "$(dirname "$output_lib")"
	cp "$source_lib" "$output_lib"
}

combine_pdfium_libraries() {
	output_lib=$1
	shift

	[ "$#" -gt 0 ] || die "no PDFium libraries to combine for $output_lib"
	mkdir -p "$(dirname "$output_lib")"
	if [ "$#" -eq 1 ]; then
		cp "$1" "$output_lib"
	else
		lipo -create "$@" -output "$output_lib"
	fi
}

install_apple_pdfium_artifacts() {
	pdfium_work_dir="$work_dir/pdfium"
	rm -rf "$pdfium_work_dir" "$pdfium_dir"
	mkdir -p "$pdfium_work_dir" "$pdfium_dir"

	if [ "$include_ios_device" -eq 1 ]; then
		install_pdfium_target ios-device-arm64 "$pdfium_work_dir/ios-device-arm64"
		copy_pdfium_library \
			"$pdfium_work_dir/ios-device-arm64/lib/$pdfium_lib_name" \
			"$pdfium_dir/ios-arm64/lib/$pdfium_lib_name"
	fi

	if [ "$include_ios_simulator" -eq 1 ]; then
		set --
		for target in $ios_simulator_targets; do
			case "$target" in
			aarch64-apple-ios-sim)
				install_pdfium_target ios-simulator-arm64 "$pdfium_work_dir/ios-simulator-arm64"
				set -- "$@" "$pdfium_work_dir/ios-simulator-arm64/lib/$pdfium_lib_name"
				;;
			x86_64-apple-ios)
				install_pdfium_target ios-simulator-x64 "$pdfium_work_dir/ios-simulator-x64"
				set -- "$@" "$pdfium_work_dir/ios-simulator-x64/lib/$pdfium_lib_name"
				;;
			*)
				die "unsupported iOS simulator PDFium target: $target"
				;;
			esac
		done
		combine_pdfium_libraries "$pdfium_dir/ios-simulator/lib/$pdfium_lib_name" "$@"
	fi

	if [ "$include_macos" -eq 1 ]; then
		install_pdfium_target mac-univ "$pdfium_work_dir/mac-univ"
		copy_pdfium_library \
			"$pdfium_work_dir/mac-univ/lib/$pdfium_lib_name" \
			"$pdfium_dir/macos/lib/$pdfium_lib_name"
	fi
}

combine_libraries() {
	output=$1
	shift
	[ "$#" -gt 0 ] || die "no libraries to combine for $output"
	mkdir -p "$(dirname "$output")"
	if [ "$#" -eq 1 ]; then
		cp "$1" "$output"
	else
		lipo -create "$@" -output "$output"
	fi
}

build_universal_library() {
	output=$1
	sdk=$2
	deployment_env=$3
	deployment_target=$4
	shift 4
	[ "$#" -gt 0 ] || die "no Rust targets supplied for $output"
	targets=$*
	set --
	for target in $targets; do
		target_output_dir="$slice_dir/$target"
		build_target "$target" "$sdk" "$deployment_env" "$deployment_target" "$target_output_dir"
		set -- "$@" "$target_output_dir/$lib_name"
	done
	combine_libraries "$output" "$@"
}

if [ "$include_ios_device" -eq 1 ]; then
	build_universal_library "$ios_device_dir/$lib_name" iphoneos IPHONEOS_DEPLOYMENT_TARGET "$ios_deployment_target" $ios_device_targets
fi

if [ "$include_ios_simulator" -eq 1 ]; then
	build_universal_library "$ios_simulator_dir/$lib_name" iphonesimulator IPHONEOS_DEPLOYMENT_TARGET "$ios_deployment_target" $ios_simulator_targets
fi

if [ "$include_macos" -eq 1 ]; then
	build_universal_library "$macos_dir/$lib_name" macosx MACOSX_DEPLOYMENT_TARGET "$macos_deployment_target" $macos_targets
fi

if [ "$profile" = apple-app ]; then
	install_apple_pdfium_artifacts
fi

set -- -create-xcframework
if [ "$include_ios_device" -eq 1 ]; then
	set -- "$@" -library "$ios_device_dir/$lib_name" -headers "$include_dir"
fi
if [ "$include_ios_simulator" -eq 1 ]; then
	set -- "$@" -library "$ios_simulator_dir/$lib_name" -headers "$include_dir"
fi
if [ "$include_macos" -eq 1 ]; then
	set -- "$@" -library "$macos_dir/$lib_name" -headers "$include_dir"
fi
set -- "$@" -output "$xcframework_path"

xcodebuild "$@"

manifest_path="$out_dir/build-manifest.txt"
herm_manifest_init "$manifest_path"
herm_manifest_add "$manifest_path" builder build-cpsl-apple-xcframework.sh
herm_manifest_add "$manifest_path" profile "$profile"
herm_manifest_add "$manifest_path" features "$([ "$profile" = apple-app ] && printf '%s' embedded-agent || printf '%s' ffi-minimal)"
herm_manifest_add "$manifest_path" build_system "$build_system"
if [ "$build_system" = bazel ]; then
	herm_manifest_add "$manifest_path" bazel_compilation_mode "$bazel_compilation_mode"
	herm_manifest_add "$manifest_path" bazel_version "$("$bazel_command" --version)"
else
	herm_manifest_add "$manifest_path" cargo_profile "$cargo_profile"
	herm_manifest_add "$manifest_path" cargo_incremental "$cargo_incremental"
fi
herm_manifest_add "$manifest_path" targets "$CPSL_REQUEST_DESCRIPTION"
herm_manifest_add "$manifest_path" herm_revision "$(herm_source_revision "$herm_root")"
herm_manifest_add "$manifest_path" cpsl_revision "$(herm_source_revision "$cpsl_root")"
if [ "$build_system" = cargo ]; then
	herm_manifest_add "$manifest_path" rustc_version "$(rustc --version)"
	herm_manifest_add "$manifest_path" cargo_version "$(cargo --version)"
fi
herm_manifest_add "$manifest_path" xcode_version "$(xcodebuild -version)"
herm_manifest_add "$manifest_path" clang_version "$(xcrun clang --version | sed -n '1p')"
herm_manifest_add_file "$manifest_path" cpsl_header_sha256 "$include_dir/cpsl.h"
herm_manifest_add_file "$manifest_path" ios_device_library_sha256 "$ios_device_dir/$lib_name"
herm_manifest_add_file "$manifest_path" ios_simulator_library_sha256 "$ios_simulator_dir/$lib_name"
herm_manifest_add_file "$manifest_path" macos_library_sha256 "$macos_dir/$lib_name"
if [ "$profile" = apple-app ]; then
	herm_manifest_add "$manifest_path" pdfium_version "${PDFIUM_VERSION:-7734}"
	herm_manifest_add_file "$manifest_path" pdfium_ios_device_sha256 "$pdfium_dir/ios-arm64/lib/$pdfium_lib_name"
	herm_manifest_add_file "$manifest_path" pdfium_ios_simulator_sha256 "$pdfium_dir/ios-simulator/lib/$pdfium_lib_name"
	herm_manifest_add_file "$manifest_path" pdfium_macos_sha256 "$pdfium_dir/macos/lib/$pdfium_lib_name"
fi

build_identity_after=$(cpsl_apple_build_stamp_expected \
	"$herm_root" "$cpsl_root" "$profile" "$cargo_profile" "$cargo_incremental") || \
	die "failed to verify CPSL Apple build identity"
[ "$build_identity_before" = "$build_identity_after" ] || \
	die "CPSL Apple build inputs changed while the build was running; retry the build"
cpsl_apple_build_stamp_write_value "$build_stamp_path" "$build_identity_after"

if [ -z "${OUT_DIR:-}" ] && [ -z "${CPSL_WORK_DIR:-}" ] && [ -z "${CONFIGURATION:-}" ]; then
	display_out=".herm-cpsl/artifacts/apple"
else
	display_out="$out_dir"
fi

printf '\nBuilt CPSL Apple XCFramework (%s)\n' "$profile"
printf '  build system: %s\n' "$build_system"
if [ "$build_system" = bazel ]; then
	printf '  Bazel compilation mode: %s\n' "$bazel_compilation_mode"
else
	printf '  Cargo profile: %s\n' "$cargo_profile"
fi
printf '  targets: %s\n' "$CPSL_REQUEST_DESCRIPTION"
printf '  image: %s\n' "$display_out"
printf '  xcframework: %s/%s\n' "$display_out" "$xcframework_name"
if [ "$profile" = apple-app ]; then
	printf '  pdfium: %s/libs/pdfium\n' "$display_out"
fi
printf '  header: %s/include/cpsl.h\n' "$display_out"
printf '  manifest: %s/build-manifest.txt\n' "$display_out"
