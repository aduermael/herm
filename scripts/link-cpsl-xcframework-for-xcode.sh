#!/bin/sh
set -eu

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
herm_root=$(CDPATH= cd "$script_dir/.." && pwd -P)
. "$script_dir/lib/cpsl-xcframework.sh"

placeholder_dir="$herm_root/scripts/cpsl-xcframework-placeholder"
link_path="$placeholder_dir/cpsl.xcframework"
work_dir=${CPSL_WORK_DIR:-"$herm_root/.herm-cpsl"}
cargo_profile=$(cpsl_apple_cargo_profile_from_environment) || {
	printf '%s\n' "error: failed to resolve CPSL Cargo profile" >&2
	exit 1
}
out_dir=${OUT_DIR:-$(cpsl_apple_default_artifact_dir "$work_dir")}
built_path="$out_dir/cpsl.xcframework"
link_stamp="$out_dir/.xcode-linked-xcframework.stamp"
tmp_dir=

request_assignments=$(cpsl_apple_request_from_environment) || {
	printf '%s\n' "error: failed to resolve CPSL Apple build targets" >&2
	exit 1
}
eval "$request_assignments"
ios_device_targets=$IOS_DEVICE_TARGETS
ios_simulator_targets=$IOS_SIMULATOR_TARGETS
macos_targets=$MACOS_TARGETS

HERM_CPSL_FORCE_SUBMODULE=1
export HERM_CPSL_FORCE_SUBMODULE
unset CPSL_ROOT

cpsl_xcode_cleanup() {
	[ -n "${tmp_dir:-}" ] || return 0
	rm -rf "$tmp_dir"
}

trap cpsl_xcode_cleanup EXIT HUP INT TERM

cpsl_xcode_write_build_stamp() {
	stamp_path=${SCRIPT_OUTPUT_FILE_0:-}

	[ -n "$stamp_path" ] || return 0
	mkdir -p "$(dirname "$stamp_path")"
	printf '%s\n' "linked $(date -u '+%Y-%m-%dT%H:%M:%SZ')" >"$stamp_path"
}

cpsl_xcode_processed_dylib_is_placeholder() {
	dylib=$1

	[ -f "$dylib" ] || return 1

	size=$(wc -c <"$dylib" | tr -d '[:space:]')
	[ "${size:-0}" -lt 1024 ]
}

cpsl_xcode_processed_outputs_need_refresh() {
	products_dir=${TARGET_BUILD_DIR:-}

	[ -n "$products_dir" ] || return 1

	dylib="$products_dir/libcpsl.dylib"
	modulemap="$products_dir/include/module.modulemap"

	[ -f "$modulemap" ] || return 0
	cpsl_xcode_processed_dylib_is_placeholder "$dylib"
}

cpsl_xcode_invalidate_processed_outputs() {
	products_dir=${TARGET_BUILD_DIR:-}

	[ -n "$products_dir" ] || return 0

	if [ -e "$products_dir/libcpsl.dylib" ] || [ -d "$products_dir/include" ]; then
		printf 'Refreshing CPSL ProcessXCFramework outputs: %s\n' "$products_dir"
	fi
	rm -f "$products_dir/libcpsl.dylib"
	rm -rf "$products_dir/include"
}

cpsl_xcode_publish_processed_outputs() {
	products_dir=${TARGET_BUILD_DIR:-}
	seen_categories=
	published=0

	[ -n "$products_dir" ] || return 0

	for target in $ios_device_targets $ios_simulator_targets $macos_targets; do
		category=$(cpsl_apple_category_for_rust_target "$target") || exit 1
		case " $seen_categories " in
		*" $category "*)
			continue
			;;
		esac
		slice_id=$(cpsl_xcode_placeholder_slice_for_category "$category") || exit 1
		slice_dir="$link_path/$slice_id"

		[ -d "$slice_dir" ] || {
			printf '%s\n' "error: missing linked CPSL slice for publish: $slice_dir" >&2
			exit 1
		}
		[ -f "$slice_dir/libcpsl.dylib" ] || {
			printf '%s\n' "error: missing linked CPSL library for publish: $slice_dir/libcpsl.dylib" >&2
			exit 1
		}
		[ -f "$slice_dir/Headers/cpsl.h" ] || {
			printf '%s\n' "error: missing linked CPSL header for publish: $slice_dir/Headers/cpsl.h" >&2
			exit 1
		}
		[ -f "$slice_dir/Headers/module.modulemap" ] || {
			printf '%s\n' "error: missing linked CPSL module map for publish: $slice_dir/Headers/module.modulemap" >&2
			exit 1
		}

		mkdir -p "$products_dir/include"
		cp "$slice_dir/Headers/cpsl.h" "$products_dir/include/cpsl.h"
		cp "$slice_dir/Headers/module.modulemap" "$products_dir/include/module.modulemap"
		cp "$slice_dir/libcpsl.dylib" "$products_dir/.libcpsl.dylib.tmp"
		mv "$products_dir/.libcpsl.dylib.tmp" "$products_dir/libcpsl.dylib"
		seen_categories="${seen_categories:+$seen_categories }$category"
		published=1
	done

	[ "$published" -eq 1 ] || {
		printf '%s\n' "error: no CPSL slice to publish for current Xcode request" >&2
		exit 1
	}
}

