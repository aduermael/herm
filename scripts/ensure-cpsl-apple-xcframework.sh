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
  CPSL_XCFRAMEWORK_LOCK_MAX_AGE_SECONDS
                         Max lock hold time before auto-expiry (default: 3600).
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

# Default max hold: 1 hour. Cold Bazel CPSL builds can take a long time; a hard
# ceiling still prevents a dead/stuck holder from blocking Xcode forever.
cpsl_ensure_lock_max_age_seconds() {
	max_age=${CPSL_XCFRAMEWORK_LOCK_MAX_AGE_SECONDS:-3600}
	case "$max_age" in
	'' | *[!0-9]*)
		max_age=3600
		;;
	esac
	if [ "$max_age" -lt 60 ]; then
		max_age=60
	fi
	printf '%s\n' "$max_age"
}

cpsl_ensure_lock_poll_seconds() {
	printf '%s\n' 5
}

cpsl_ensure_lock_log_interval_seconds() {
	# Avoid spamming Xcode's build log on every poll.
	printf '%s\n' 30
}

cpsl_ensure_format_unix_time() {
	unix_time=$1

	if formatted=$(date -r "$unix_time" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null); then
		printf '%s\n' "$formatted"
		return 0
	fi
	if formatted=$(date -d "@$unix_time" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null); then
		printf '%s\n' "$formatted"
		return 0
	fi
	printf 'unix:%s\n' "$unix_time"
}

cpsl_ensure_format_duration() {
	total_seconds=$1

	if [ "$total_seconds" -lt 0 ]; then
		total_seconds=0
	fi
	hours=$((total_seconds / 3600))
	minutes=$(((total_seconds % 3600) / 60))
	seconds=$((total_seconds % 60))
	if [ "$hours" -gt 0 ]; then
		printf '%dh%02dm%02ds\n' "$hours" "$minutes" "$seconds"
	elif [ "$minutes" -gt 0 ]; then
		printf '%dm%02ds\n' "$minutes" "$seconds"
	else
		printf '%ds\n' "$seconds"
	fi
}

cpsl_ensure_lock_mtime() {
	path=$1

	if stat -f %m "$path" >/dev/null 2>&1; then
		stat -f %m "$path"
		return 0
	fi

	stat -c %Y "$path"
}

cpsl_ensure_read_first_numeric_file() {
	# Reads the first line of the first existing candidate that is all digits.
	for candidate in "$@"; do
		[ -f "$candidate" ] || continue
		value=$(cat "$candidate" 2>/dev/null || printf '')
		case "$value" in
		'' | *[!0-9]*)
			continue
			;;
		*)
			printf '%s\n' "$value"
			return 0
			;;
		esac
	done
	return 1
}

cpsl_ensure_read_lock_pid() {
	lock_path=$1

	# Prefer the canonical pid file, then tolerate cloud/Finder renames such as
	# "pid 2" that leave a non-empty lock directory and break rmdir reclaim.
	if [ -d "$lock_path" ]; then
		cpsl_ensure_read_first_numeric_file \
			"$lock_path/pid" \
			"$lock_path"/pid\ * || true
		return 0
	fi
	if [ -f "$lock_path" ]; then
		cpsl_ensure_read_first_numeric_file "$lock_path" || true
	fi
}

cpsl_ensure_read_lock_started_at() {
	lock_path=$1

	if [ -d "$lock_path" ]; then
		if started=$(cpsl_ensure_read_first_numeric_file \
			"$lock_path/started_at" \
			"$lock_path"/started_at\ *); then
			printf '%s\n' "$started"
			return 0
		fi
	fi

	cpsl_ensure_lock_mtime "$lock_path" 2>/dev/null
}

cpsl_ensure_read_lock_expires_at() {
	lock_path=$1
	max_age=$2

	if [ -d "$lock_path" ]; then
		if expires=$(cpsl_ensure_read_first_numeric_file \
			"$lock_path/expires_at" \
			"$lock_path"/expires_at\ *); then
			printf '%s\n' "$expires"
			return 0
		fi
	fi

	started=$(cpsl_ensure_read_lock_started_at "$lock_path") || return 1
	printf '%s\n' "$((started + max_age))"
}

cpsl_ensure_remove_stale_lock() {
	lock_path=$1
	reason=${2:-stale}

	# Force-remove the whole lock tree. A plain rmdir fails when iCloud/Finder
	# renames pid -> "pid 2" (or leaves other stray files), which previously
	# spun forever in the acquire loop.
	if [ -d "$lock_path" ] || [ -e "$lock_path" ] || [ -L "$lock_path" ]; then
		printf 'Removing CPSL XCFramework build lock (%s):\n  path: %s\n' \
			"$reason" "$lock_path"
		rm -rf "$lock_path"
	fi
}

cpsl_ensure_log_lock_status() {
	lock_path=$1
	lock_pid=$2
	holder_state=$3
	expires_at=$4
	now=$5
	reason=$6

	if [ "$expires_at" -gt "$now" ]; then
		remaining=$((expires_at - now))
		expiry_clause=$(printf 'expires at %s (in %s)' \
			"$(cpsl_ensure_format_unix_time "$expires_at")" \
			"$(cpsl_ensure_format_duration "$remaining")")
	else
		expiry_clause=$(printf 'expired at %s (%s ago)' \
			"$(cpsl_ensure_format_unix_time "$expires_at")" \
			"$(cpsl_ensure_format_duration $((now - expires_at)))")
	fi

	printf 'CPSL XCFramework build lock is held (%s).\n' "$reason"
	printf '  path:        %s\n' "$lock_path"
	if [ -n "$lock_pid" ]; then
		printf '  holder_pid:  %s (%s)\n' "$lock_pid" "$holder_state"
	else
		printf '  holder_pid:  unknown\n'
	fi
	printf '  status:      %s\n' "$expiry_clause"
	printf '  auto-expire: locks are reclaimed after expiry or when the holder exits\n'
	printf '  force unlock: rm -rf %s\n' "$lock_path"
}

