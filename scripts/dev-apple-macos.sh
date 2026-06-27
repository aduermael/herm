#!/bin/sh
set -eu

die() {
	printf '%s\n' "error: $*" >&2
	exit 1
}

need_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		die "$1 is required; $2"
	fi
}

clean_xattrs() {
	command -v xattr >/dev/null 2>&1 || return 0
	for path in "$@"; do
		[ -e "$path" ] || continue
		printf 'Clearing extended attributes: %s\n' "$path"
		xattr -cr "$path" || die "failed to clear extended attributes: $path"
	done
}

ad_hoc_sign_app() {
	app=$1
	entitlements=$2

	[ -d "$app" ] || die "expected app was not built: $app"
	need_cmd codesign "install full Xcode or Command Line Tools"

	clean_xattrs "$app"

	if [ -d "$app/Contents/Frameworks" ]; then
		find "$app/Contents/Frameworks" -type f \( -name '*.dylib' -o -name '*.so' \) \
			-exec codesign --force --sign - --timestamp=none --generate-entitlement-der {} \; || \
			die "failed to sign embedded frameworks"
	fi

	if [ -d "$app/Contents/MacOS" ]; then
		find "$app/Contents/MacOS" -type f \( -name '*.dylib' -o -name '*.so' \) \
			-exec codesign --force --sign - --timestamp=none --generate-entitlement-der {} \; || \
			die "failed to sign embedded macOS libraries"
	fi

	if [ -f "$entitlements" ]; then
		codesign --force --sign - --entitlements "$entitlements" --timestamp=none --generate-entitlement-der "$app" || \
			die "failed to sign app"
	else
		codesign --force --sign - --timestamp=none --generate-entitlement-der "$app" || \
			die "failed to sign app"
	fi
}

usage() {
	cat <<EOF
Usage:
  scripts/dev-apple-macos.sh [options]

Builds the Herm macOS app from the terminal and launches it.

Options:
  --build-only        Build the app but do not launch it.
  --debug            Open the app executable in LLDB.
  --open             Launch the .app with Launch Services instead of running the executable.
  --skip-cpsl        Do not build the CPSL XCFramework; require it to already exist.
  --rebuild-cpsl     Rebuild the CPSL XCFramework before building the app.
  --full-cpsl        Build both iOS and macOS CPSL slices. Default is macOS only.
  --universal-cpsl   Build both arm64 and x86_64 macOS CPSL slices.
  --project-signing  Use the Xcode project's signing settings instead of ad hoc signing.
  --configuration C  Build configuration. Defaults to Debug.
  --derived-data P   DerivedData path. Defaults to .herm-apple/DerivedData.
  -h, --help         Show this help.

Examples:
  scripts/dev-apple-macos.sh
  scripts/dev-apple-macos.sh --debug
  scripts/dev-apple-macos.sh --build-only --rebuild-cpsl
EOF
}

xcframework_supports_platform() {
	info=$1
	platform=$2

	[ -f "$info" ] || return 1
	awk -v platform="$platform" '
		/<key>SupportedPlatform<\/key>/ {
			getline
			if ($0 ~ "<string>" platform "</string>") {
				found = 1
			}
		}
		END {
			exit found ? 0 : 1
		}
	' "$info"
}

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
root=$(CDPATH= cd "$script_dir/.." && pwd -P)

mode=run
cpsl_mode=auto
cpsl_platforms=${APPLE_PLATFORMS:-macos}
cpsl_macos_targets=${MACOS_TARGETS:-}
configuration=Debug
derived_data="$root/.herm-apple/DerivedData"
project_signing=0

while [ "$#" -gt 0 ]; do
	case "$1" in
	--build-only)
		mode=build
		;;
	--debug)
		mode=debug
		;;
	--open)
		mode=open
		;;
	--skip-cpsl)
		cpsl_mode=skip
		;;
	--rebuild-cpsl)
		cpsl_mode=rebuild
		;;
	--full-cpsl)
		cpsl_platforms="ios macos"
		;;
	--universal-cpsl)
		cpsl_macos_targets="aarch64-apple-darwin x86_64-apple-darwin"
		;;
	--project-signing)
		project_signing=1
		;;
	--configuration)
		shift
		[ "$#" -gt 0 ] || die "--configuration requires a value"
		configuration=$1
		;;
	--derived-data)
		shift
		[ "$#" -gt 0 ] || die "--derived-data requires a value"
		derived_data=$1
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

cpsl_has_macos=0
for platform in $cpsl_platforms; do
	case "$platform" in
	ios)
		;;
	macos)
		cpsl_has_macos=1
		;;
	*)
		die "unsupported APPLE_PLATFORMS entry for macOS app build: $platform"
		;;
	esac
done
[ "$cpsl_has_macos" -eq 1 ] || die "dev-apple-macos.sh requires CPSL macOS slices; unset APPLE_PLATFORMS or include macos"

[ "$(uname -s)" = Darwin ] || die "run this from a macOS terminal, not Linux or a container"

need_cmd xcode-select "install full Xcode, then select and initialize it with xcode-select/xcodebuild"
need_cmd xcodebuild "install full Xcode"
need_cmd xcrun "install full Xcode"

developer_dir=$(xcode-select -p 2>/dev/null || printf '')
case "$developer_dir" in
*/CommandLineTools)
	cat >&2 <<EOF