cpsl_xcode_make_temp_dir() {
	if [ -z "${tmp_dir:-}" ]; then
		tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/herm-cpsl-xcode-link.XXXXXX")
	fi
	mkdir -p "$tmp_dir"
}

cpsl_xcode_file_metadata() {
	path=$1

	if metadata=$(stat -f '%z %m' "$path" 2>/dev/null); then
		printf '%s\n' "$metadata"
		return 0
	fi

	if metadata=$(stat -c '%s %Y' "$path" 2>/dev/null); then
		printf '%s\n' "$metadata"
		return 0
	fi

	return 1
}

cpsl_xcode_artifact_fingerprint() {
	xcframework_path=$1

	[ -d "$xcframework_path" ] || return 1

	(
		cd "$xcframework_path" || exit 1
		find . -type f -print | LC_ALL=C sort | while IFS= read -r file; do
			metadata=$(cpsl_xcode_file_metadata "$file") || exit 1
			printf '%s\t%s\n' "${file#./}" "$metadata"
		done
	)
}

cpsl_xcode_link_stamp_content() {
	artifact_fingerprint=$1

	printf 'IOS_DEVICE_TARGETS=%s\n' "$ios_device_targets"
	printf 'IOS_SIMULATOR_TARGETS=%s\n' "$ios_simulator_targets"
	printf 'MACOS_TARGETS=%s\n' "$macos_targets"
	printf 'CARGO_PROFILE=%s\n' "$cargo_profile"
	printf 'ARTIFACT_FINGERPRINT_BEGIN\n'
	printf '%s\n' "$artifact_fingerprint"
	printf 'ARTIFACT_FINGERPRINT_END\n'
}

cpsl_xcode_link_is_current() {
	expected_fingerprint=$1
	linked_info=$(cpsl_xcframework_info_plist "$link_path")

	[ -f "$link_stamp" ] || return 1
	[ -d "$link_path" ] || return 1
	cpsl_xcframework_is_placeholder "$link_path" && return 1
	cpsl_xcframework_satisfies_targets "$linked_info" "$ios_device_targets" "$ios_simulator_targets" "$macos_targets" || return 1

	actual_fingerprint=$(cat "$link_stamp") || return 1
	expected_fingerprint=$(cpsl_xcode_link_stamp_content "$expected_fingerprint")
	[ "$actual_fingerprint" = "$expected_fingerprint" ]
}

cpsl_xcode_placeholder_slice_for_category() {
	category=$1

	case "$category" in
	ios_device)
		printf '%s\n' ios-arm64
		;;
	ios_simulator)
		printf '%s\n' ios-arm64_x86_64-simulator
		;;
	macos)
		printf '%s\n' macos-arm64_x86_64
		;;
	*)
		printf '%s\n' "error: unsupported CPSL XCFramework category: $category" >&2
		return 1
		;;
	esac
}

cpsl_xcode_lipo_archs() {
	lib=$1

	[ -f "$lib" ] || {
		printf '%s\n' "error: missing library for lipo inspection: $lib" >&2
		return 1
	}

	xcrun lipo -archs "$lib"
}

cpsl_xcode_stub_sdk_for_category() {
	category=$1

	case "$category" in
	ios_simulator)
		printf '%s\n' iphonesimulator
		;;
	macos)
		printf '%s\n' macosx
		;;
	*)
		printf '%s\n' "error: validation stubs are not supported for CPSL category: $category" >&2
		return 1
		;;
	esac
}

cpsl_xcode_stub_min_flag_for_category() {
	category=$1

	case "$category" in
	ios_simulator)
		printf '%s\n' "-mios-simulator-version-min=${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"
		;;
	macos)
		printf '%s\n' "-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET:-14.0}"
		;;
	*)
		printf '%s\n' "error: validation stubs are not supported for CPSL category: $category" >&2
		return 1
		;;
	esac
}

