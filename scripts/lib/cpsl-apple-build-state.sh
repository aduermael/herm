#!/bin/sh

# Content-based cache identity for CPSL Apple artifacts.
# Source after scripts/lib/cpsl-xcframework.sh.

cpsl_apple_state_sha256_file() {
	path=$1

	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$path" | awk '{ print $1 }'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$path" | awk '{ print $1 }'
	else
		printf '%s\n' "sha256sum or shasum is required" >&2
		return 1
	fi
}

cpsl_apple_state_sha256_stream() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum | awk '{ print $1 }'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 | awk '{ print $1 }'
	else
		printf '%s\n' "sha256sum or shasum is required" >&2
		return 1
	fi
}

cpsl_apple_state_value() {
	printf '%s' "$1" | tr '\r\n' '  '
}

cpsl_apple_state_file_record() {
	label=$1
	path=$2

	if [ -f "$path" ]; then
		printf '%s\t%s\n' "$label" "$(cpsl_apple_state_sha256_file "$path")"
	else
		printf '%s\tmissing\n' "$label"
	fi
}

cpsl_apple_source_tree_state() {
	source_root=$1
	source_path=$(CDPATH= cd "$source_root" && pwd -P) || return 1

	if source_revision=$(git -C "$source_path" rev-parse --verify HEAD 2>/dev/null); then
		dirty_state=$(
			{
				git -C "$source_path" diff --binary HEAD --
				git -C "$source_path" ls-files --others --exclude-standard | while IFS= read -r relative_path; do
					[ -f "$source_path/$relative_path" ] || continue
					cpsl_apple_state_file_record "untracked/$relative_path" "$source_path/$relative_path"
				done
			} | cpsl_apple_state_sha256_stream
		) || return 1
		printf 'git:%s:%s\n' "$source_revision" "$dirty_state"
		return 0
	fi

	(
		cd "$source_path" || exit 1
		find . \( -name .git -o -name target \) -prune -o -type f -print | LC_ALL=C sort |
			while IFS= read -r relative_path; do
				cpsl_apple_state_file_record "${relative_path#./}" "$source_path/${relative_path#./}"
			done
	) | cpsl_apple_state_sha256_stream
}

cpsl_apple_builder_inputs_state() {
	herm_root=$1
	patch_dir="$herm_root/scripts/cpsl-patches"
	series_file="$patch_dir/series"

	{
		for relative_path in \
			rust-toolchain.toml \
			scripts/build-cpsl-apple-xcframework.sh \
			scripts/apply-cpsl-patches.sh \
			scripts/lib/build-manifest.sh \
			scripts/lib/cpsl-apple-build-state.sh \
			scripts/lib/cpsl-xcframework.sh \
			scripts/lib/host-path.sh
		do
			cpsl_apple_state_file_record "$relative_path" "$herm_root/$relative_path"
		done

		cpsl_apple_state_file_record scripts/cpsl-patches/series "$series_file"
		if [ -f "$series_file" ]; then
			while IFS= read -r name || [ -n "$name" ]; do
				case "$name" in
				'' | '#'* ) continue ;;
				esac
				cpsl_apple_state_file_record "scripts/cpsl-patches/$name" "$patch_dir/$name"
			done <"$series_file"
		fi
	} | cpsl_apple_state_sha256_stream
}

cpsl_apple_build_stamp_path() {
	out_dir=$1
	printf '%s/.cpsl-apple-build.stamp' "$out_dir"
}

cpsl_apple_cargo_cache_namespace_content() {
	rustc_version=$1
	cargo_version=$2
	xcode_version=$3
	ios_deployment_target=${IOS_DEPLOYMENT_TARGET:-${IPHONEOS_DEPLOYMENT_TARGET:-17.0}}
	macos_deployment_target=${MACOSX_DEPLOYMENT_TARGET:-14.0}
	[ -n "${IOS_DEVICE_TARGETS:-}${IOS_SIMULATOR_TARGETS:-}" ] || ios_deployment_target=unused
	[ -n "${MACOS_TARGETS:-}" ] || macos_deployment_target=unused

	{
		printf 'rustc=%s\n' "$(cpsl_apple_state_value "$rustc_version")"
		printf 'cargo=%s\n' "$(cpsl_apple_state_value "$cargo_version")"
		printf 'xcode=%s\n' "$(cpsl_apple_state_value "$xcode_version")"
		printf 'ios_deployment_target=%s\n' "$ios_deployment_target"
		printf 'macos_deployment_target=%s\n' "$macos_deployment_target"
		printf 'rustflags=%s\n' "$(cpsl_apple_state_value "${RUSTFLAGS:-}")"
	} | cpsl_apple_state_sha256_stream | cut -c 1-16
}

