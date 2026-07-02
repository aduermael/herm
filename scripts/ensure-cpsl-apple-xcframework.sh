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

Ensures the full CPSL Apple XCFramework exists before building Herm.

Options:
  --skip   Require an existing full XCFramework; do not build.
  -h, --help
           Show this help.

Environment:
  HERM_CPSL_REBUILD=1  Force a CPSL XCFramework rebuild.
  CPSL_ROOT, CPSL_WORK_DIR, OUT_DIR, IOS_SIMULATOR_TARGETS, MACOS_TARGETS
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
	lock_timeout=$2

	mkdir -p "$(dirname "$lock_path")"

	while [ -f "$lock_path" ]; do
		lock_age=$(($(date +%s) - $(cpsl_ensure_lock_mtime "$lock_path")))
		if [ "$lock_age" -ge "$lock_timeout" ]; then
			rm -f "$lock_path"
			break
		fi
		printf 'Waiting for CPSL XCFramework build lock: %s\n' "$lock_path"
		sleep 5
	done

	printf '%s\n' "$$" >"$lock_path"
}

cpsl_ensure_release_lock() {
	[ -n "${lock_file:-}" ] || return 0
	rm -f "$lock_file"
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
	cpsl_xcframework_is_full "$xcframework_info" || {
		printf '%s\n' "$xcframework_path is incomplete"
		return 0
	}
	cpsl_ensure_pdfium_is_full || {
		printf '%s\n' "$pdfium_path is incomplete"
		return 0
	}
	cpsl_xcframework_inputs_newer_than "$xcframework_info" "$herm_root" && {
		printf '%s\n' "CPSL build inputs changed"
		return 0
	}
	return 1
}

cpsl_ensure_should_reuse() {
	xcframework_info=$1

	! cpsl_ensure_rebuild_reason "$xcframework_info" >/dev/null
}

cpsl_ensure_pdfium_is_full() {
	for slice in ios-arm64 ios-simulator macos; do
		[ -f "$pdfium_path/$slice/lib/libpdfium.dylib" ] || return 1
	done
	return 0
}

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
herm_root=$(CDPATH= cd "$script_dir/.." && pwd -P)
. "$script_dir/lib/host-path.sh"
. "$script_dir/lib/cpsl-xcframework.sh"
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

work_dir=${CPSL_WORK_DIR:-"$herm_root/.herm-cpsl"}
out_dir=${OUT_DIR:-"$work_dir/artifacts/apple"}
xcframework_path="$out_dir/cpsl.xcframework"
pdfium_path="$out_dir/libs/pdfium"
xcframework_info=$(cpsl_xcframework_info_plist "$xcframework_path")

if [ "$skip_mode" -eq 1 ]; then
	[ -d "$xcframework_path" ] || die "missing $xcframework_path; rerun without --skip"
	cpsl_xcframework_is_full "$xcframework_info" || \
		die "$xcframework_path is incomplete; rerun without --skip"
	cpsl_ensure_pdfium_is_full || \
		die "$pdfium_path is incomplete; rerun without --skip"
	printf 'Using existing CPSL XCFramework: %s\n' "$xcframework_path"
	exit 0
fi

if cpsl_ensure_should_reuse "$xcframework_info"; then
	printf 'Using existing CPSL XCFramework: %s\n' "$xcframework_path"
	exit 0
fi
rebuild_reason=$(cpsl_ensure_rebuild_reason "$xcframework_info" || printf '%s\n' "unknown reason")

lock_file="$work_dir/.cpsl-xcframework-build.lock"
lock_timeout=7200
trap cpsl_ensure_release_lock EXIT HUP INT TERM
cpsl_ensure_acquire_lock "$lock_file" "$lock_timeout"

xcframework_info=$(cpsl_xcframework_info_plist "$xcframework_path")
if cpsl_ensure_should_reuse "$xcframework_info"; then
	printf 'Using existing CPSL XCFramework: %s\n' "$xcframework_path"
	exit 0
fi
rebuild_reason=$(cpsl_ensure_rebuild_reason "$xcframework_info" || printf '%s\n' "$rebuild_reason")

printf 'Building CPSL Apple XCFramework for: ios macos (%s)\n' "$rebuild_reason"
APPLE_PLATFORMS="ios macos" "$herm_root/scripts/build-cpsl-apple-xcframework.sh"
