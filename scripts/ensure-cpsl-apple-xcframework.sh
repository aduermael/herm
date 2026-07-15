#!/bin/sh
set -eu

die() {
	printf '%s\n' "error: $*" >&2
	exit 1
}

usage() {
	cat <<EOF
Usage:
  scripts/ensure-cpsl-apple-xcframework.sh [options]

Ensures the requested CPSL Apple XCFramework slices exist before building Herm.

Options:
  --skip   Require an existing matching XCFramework; do not build.
  -h, --help
           Show this help.

Environment:
  HERM_CPSL_REBUILD=1  Force a CPSL XCFramework rebuild.
  CPSL_ROOT, CPSL_WORK_DIR, OUT_DIR, APPLE_PLATFORMS,
  IOS_DEVICE_TARGETS, IOS_SIMULATOR_TARGETS, MACOS_TARGETS, CONFIGURATION
                         Passed through to build-cpsl-apple-xcframework.sh.
EOF
}

cpsl_ensure_is_visionos_build() {
	case "${PLATFORM_NAME:-}" in
	xros | xrsimulator)
		return 0
		;;
	esac

	case "${SDKROOT:-}" in
	*xros* | *xrsimulator*)
		return 0
		;;
	esac

	return 1
}

cpsl_ensure_lock_mtime() {
	path=$1

	if stat -f %m "$path" >/dev/null 2>&1; then
		stat -f %m "$path"
		return 0
	fi

	stat -c %Y "$path"
}

cpsl_ensure_acquire_lock() {
	lock_path=$1

	mkdir -p "$(dirname "$lock_path")"

	while ! mkdir "$lock_path" 2>/dev/null; do
		lock_pid=
		if [ -f "$lock_path/pid" ]; then
			lock_pid=$(cat "$lock_path/pid" 2>/dev/null || printf '')
		elif [ -f "$lock_path" ]; then
			lock_pid=$(cat "$lock_path" 2>/dev/null || printf '')
		fi
		case "$lock_pid" in
		'' | *[!0-9]*) lock_pid= ;;
		esac
		if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
			printf 'Waiting for CPSL XCFramework build lock held by PID %s: %s\n' "$lock_pid" "$lock_path"
			sleep 5
			continue
		fi

		lock_mtime=$(cpsl_ensure_lock_mtime "$lock_path" 2>/dev/null) || continue
		lock_age=$(($(date +%s) - lock_mtime))
		if [ -n "$lock_pid" ] || [ "$lock_age" -ge 10 ]; then
			if [ -d "$lock_path" ]; then
				rm -f "$lock_path/pid"
				rmdir "$lock_path" 2>/dev/null || true
			else
				rm -f "$lock_path"
			fi
			continue
		fi
		printf 'Waiting for CPSL XCFramework build lock: %s\n' "$lock_path"
		sleep 5
	done

	printf '%s\n' "$$" >"$lock_path/pid"
	lock_owned=1
}

cpsl_ensure_release_lock() {
	[ "${lock_owned:-0}" -eq 1 ] || return 0
	rm -f "$lock_file/pid"
	rmdir "$lock_file" 2>/dev/null || true
	lock_owned=0
}

cpsl_ensure_rebuild_reason() {
	xcframework_info=$1

	[ "${HERM_CPSL_REBUILD:-0}" = 1 ] && {
		printf '%s\n' "HERM_CPSL_REBUILD=1"
		return 0
	}
	[ -d "$xcframework_path" ] || {
		printf '%s\n' "missing $xcframework_path"
		return 0
	}
	[ -f "$xcframework_info" ] || {
		printf '%s\n' "missing $xcframework_info"
		return 0
	}
	cpsl_xcframework_is_placeholder "$xcframework_path" && {
		printf '%s\n' "$xcframework_path is still the bootstrap placeholder"
		return 0
	}
	expected_build_identity=$(cpsl_apple_build_stamp_expected \
		"$herm_root" "$cpsl_input_root" apple-app "$cargo_profile" "$cargo_incremental") || {
		printf '%s\n' "could not compute the current CPSL Apple build identity"
		return 0
	}
	cpsl_apple_build_stamp_matches_value "$build_stamp_path" "$expected_build_identity" || {
		printf '%s\n' "CPSL build identity changed (source, exact targets, configuration, toolchain, or build flags)"
		return 0
	}
	cpsl_xcframework_matches_targets "$xcframework_info" "$ios_device_targets" "$ios_simulator_targets" "$macos_targets" || {
		printf '%s\n' "$xcframework_path does not exactly match requested CPSL target(s): $CPSL_REQUEST_DESCRIPTION"
		return 0
	}
	cpsl_xcframework_binaries_satisfy_targets "$xcframework_path" "$ios_device_targets" "$ios_simulator_targets" "$macos_targets" || {
		printf '%s\n' "$xcframework_path has missing or invalid CPSL binaries for: $CPSL_REQUEST_DESCRIPTION"
		return 0
	}
	cpsl_pdfium_satisfies_targets "$pdfium_path" "$ios_device_targets" "$ios_simulator_targets" "$macos_targets" || {
		printf '%s\n' "$pdfium_path does not contain requested PDFium target(s): $CPSL_REQUEST_DESCRIPTION"
		return 0
	}
	return 1
}