cpsl_apple_cargo_cache_namespace() {
	rustc_version=$(rustc -vV 2>/dev/null) || return 1
	cargo_version=$(cargo --version 2>/dev/null) || return 1
	xcode_version=$(xcodebuild -version 2>/dev/null) || return 1
	printf 'apple-%s\n' "$(cpsl_apple_cargo_cache_namespace_content "$rustc_version" "$cargo_version" "$xcode_version")"
}

cpsl_apple_build_stamp_content() {
	herm_root=$1
	source_root=$2
	build_profile=$3
	cargo_profile=$4
	cargo_incremental=$5
	rustc_version=$6
	cargo_version=$7
	xcode_version=$8
	source_path=$(CDPATH= cd "$source_root" && pwd -P) || return 1
	source_state=$(cpsl_apple_source_tree_state "$source_path") || return 1
	builder_state=$(cpsl_apple_builder_inputs_state "$herm_root") || return 1
	ios_deployment_target=${IOS_DEPLOYMENT_TARGET:-${IPHONEOS_DEPLOYMENT_TARGET:-17.0}}
	macos_deployment_target=${MACOSX_DEPLOYMENT_TARGET:-14.0}
	[ -n "${IOS_DEVICE_TARGETS:-}${IOS_SIMULATOR_TARGETS:-}" ] || ios_deployment_target=unused
	[ -n "${MACOS_TARGETS:-}" ] || macos_deployment_target=unused

	printf 'format=1\n'
	printf 'source_path=%s\n' "$(cpsl_apple_state_value "$source_path")"
	printf 'source_state=%s\n' "$(cpsl_apple_state_value "$source_state")"
	printf 'builder_inputs_sha256=%s\n' "$builder_state"
	printf 'profile=%s\n' "$build_profile"
	if [ "$build_profile" = apple-app ]; then
		printf 'features=embedded-agent\n'
	else
		printf 'features=ffi-minimal\n'
	fi
	printf 'configuration=%s\n' "$(cpsl_apple_state_value "${CONFIGURATION:-manual}")"
	printf 'cargo_profile=%s\n' "$cargo_profile"
	printf 'cargo_incremental=%s\n' "$cargo_incremental"
	printf 'apple_platforms=%s\n' "$(cpsl_apple_state_value "$APPLE_PLATFORMS")"
	printf 'ios_device_targets=%s\n' "$(cpsl_apple_state_value "$IOS_DEVICE_TARGETS")"
	printf 'ios_simulator_targets=%s\n' "$(cpsl_apple_state_value "$IOS_SIMULATOR_TARGETS")"
	printf 'macos_targets=%s\n' "$(cpsl_apple_state_value "$MACOS_TARGETS")"
	printf 'ios_deployment_target=%s\n' "$(cpsl_apple_state_value "$ios_deployment_target")"
	printf 'macos_deployment_target=%s\n' "$(cpsl_apple_state_value "$macos_deployment_target")"
	printf 'pdfium_version=%s\n' "$(cpsl_apple_state_value "${PDFIUM_VERSION:-7734}")"
	printf 'rustflags=%s\n' "$(cpsl_apple_state_value "${RUSTFLAGS:-}")"
	printf 'rustc_version=%s\n' "$(cpsl_apple_state_value "$rustc_version")"
	printf 'cargo_version=%s\n' "$(cpsl_apple_state_value "$cargo_version")"
	printf 'xcode_version=%s\n' "$(cpsl_apple_state_value "$xcode_version")"
}

cpsl_apple_build_stamp_expected() {
	herm_root=$1
	source_root=$2
	build_profile=$3
	cargo_profile=$4
	cargo_incremental=$5

	rustc_version=$(rustc -vV 2>/dev/null) || return 1
	cargo_version=$(cargo --version 2>/dev/null) || return 1
	xcode_version=$(xcodebuild -version 2>/dev/null) || return 1
	cpsl_apple_build_stamp_content \
		"$herm_root" "$source_root" "$build_profile" "$cargo_profile" "$cargo_incremental" \
		"$rustc_version" "$cargo_version" "$xcode_version"
}

cpsl_apple_build_stamp_matches_value() {
	stamp_path=$1
	expected=$2

	[ -f "$stamp_path" ] || return 1
	actual=$(cat "$stamp_path") || return 1
	[ "$actual" = "$expected" ]
}

cpsl_apple_build_stamp_write_value() {
	stamp_path=$1
	content=$2
	tmp_path="$stamp_path.tmp.$$"

	mkdir -p "$(dirname "$stamp_path")"
	printf '%s\n' "$content" >"$tmp_path"
	mv "$tmp_path" "$stamp_path"
}