error: selected developer directory is Command Line Tools: $developer_dir

This app build needs full Xcode's developer directory, even though the build is
driven entirely from Terminal.

Install Xcode, then select and initialize it from Terminal:
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  sudo xcodebuild -runFirstLaunch

Or use Xcode for only this command:
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer $0 $*
EOF
	exit 1
	;;
esac

if ! xcodebuild -version >/dev/null 2>&1; then
	[ -n "$developer_dir" ] || developer_dir="<unset>"
	die "selected developer directory is not full Xcode: $developer_dir"
fi

if [ "$mode" = debug ]; then
	xcrun --find lldb >/dev/null 2>&1 || die "LLDB is required; install full Xcode"
fi

if [ "$mode" = open ]; then
	need_cmd open "macOS Launch Services is required"
fi

project="$root/app/apple/herm.xcodeproj"
target=herm
scheme=herm
app_path="$derived_data/Build/Products/$configuration/$target.app"
binary_path="$app_path/Contents/MacOS/$target"
xcframework_path="$root/.herm-cpsl/artifacts/apple/cpsl.xcframework"
entitlements_path="$derived_data/Build/Intermediates.noindex/herm.build/$configuration/herm.build/$target.app.xcent"
host_arch=$(uname -m)
xcode_arch=$host_arch

[ -d "$project" ] || die "missing Xcode project: $project"

if [ -z "$cpsl_macos_targets" ]; then
	case "$host_arch" in
	arm64)
		cpsl_macos_targets=aarch64-apple-darwin
		;;
	aarch64)
		cpsl_macos_targets=aarch64-apple-darwin
		xcode_arch=arm64
		;;
	x86_64)
		cpsl_macos_targets=x86_64-apple-darwin
		;;
	*)
		die "unsupported macOS architecture for CPSL build: $host_arch"
		;;
	esac
fi

cpsl_patches_newer=0
cpsl_platform_missing=0
xcframework_info="$xcframework_path/Info.plist"
if [ -d "$xcframework_path" ]; then
	for platform in $cpsl_platforms; do
		if ! xcframework_supports_platform "$xcframework_info" "$platform"; then
			cpsl_platform_missing=1
		fi
	done
fi
if [ -d "$xcframework_path" ] && [ -d "$root/scripts/cpsl-patches" ]; then
	if [ ! -f "$xcframework_info" ]; then
		cpsl_patches_newer=1
	elif find "$root/scripts/cpsl-patches" -type f -newer "$xcframework_info" | grep -q .; then
		cpsl_patches_newer=1
	fi
fi

if [ "$cpsl_mode" = skip ]; then
	[ -d "$xcframework_path" ] || die "missing $xcframework_path; rerun without --skip-cpsl"
	[ "$cpsl_platform_missing" -eq 0 ] || die "$xcframework_path does not contain required platform(s): $cpsl_platforms; rerun without --skip-cpsl"
elif [ "$cpsl_mode" = rebuild ] || [ ! -d "$xcframework_path" ] || [ "$cpsl_patches_newer" -eq 1 ] || [ "$cpsl_platform_missing" -eq 1 ]; then
	printf 'Building CPSL Apple XCFramework for: %s\n' "$cpsl_platforms"
	APPLE_PLATFORMS="$cpsl_platforms" \
		MACOS_TARGETS="$cpsl_macos_targets" \
		"$root/scripts/build-cpsl-apple-xcframework.sh"
else
	printf 'Using existing CPSL XCFramework: %s\n' "$xcframework_path"
fi

clean_xattrs "$root/app/apple/herm" "$xcframework_path" "$app_path"

printf 'Building %s (%s) for macOS\n' "$target" "$configuration"
if [ "$project_signing" -eq 1 ]; then
	xcodebuild \
		-project "$project" \
		-scheme "$scheme" \
		-configuration "$configuration" \
		-sdk macosx \
		-destination "platform=macOS,arch=$xcode_arch" \
		-derivedDataPath "$derived_data" \
		build
else
	xcodebuild \
		-project "$project" \
		-scheme "$scheme" \
		-configuration "$configuration" \
		-sdk macosx \
		-destination "platform=macOS,arch=$xcode_arch" \
		-derivedDataPath "$derived_data" \
		CODE_SIGNING_ALLOWED=NO \
		CODE_SIGNING_REQUIRED=NO \
		REGISTER_APP_GROUPS=NO \
		build
	ad_hoc_sign_app "$app_path" "$entitlements_path"
fi

[ -d "$app_path" ] || die "expected app was not built: $app_path"
[ -x "$binary_path" ] || die "expected app executable was not built: $binary_path"

case "$mode" in
build)
	printf '\nBuilt app: %s\n' "$app_path"
	printf 'Executable: %s\n' "$binary_path"
	;;
debug)
	printf '\nStarting LLDB for: %s\n' "$binary_path"
	printf 'Run the app from LLDB with: run\n'
	exec xcrun lldb -- "$binary_path"
	;;
open)
	printf '\nOpening app: %s\n' "$app_path"
	exec open "$app_path"
	;;
run)
	printf '\nRunning app executable: %s\n' "$binary_path"
	exec "$binary_path"
	;;
*)
	die "internal error: unknown mode $mode"
	;;
esac