cpsl_xcode_create_validation_stub() {
	category=$1
	arch=$2
	output=$3
	sdk=$(cpsl_xcode_stub_sdk_for_category "$category") || exit 1
	min_flag=$(cpsl_xcode_stub_min_flag_for_category "$category") || exit 1

	cpsl_xcode_make_temp_dir
	stub_source="$tmp_dir/cpsl-validation-stub.c"
	printf '%s\n' 'int herm_cpsl_validation_stub(void) { return 0; }' >"$stub_source"

	printf 'Creating CPSL validation stub (%s %s): %s\n' "$category" "$arch" "$output"
	if ! xcrun --sdk "$sdk" clang -dynamiclib -arch "$arch" "$min_flag" \
		-Wl,-install_name,@rpath/libcpsl.dylib \
		"$stub_source" -o "$output"; then
		printf '%s\n' "error: failed to create CPSL validation stub for $category $arch" >&2
		exit 1
	fi
}

cpsl_xcode_requested_arches_for_category() {
	category=$1
	targets=

	case "$category" in
	ios_device)
		targets=$ios_device_targets
		;;
	ios_simulator)
		targets=$ios_simulator_targets
		;;
	macos)
		targets=$macos_targets
		;;
	*)
		printf '%s\n' "error: unsupported CPSL XCFramework category: $category" >&2
		return 1
		;;
	esac

	arches=
	for target in $targets; do
		arch=$(cpsl_apple_arch_for_rust_target "$target") || return 1
		arches=$(cpsl_apple_list_append_unique "$arches" "$arch")
	done
	printf '%s\n' "$arches"
}

cpsl_xcode_placeholder_arches_for_category() {
	category=$1

	case "$category" in
	ios_device)
		printf '%s\n' arm64
		;;
	ios_simulator | macos)
		printf '%s\n' "arm64 x86_64"
		;;
	*)
		printf '%s\n' "error: unsupported CPSL XCFramework category: $category" >&2
		return 1
		;;
	esac
}

cpsl_xcode_make_overlay_validation_safe() {
	category=$1
	lib=$2
	requested_arches=$(cpsl_xcode_requested_arches_for_category "$category") || exit 1
	placeholder_arches=$(cpsl_xcode_placeholder_arches_for_category "$category") || exit 1
	lib_arches=$(cpsl_xcode_lipo_archs "$lib") || {
		printf '%s\n' "error: failed to inspect CPSL overlay library architectures: $lib" >&2
		exit 1
	}

	for arch in $requested_arches; do
		cpsl_xcode_arch_list_contains "$lib_arches" "$arch" || {
			printf '%s\n' "error: CPSL built library is missing requested architecture $arch: $lib" >&2
			exit 1
		}
	done

	missing_arches=
	for arch in $placeholder_arches; do
		if ! cpsl_xcode_arch_list_contains "$lib_arches" "$arch"; then
			missing_arches="${missing_arches:+$missing_arches }$arch"
		fi
	done
	[ -n "$missing_arches" ] || return 0

	if [ "$category" = ios_device ]; then
		printf '%s\n' "error: CPSL iOS device overlay is missing required architecture(s): $missing_arches" >&2
		exit 1
	fi

	cpsl_xcode_make_temp_dir
	set -- "$lib"
	for arch in $missing_arches; do
		stub_lib="$tmp_dir/libcpsl-$category-$arch-validation-stub.dylib"
		cpsl_xcode_create_validation_stub "$category" "$arch" "$stub_lib"
		set -- "$@" "$stub_lib"
	done

	universal_lib="$tmp_dir/libcpsl-$category-validation-safe.dylib"
	if ! xcrun lipo -create "$@" -output "$universal_lib"; then
		printf '%s\n' "error: failed to combine CPSL overlay library with validation stub(s): $lib" >&2
		exit 1
	fi
	cp "$universal_lib" "$lib"
}

