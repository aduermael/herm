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
  build-cpsl-ios-xcframework.sh [--minimum]

Builds a CPSL iOS XCFramework from Herm's pinned CPSL source dependency.

By default this script fetches CPSL into a gitignored Herm-local work directory,
matching scripts/build-cpsl-image.sh. The output is an Apple-consumable
XCFramework containing CPSL's dynamic library and C header.

Options:
  --minimum   Build the default Herm CPSL library profile. This is the default.
  -h, --help  Show this help.

Environment:
  CPSL_REPO                CPSL git URL. Defaults to the public CPSL repository.
  CPSL_REF                 CPSL git ref to fetch. Defaults to the pinned merged CPSL commit.
  CPSL_ROOT                Existing CPSL checkout to use instead of fetching.
  CPSL_WORK_DIR            Gitignored work/artifact root. Defaults to HERM_ROOT/.herm-cpsl.
  CPSL_TARGET_DIR          Cargo target directory. Defaults to CPSL_WORK_DIR/cargo-target.
  OUT_DIR                  Artifact directory. Defaults to CPSL_WORK_DIR/artifacts/ios.
  IOS_DEPLOYMENT_TARGET    Minimum iOS version. Defaults to 17.0.
  IOS_SIMULATOR_TARGETS    Rust simulator targets. Defaults to arm64 and x86_64 simulator.
EOF
}

profile=minimum
while [ "$#" -gt 0 ]; do
	case "$1" in
	--minimum)
		profile=minimum
		;;
	--all)
		die "--all is not supported for iOS yet; the PDFium/runtime artifact path is not defined"
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

[ "$(uname -s)" = Darwin ] || die "iOS XCFramework builds require macOS with Xcode"

work_dir=${CPSL_WORK_DIR:-"$herm_root/.herm-cpsl"}
mkdir -p "$work_dir"
work_dir=$(CDPATH= cd "$work_dir" && pwd -P)
cpsl_repo=${CPSL_REPO:-"https://github.com/fundamental-research-labs/cpsl.git"}
default_cpsl_ref=47ea301e1b32223cc0bc46001cca59fb7516f047
cpsl_ref=${CPSL_REF:-"$default_cpsl_ref"}
managed_cpsl_root="$work_dir/cpsl"
target_dir=${CPSL_TARGET_DIR:-"$work_dir/cargo-target"}
out_dir=${OUT_DIR:-"$work_dir/artifacts/ios"}
ios_deployment_target=${IOS_DEPLOYMENT_TARGET:-17.0}
device_target=aarch64-apple-ios
simulator_targets=${IOS_SIMULATOR_TARGETS:-"aarch64-apple-ios-sim x86_64-apple-ios"}
lib_name=libcpsl.dylib
xcframework_name=cpsl.xcframework

[ -n "$simulator_targets" ] || die "IOS_SIMULATOR_TARGETS must not be empty"

need_cmd cargo "install Rust from https://rustup.rs"
need_cmd rustc "install Rust from https://rustup.rs"
need_cmd xcode-select "run: xcode-select --install"
need_cmd xcodebuild "install Xcode"
need_cmd xcrun "install Xcode command line tools"
need_cmd lipo "install Xcode command line tools"

xcode-select -p >/dev/null 2>&1 || die "Xcode Command Line Tools are required; run: xcode-select --install"
developer_dir=$(xcode-select -p)
for sdk in iphoneos iphonesimulator; do
	if ! sdk_path=$(xcrun --sdk "$sdk" --show-sdk-path 2>/dev/null); then
		die "selected Xcode developer directory does not provide the $sdk SDK: $developer_dir; install full Xcode, open it once, then run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
	fi
	[ -d "$sdk_path" ] || die "$sdk SDK path does not exist: $sdk_path"
done

if command -v rustup >/dev/null 2>&1; then
	missing_targets=
	for target in $device_target $simulator_targets; do
		if ! rustup target list --installed | grep -qx "$target"; then
			missing_targets="${missing_targets:+$missing_targets }$target"
		fi
	done
	if [ -n "$missing_targets" ]; then
		die "missing Rust iOS target(s): $missing_targets; run: rustup target add $missing_targets"
	fi
fi

if [ -n "${CPSL_ROOT:-}" ]; then
	cpsl_root=$(CDPATH= cd "$CPSL_ROOT" && pwd -P) || die "CPSL_ROOT is not a directory: $CPSL_ROOT"