cpsl_ensure_acquire_lock() {
	lock_path=$1
	max_age=$(cpsl_ensure_lock_max_age_seconds)
	poll_seconds=$(cpsl_ensure_lock_poll_seconds)
	log_interval=$(cpsl_ensure_lock_log_interval_seconds)
	last_wait_log_at=0

	mkdir -p "$(dirname "$lock_path")"

	while ! mkdir "$lock_path" 2>/dev/null; do
		now=$(date +%s)
		lock_pid=$(cpsl_ensure_read_lock_pid "$lock_path" || true)
		holder_alive=0
		holder_state=unknown
		if [ -n "$lock_pid" ]; then
			if kill -0 "$lock_pid" 2>/dev/null; then
				holder_alive=1
				holder_state=alive
			else
				holder_state=dead
			fi
		fi

		expires_at=$(cpsl_ensure_read_lock_expires_at "$lock_path" "$max_age" 2>/dev/null) || expires_at=
		if [ -z "$expires_at" ]; then
			cpsl_ensure_remove_stale_lock "$lock_path" "unreadable metadata"
			continue
		fi

		# Dead / missing holder: reclaim immediately (no need to wait for expiry).
		if [ "$holder_alive" -eq 0 ]; then
			if [ -n "$lock_pid" ]; then
				reason="holder pid $lock_pid is not running"
			else
				reason="no live holder pid"
			fi
			cpsl_ensure_log_lock_status \
				"$lock_path" "$lock_pid" "$holder_state" "$expires_at" "$now" "$reason"
			cpsl_ensure_remove_stale_lock "$lock_path" "$reason"
			continue
		fi

		# Live holder past the hard ceiling: steal so Xcode cannot hang forever.
		if [ "$now" -ge "$expires_at" ]; then
			reason="expired while held by live pid $lock_pid"
			cpsl_ensure_log_lock_status \
				"$lock_path" "$lock_pid" "$holder_state" "$expires_at" "$now" "$reason"
			cpsl_ensure_remove_stale_lock "$lock_path" "$reason"
			continue
		fi

		# Live holder still within the lease: wait, and re-log periodically.
		if [ $((now - last_wait_log_at)) -ge "$log_interval" ] || [ "$last_wait_log_at" -eq 0 ]; then
			cpsl_ensure_log_lock_status \
				"$lock_path" \
				"$lock_pid" \
				"$holder_state" \
				"$expires_at" \
				"$now" \
				"another CPSL build is in progress"
			last_wait_log_at=$now
		fi
		sleep "$poll_seconds"
	done

	now=$(date +%s)
	expires_at=$((now + max_age))
	printf '%s\n' "$$" >"$lock_path/pid"
	printf '%s\n' "$now" >"$lock_path/started_at"
	printf '%s\n' "$expires_at" >"$lock_path/expires_at"
	printf 'Acquired CPSL XCFramework build lock.\n'
	printf '  path:        %s\n' "$lock_path"
	printf '  holder_pid:  %s\n' "$$"
	printf '  expires at:  %s (in %s)\n' \
		"$(cpsl_ensure_format_unix_time "$expires_at")" \
		"$(cpsl_ensure_format_duration "$max_age")"
	printf '  force unlock: rm -rf %s\n' "$lock_path"
	lock_owned=1
}

cpsl_ensure_release_lock() {
	[ "${lock_owned:-0}" -eq 1 ] || return 0
	if [ -n "${lock_file:-}" ]; then
		printf 'Released CPSL XCFramework build lock: %s\n' "$lock_file"
		rm -rf "$lock_file"
	fi
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
herm_ensure_host_tools_path

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
build_system=$(cpsl_apple_build_system_from_environment) || die "failed to resolve CPSL Apple build system"
if [ "$build_system" = cargo ]; then
	cargo_profile=$(cpsl_apple_cargo_profile_from_environment) || die "failed to resolve CPSL Cargo profile"
	cargo_incremental=$(cpsl_apple_cargo_incremental_from_environment) || die "failed to resolve CPSL incremental compilation setting"
else
	cargo_profile=unused
	cargo_incremental=unused
fi
out_dir=${OUT_DIR:-$(cpsl_apple_default_artifact_dir "$work_dir")}
default_cpsl_root="$herm_root/external/cpsl"
cpsl_input_root=${CPSL_ROOT:-"$default_cpsl_root"}
[ "${HERM_CPSL_FORCE_SUBMODULE:-0}" -eq 0 ] || cpsl_input_root=$default_cpsl_root
if [ "$build_system" = bazel ]; then
	if [ -n "${CPSL_ROOT:-}" ]; then
		requested_cpsl_root=$(CDPATH= cd "$CPSL_ROOT" && pwd -P) || die "CPSL_ROOT is not a directory: $CPSL_ROOT"
		[ "$requested_cpsl_root" = "$default_cpsl_root" ] || \
			die "Bazel builds use $default_cpsl_root; set CPSL_APPLE_BUILD_SYSTEM=cargo to build a different CPSL_ROOT"
	fi
	cpsl_input_root=$default_cpsl_root
fi
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
CPSL_APPLE_BUILD_SYSTEM="$build_system" \
	"$herm_root/scripts/build-cpsl-apple-xcframework.sh"