cpsl_xcode_overlay_built_slice() {
	category=$1
	built_info=$(cpsl_xcframework_info_plist "$built_path")
	source_id=$(cpsl_xcframework_library_identifier_for_category "$built_info" "$category") || {
		printf '%s\n' "error: built CPSL XCFramework does not contain $category" >&2
		exit 1
	}
	dest_id=$(cpsl_xcode_placeholder_slice_for_category "$category") || exit 1
	source_dir="$built_path/$source_id"
	dest_dir="$link_path/$dest_id"
	dest_lib_tmp="$dest_dir/.libcpsl.dylib.tmp.$$"

	[ -d "$source_dir" ] || {
		printf '%s\n' "error: missing built CPSL XCFramework slice: $source_dir" >&2
		exit 1
	}
	[ -d "$dest_dir" ] || {
		printf '%s\n' "error: missing linked CPSL placeholder slice: $dest_dir" >&2
		exit 1
	}

	cpsl_xcode_make_temp_dir
	prepared_dir="$tmp_dir/prepared-$dest_id"
	rm -rf "$prepared_dir"
	cp -R "$source_dir" "$prepared_dir"
	cpsl_xcode_make_overlay_validation_safe "$category" "$prepared_dir/libcpsl.dylib"

	mkdir -p "$dest_dir/Headers"
	cp "$prepared_dir/Headers/cpsl.h" "$dest_dir/Headers/cpsl.h"
	if [ -f "$prepared_dir/Headers/module.modulemap" ]; then
		cp "$prepared_dir/Headers/module.modulemap" "$dest_dir/Headers/module.modulemap"
	fi
	cp "$prepared_dir/libcpsl.dylib" "$dest_lib_tmp"
	mv "$dest_lib_tmp" "$dest_dir/libcpsl.dylib"
}

cpsl_xcode_overlay_requested_slices() {
	seen_categories=
	overlaid=0

	for target in $ios_device_targets $ios_simulator_targets $macos_targets; do
		category=$(cpsl_apple_category_for_rust_target "$target") || exit 1
		case " $seen_categories " in
		*" $category "*)
			continue
			;;
		esac
		cpsl_xcode_overlay_built_slice "$category"
		seen_categories="${seen_categories:+$seen_categories }$category"
		overlaid=1
	done

	[ "$overlaid" -eq 1 ] || {
		printf '%s\n' "error: no CPSL XCFramework slices requested for overlay" >&2
		exit 1
	}
	rm -f "$(cpsl_xcframework_placeholder_marker "$link_path")"
}

cpsl_xcframework_remove_stray_links "$placeholder_dir" "$link_path"

# Xcode may run ProcessXCFramework before this script in the dependency target.
# Clear placeholder extracts early so the app target reprocesses after linking.
if cpsl_xcode_processed_outputs_need_refresh; then
	cpsl_xcode_invalidate_processed_outputs
fi

# Xcode validates the linked XCFramework path before any build phase runs, so a
# tracked bootstrap directory must exist on fresh clones. Locally, repair broken
# symlinks or non-directory contents before building the real artifact. Existing
# directories may be either the bootstrap placeholder or a prior local copy.
if [ -L "$link_path" ]; then
	if [ ! -e "$link_path" ]; then
		rm "$link_path"
		"$herm_root/scripts/bootstrap-cpsl-xcframework-placeholder.sh"
	fi
elif [ ! -e "$link_path" ]; then
	"$herm_root/scripts/bootstrap-cpsl-xcframework-placeholder.sh"
elif [ -d "$link_path" ]; then
	linked_info=$(cpsl_xcframework_info_plist "$link_path")
	if ! cpsl_xcframework_is_full "$linked_info"; then
		"$herm_root/scripts/bootstrap-cpsl-xcframework-placeholder.sh"
	fi
elif [ -e "$link_path" ]; then
	rm -rf "$link_path"
	"$herm_root/scripts/bootstrap-cpsl-xcframework-placeholder.sh"
fi

"$herm_root/scripts/ensure-cpsl-apple-xcframework.sh" "$@"

[ -d "$built_path" ] || {
	printf '%s\n' "error: missing built CPSL XCFramework: $built_path" >&2
	exit 1
}
built_fingerprint=$(cpsl_xcode_artifact_fingerprint "$built_path") || {
	printf '%s\n' "error: failed to fingerprint CPSL XCFramework: $built_path" >&2
	exit 1
}

if cpsl_xcode_link_is_current "$built_fingerprint"; then
	printf 'Using linked CPSL XCFramework: %s\n' "$link_path"
else
	"$herm_root/scripts/bootstrap-cpsl-xcframework-placeholder.sh"
	cpsl_xcode_overlay_requested_slices
	cpsl_xcframework_set_skip_worktree "$herm_root"
	mkdir -p "$(dirname "$link_stamp")"
	cpsl_xcode_link_stamp_content "$built_fingerprint" >"$link_stamp"
	printf 'Linked CPSL XCFramework: %s\n' "$link_path"
fi

cpsl_xcode_publish_processed_outputs
cpsl_xcode_write_build_stamp