else
	need_cmd git "install Git or set CPSL_ROOT to an existing CPSL checkout"
	if [ -e "$managed_cpsl_root" ] && [ ! -d "$managed_cpsl_root/.git" ]; then
		die "$managed_cpsl_root exists but is not a Git checkout"
	fi
	if [ ! -d "$managed_cpsl_root/.git" ]; then
		printf 'Initializing CPSL checkout in %s\n' "$managed_cpsl_root"
		git -c init.defaultBranch=main init "$managed_cpsl_root" >/dev/null
		git -C "$managed_cpsl_root" remote add origin "$cpsl_repo"
	else
		git -C "$managed_cpsl_root" remote set-url origin "$cpsl_repo"
	fi
	printf 'Fetching CPSL %s from %s\n' "$cpsl_ref" "$cpsl_repo"
	git -C "$managed_cpsl_root" fetch --depth 1 origin "$cpsl_ref"
	git -C "$managed_cpsl_root" checkout --detach FETCH_HEAD
	cpsl_root=$(CDPATH= cd "$managed_cpsl_root" && pwd -P)
fi

sh "$herm_root/scripts/apply-cpsl-patches.sh" "$cpsl_root"

[ -f "$cpsl_root/Cargo.toml" ] || die "missing CPSL Cargo.toml at $cpsl_root"
[ -f "$cpsl_root/ffi/Cargo.toml" ] || die "missing CPSL FFI crate at $cpsl_root/ffi"
[ -f "$cpsl_root/ffi/include/cpsl.h" ] || die "missing CPSL FFI header at $cpsl_root/ffi/include/cpsl.h"

mkdir -p "$out_dir"
out_dir=$(CDPATH= cd "$out_dir" && pwd -P)
include_dir="$out_dir/include"
slice_dir="$out_dir/slices"
device_dir="$slice_dir/ios-arm64"
simulator_dir="$slice_dir/ios-simulator"
xcframework_path="$out_dir/$xcframework_name"

rm -rf "$slice_dir" "$xcframework_path"
mkdir -p "$include_dir" "$device_dir" "$simulator_dir"
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
	output_dir=$3
	target_env=$(target_env_name "$target")
	target_env_upper=$(target_env_name_upper "$target")
	sdk_path=$(xcrun --sdk "$sdk" --show-sdk-path)
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

	printf 'Building CPSL FFI (%s) for %s\n' "$profile" "$target"
	env \
		"SDKROOT=$sdk_path" \
		"IPHONEOS_DEPLOYMENT_TARGET=$ios_deployment_target" \
		"CC_$target_env=$clang" \
		"CXX_$target_env=$clangxx" \
		"AR_$target_env=$ar" \
		"CARGO_TARGET_${target_env_upper}_LINKER=$clang" \
		"RUSTFLAGS=$rustflags" \
		cargo build --manifest-path "$cpsl_root/Cargo.toml" --target-dir "$target_dir" -p cpsl-ffi --release --target "$target"

	target_lib="$target_dir/$target/release/$lib_name"
	[ -f "$target_lib" ] || die "expected CPSL library not found: $target_lib"
	mkdir -p "$output_dir"
	cp "$target_lib" "$output_dir/$lib_name"
}

build_target "$device_target" iphoneos "$device_dir"

sim_count=0
set --
for target in $simulator_targets; do
	target_output_dir="$slice_dir/$target"
	build_target "$target" iphonesimulator "$target_output_dir"
	set -- "$@" "$target_output_dir/$lib_name"
	sim_count=$((sim_count + 1))
done

if [ "$sim_count" -eq 1 ]; then
	cp "$1" "$simulator_dir/$lib_name"
else
	lipo -create "$@" -output "$simulator_dir/$lib_name"
fi

xcodebuild -create-xcframework \
	-library "$device_dir/$lib_name" -headers "$include_dir" \
	-library "$simulator_dir/$lib_name" -headers "$include_dir" \
	-output "$xcframework_path"

if [ -z "${OUT_DIR:-}" ] && [ -z "${CPSL_WORK_DIR:-}" ]; then
	display_out=".herm-cpsl/artifacts/ios"
else
	display_out="$out_dir"
fi

printf '\nBuilt CPSL iOS XCFramework (%s)\n' "$profile"
printf '  image: %s\n' "$display_out"
printf '  xcframework: %s/%s\n' "$display_out" "$xcframework_name"
printf '  header: %s/include/cpsl.h\n' "$display_out"