cpsl_ensure_should_reuse() {
	xcframework_info=$1

	! cpsl_ensure_rebuild_reason "$xcframework_info" >/dev/null
}

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
herm_root=$(CDPATH= cd "$script_dir/.." && pwd -P)
. "$script_dir/lib/host-path.sh"
. "$script_dir/lib/cpsl-xcframework.sh"
. "$script_dir/lib/cpsl-apple-build-state.sh"
herm_ensure_rust_path

skip_mode=0
while [ "$#" -gt 0 ]; do
	case "$1" in
	--skip)
		skip_mode=1
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

if cpsl_ensure_is_visionos_build; then
	die "CPSL does not yet support visionOS. Supported platforms: iOS and macOS."
fi

request_assignments=$(cpsl_apple_request_from_environment) || die "failed to resolve CPSL Apple build targets"
eval "$request_assignments"
ios_device_targets=$IOS_DEVICE_TARGETS
ios_simulator_targets=$IOS_SIMULATOR_TARGETS
macos_targets=$MACOS_TARGETS

if cpsl_apple_has_xcode_selection; then
	HERM_CPSL_FORCE_SUBMODULE=1
	export HERM_CPSL_FORCE_SUBMODULE
	unset CPSL_ROOT
fi
work_dir=${CPSL_WORK_DIR:-"$herm_root/.herm-cpsl"}
cargo_profile=$(cpsl_apple_cargo_profile_from_environment) || die "failed to resolve CPSL Cargo profile"
cargo_incremental=$(cpsl_apple_cargo_incremental_from_environment) || die "failed to resolve CPSL incremental compilation setting"
out_dir=${OUT_DIR:-$(cpsl_apple_default_artifact_dir "$work_dir")}
default_cpsl_root="$herm_root/external/cpsl"
cpsl_input_root=${CPSL_ROOT:-"$default_cpsl_root"}
[ "${HERM_CPSL_FORCE_SUBMODULE:-0}" -eq 0 ] || cpsl_input_root=$default_cpsl_root
xcframework_path="$out_dir/cpsl.xcframework"
pdfium_path="$out_dir/libs/pdfium"
build_stamp_path=$(cpsl_apple_build_stamp_path "$out_dir")
xcframework_info=$(cpsl_xcframework_info_plist "$xcframework_path")

if [ "$skip_mode" -eq 1 ]; then
	[ -d "$xcframework_path" ] || die "missing $xcframework_path; rerun without --skip"
	expected_build_identity=$(cpsl_apple_build_stamp_expected \
		"$herm_root" "$cpsl_input_root" apple-app "$cargo_profile" "$cargo_incremental") || \
		die "could not compute the current CPSL Apple build identity"
	cpsl_apple_build_stamp_matches_value "$build_stamp_path" "$expected_build_identity" || \
		die "$xcframework_path does not match the current source, exact targets, configuration, toolchain, and build flags; rerun without --skip"
	cpsl_xcframework_matches_targets "$xcframework_info" "$ios_device_targets" "$ios_simulator_targets" "$macos_targets" || \
		die "$xcframework_path does not exactly match requested CPSL target(s): $CPSL_REQUEST_DESCRIPTION; rerun without --skip"
	cpsl_xcframework_binaries_satisfy_targets "$xcframework_path" "$ios_device_targets" "$ios_simulator_targets" "$macos_targets" || \
		die "$xcframework_path has missing or invalid CPSL binaries for: $CPSL_REQUEST_DESCRIPTION; rerun without --skip"
	cpsl_pdfium_satisfies_targets "$pdfium_path" "$ios_device_targets" "$ios_simulator_targets" "$macos_targets" || \
		die "$pdfium_path does not contain requested PDFium target(s): $CPSL_REQUEST_DESCRIPTION; rerun without --skip"
	printf 'Using existing CPSL XCFramework: %s\n' "$xcframework_path"
	exit 0
fi

if cpsl_ensure_should_reuse "$xcframework_info"; then
	printf 'Using existing CPSL XCFramework: %s\n' "$xcframework_path"
	exit 0
fi
rebuild_reason=$(cpsl_ensure_rebuild_reason "$xcframework_info" || printf '%s\n' "unknown reason")

lock_file="$work_dir/.cpsl-xcframework-build.lock"
lock_owned=0
trap cpsl_ensure_release_lock EXIT HUP INT TERM
cpsl_ensure_acquire_lock "$lock_file"

xcframework_info=$(cpsl_xcframework_info_plist "$xcframework_path")
if cpsl_ensure_should_reuse "$xcframework_info"; then
	printf 'Using existing CPSL XCFramework: %s\n' "$xcframework_path"
	exit 0
fi
rebuild_reason=$(cpsl_ensure_rebuild_reason "$xcframework_info" || printf '%s\n' "$rebuild_reason")

printf 'Building CPSL Apple XCFramework for: %s (%s)\n' "$CPSL_REQUEST_DESCRIPTION" "$rebuild_reason"
APPLE_PLATFORMS="$APPLE_PLATFORMS" \
	IOS_DEVICE_TARGETS="$IOS_DEVICE_TARGETS" \
	IOS_SIMULATOR_TARGETS="$IOS_SIMULATOR_TARGETS" \
	MACOS_TARGETS="$MACOS_TARGETS" \
	CONFIGURATION="${CONFIGURATION:-}" \
	"$herm_root/scripts/build-cpsl-apple-xcframework.sh"
