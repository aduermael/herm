# Shared CPSL XCFramework validation helpers.
# Source this file; do not execute directly.

cpsl_xcframework_info_plist() {
	xcframework_path=$1
	printf '%s/Info.plist' "$xcframework_path"
}

cpsl_xcframework_plist_tokens() {
	info=$1

	[ -f "$info" ] || return 1
	awk '{ gsub(/></, ">\n<"); print }' "$info"
}

cpsl_apple_shell_quote() {
	printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

cpsl_apple_list_append_unique() {
	list=$1
	value=$2

	[ -n "$value" ] || {
		printf '%s' "$list"
		return 0
	}

	for entry in $list; do
		[ "$entry" = "$value" ] && {
			printf '%s' "$list"
			return 0
		}
	done

	printf '%s%s%s' "$list" "${list:+ }" "$value"
}

cpsl_xcode_arch_list_contains() {
	arch_list=$1
	want_arch=$2

	for listed_arch in $arch_list; do
		[ "$listed_arch" = "$want_arch" ] && return 0
	done

	return 1
}

cpsl_apple_platform_from_xcode() {
	platform_name=${1:-}
	sdk_name=${2:-}

	case "$platform_name" in
	iphoneos | iphonesimulator | macosx)
		printf '%s\n' "$platform_name"
		return 0
		;;
	xros | xrsimulator)
		printf '%s\n' "CPSL does not yet support visionOS. Supported platforms: iOS and macOS." >&2
		return 1
		;;
	"")
		;;
	*)
		printf '%s\n' "unsupported Apple platform for CPSL: $platform_name" >&2
		return 1
		;;
	esac

	case "$sdk_name" in
	iphoneos*)
		printf '%s\n' iphoneos
		;;
	iphonesimulator*)
		printf '%s\n' iphonesimulator
		;;
	macosx*)
		printf '%s\n' macosx
		;;
	xros* | xrsimulator*)
		printf '%s\n' "CPSL does not yet support visionOS. Supported platforms: iOS and macOS." >&2
		return 1
		;;
	"")
		printf '%s\n' "PLATFORM_NAME or SDK_NAME is required to derive CPSL Apple targets from Xcode" >&2
		return 1
		;;
	*)
		printf '%s\n' "unsupported Apple SDK for CPSL: $sdk_name" >&2
		return 1
		;;
	esac
}

cpsl_apple_archs_from_xcode() {
	archs=${1:-}
	current_arch=${2:-}

	if [ -n "$archs" ]; then
		printf '%s\n' "$archs"
		return 0
	fi

	case "$current_arch" in
	"" | undefined_arch)
		printf '%s\n' "ARCHS is required to derive CPSL Apple targets from Xcode" >&2
		return 1
		;;
	*)
		printf '%s\n' "$current_arch"
		;;
	esac
}

cpsl_apple_xcode_current_arch() {
	current_arch=${CURRENT_ARCH:-}

	case "$current_arch" in
	"" | undefined_arch)
		printf '%s\n' "${NATIVE_ARCH_ACTUAL:-}"
		;;
	*)
		printf '%s\n' "$current_arch"
		;;
	esac
}

cpsl_apple_rust_target_for_platform_arch() {
	platform=$1
	arch=$2

	case "$platform:$arch" in
	iphoneos:arm64)
		printf '%s\n' aarch64-apple-ios
		;;
	iphonesimulator:arm64)
		printf '%s\n' aarch64-apple-ios-sim
		;;
	iphonesimulator:x86_64)
		printf '%s\n' x86_64-apple-ios
		;;
	macosx:arm64)
		printf '%s\n' aarch64-apple-darwin
		;;
	macosx:x86_64)
		printf '%s\n' x86_64-apple-darwin
		;;
	*)
		printf '%s\n' "unsupported CPSL Apple platform/architecture: $platform $arch" >&2
		return 1
		;;
	esac
}

cpsl_apple_category_for_rust_target() {
	target=$1

	case "$target" in
	aarch64-apple-ios)
		printf '%s\n' ios_device
		;;
	aarch64-apple-ios-sim | x86_64-apple-ios)
		printf '%s\n' ios_simulator
		;;
	aarch64-apple-darwin | x86_64-apple-darwin)
		printf '%s\n' macos
		;;
	*)
		printf '%s\n' "unsupported CPSL Apple Rust target: $target" >&2
		return 1
		;;
	esac
}

cpsl_apple_arch_for_rust_target() {
	target=$1

	case "$target" in
	aarch64-apple-ios | aarch64-apple-ios-sim | aarch64-apple-darwin)
		printf '%s\n' arm64
		;;
	x86_64-apple-ios | x86_64-apple-darwin)
		printf '%s\n' x86_64
		;;
	*)
		printf '%s\n' "unsupported CPSL Apple Rust target: $target" >&2
		return 1
		;;
	esac
}

cpsl_apple_request_print() {
	apple_platforms=$1
	ios_device_targets=$2
	ios_simulator_targets=$3
	macos_targets=$4
	description=$5

	pdfium_slices=
	if [ -n "$ios_device_targets" ]; then
		pdfium_slices=$(cpsl_apple_list_append_unique "$pdfium_slices" ios-arm64)
	fi
	if [ -n "$ios_simulator_targets" ]; then
		pdfium_slices=$(cpsl_apple_list_append_unique "$pdfium_slices" ios-simulator)
	fi
	if [ -n "$macos_targets" ]; then
		pdfium_slices=$(cpsl_apple_list_append_unique "$pdfium_slices" macos)
	fi

	printf 'APPLE_PLATFORMS=%s\n' "$(cpsl_apple_shell_quote "$apple_platforms")"
	printf 'IOS_DEVICE_TARGETS=%s\n' "$(cpsl_apple_shell_quote "$ios_device_targets")"
	printf 'IOS_SIMULATOR_TARGETS=%s\n' "$(cpsl_apple_shell_quote "$ios_simulator_targets")"
	printf 'MACOS_TARGETS=%s\n' "$(cpsl_apple_shell_quote "$macos_targets")"
	printf 'CPSL_PDFIUM_SLICES=%s\n' "$(cpsl_apple_shell_quote "$pdfium_slices")"
	printf 'CPSL_REQUEST_DESCRIPTION=%s\n' "$(cpsl_apple_shell_quote "$description")"
}

cpsl_apple_request_from_xcode_env() {
	platform=$(cpsl_apple_platform_from_xcode "${PLATFORM_NAME:-}" "${SDK_NAME:-}") || return 1
	current_arch=$(cpsl_apple_xcode_current_arch)
	archs=$(cpsl_apple_archs_from_xcode "${ARCHS:-}" "$current_arch") || return 1
	apple_platforms=
	ios_device_targets=
	ios_simulator_targets=
	macos_targets=

	for arch in $archs; do
		target=$(cpsl_apple_rust_target_for_platform_arch "$platform" "$arch") || return 1
		case "$platform" in
		iphoneos)
			apple_platforms=$(cpsl_apple_list_append_unique "$apple_platforms" ios)
			ios_device_targets=$(cpsl_apple_list_append_unique "$ios_device_targets" "$target")
			;;
		iphonesimulator)
			apple_platforms=$(cpsl_apple_list_append_unique "$apple_platforms" ios)
			ios_simulator_targets=$(cpsl_apple_list_append_unique "$ios_simulator_targets" "$target")
			;;
		macosx)
			apple_platforms=$(cpsl_apple_list_append_unique "$apple_platforms" macos)
			macos_targets=$(cpsl_apple_list_append_unique "$macos_targets" "$target")
			;;
		esac
	done

	cpsl_apple_request_print "$apple_platforms" "$ios_device_targets" "$ios_simulator_targets" "$macos_targets" "$platform $archs"
}

cpsl_apple_request_from_build_vars() {
	apple_platforms=$1
	ios_device_targets=$2
	ios_simulator_targets=$3
	macos_targets=$4
	include_ios=0
	include_macos=0
	normalized_platforms=

	[ -n "$apple_platforms" ] || {
		printf '%s\n' "APPLE_PLATFORMS must not be empty" >&2
		return 1
	}

	for platform in $apple_platforms; do
		case "$platform" in
		ios)
			include_ios=1
			normalized_platforms=$(cpsl_apple_list_append_unique "$normalized_platforms" ios)
			;;
		macos)
			include_macos=1
			normalized_platforms=$(cpsl_apple_list_append_unique "$normalized_platforms" macos)
			;;
		*)
			printf '%s\n' "unsupported APPLE_PLATFORMS entry: $platform" >&2
			return 1
			;;
		esac
	done

	[ "$include_ios" -eq 1 ] || [ "$include_macos" -eq 1 ] || {
		printf '%s\n' "APPLE_PLATFORMS must include ios, macos, or both" >&2
		return 1
	}

	if [ "$include_ios" -eq 0 ]; then
		ios_device_targets=
		ios_simulator_targets=
	elif [ -z "$ios_device_targets" ] && [ -z "$ios_simulator_targets" ]; then
		printf '%s\n' "IOS_DEVICE_TARGETS or IOS_SIMULATOR_TARGETS must be non-empty when APPLE_PLATFORMS includes ios" >&2
		return 1
	fi

	if [ "$include_macos" -eq 0 ]; then
		macos_targets=
	elif [ -z "$macos_targets" ]; then
		printf '%s\n' "MACOS_TARGETS must not be empty when APPLE_PLATFORMS includes macos" >&2
		return 1
	fi

	for target in $ios_device_targets; do
		category=$(cpsl_apple_category_for_rust_target "$target") || return 1
		[ "$category" = ios_device ] || {
			printf '%s\n' "IOS_DEVICE_TARGETS contains non-device target: $target" >&2
			return 1
		}
	done
	for target in $ios_simulator_targets; do
		category=$(cpsl_apple_category_for_rust_target "$target") || return 1
		[ "$category" = ios_simulator ] || {
			printf '%s\n' "IOS_SIMULATOR_TARGETS contains non-simulator target: $target" >&2
			return 1
		}
	done
	for target in $macos_targets; do
		category=$(cpsl_apple_category_for_rust_target "$target") || return 1
		[ "$category" = macos ] || {
			printf '%s\n' "MACOS_TARGETS contains non-macOS target: $target" >&2
			return 1
		}
	done

	cpsl_apple_request_print "$normalized_platforms" "$ios_device_targets" "$ios_simulator_targets" "$macos_targets" \
		"$normalized_platforms; ios-device=$ios_device_targets; ios-simulator=$ios_simulator_targets; macos=$macos_targets"
}

cpsl_apple_has_xcode_selection() {
	[ -n "${PLATFORM_NAME:-}" ] || [ -n "${SDK_NAME:-}" ]
}

cpsl_apple_request_from_environment() {
	if cpsl_apple_has_xcode_selection; then
		cpsl_apple_request_from_xcode_env
		return $?
	fi

	cpsl_apple_request_from_build_vars \
		"${APPLE_PLATFORMS-"ios macos"}" \
		"${IOS_DEVICE_TARGETS-"aarch64-apple-ios"}" \
		"${IOS_SIMULATOR_TARGETS-"aarch64-apple-ios-sim x86_64-apple-ios"}" \
		"${MACOS_TARGETS-"aarch64-apple-darwin x86_64-apple-darwin"}"
}

cpsl_apple_cargo_profile_from_configuration() {
	configuration=${1:-}

	case "$configuration" in
	Debug)
		printf '%s\n' debug
		;;
	"" | Release)
		printf '%s\n' release
		;;
	*)
		printf '%s\n' "unsupported Xcode configuration for CPSL build: $configuration" >&2
		return 1
		;;
	esac
}

cpsl_apple_cargo_profile_from_environment() {
	cpsl_apple_cargo_profile_from_configuration "${CONFIGURATION:-}"
}

cpsl_apple_cargo_incremental_from_environment() {
	if [ "${CARGO_INCREMENTAL+x}" = x ]; then
		cargo_incremental=$CARGO_INCREMENTAL
	else
		cargo_profile=$(cpsl_apple_cargo_profile_from_environment) || return 1
		case "$cargo_profile" in
		debug) cargo_incremental=1 ;;
		release) cargo_incremental=0 ;;
		esac
	fi

	case "$cargo_incremental" in
	0 | 1)
		printf '%s\n' "$cargo_incremental"
		;;
	*)
		printf '%s\n' "CARGO_INCREMENTAL must be 0 or 1, got: $cargo_incremental" >&2
		return 1
		;;
	esac
}

cpsl_apple_default_artifact_dir() {
	work_dir=$1

	if [ -n "${CONFIGURATION:-}" ]; then
		printf '%s/artifacts/apple/%s' "$work_dir" "$CONFIGURATION"
	else
		printf '%s/artifacts/apple' "$work_dir"
	fi
}

cpsl_xcframework_has_library_arch() {
	info=$1
	want_platform=$2
	want_variant=$3
	want_arch=$4

	cpsl_xcframework_plist_tokens "$info" | awk -v want_platform="$want_platform" -v want_variant="$want_variant" -v want_arch="$want_arch" '
		/<dict>/ {
			depth++
			if (depth == 2) {
				platform = ""
				variant = ""
				arch = 0
				in_arches = 0
			}
			next
		}
		depth == 2 && /<key>SupportedPlatform<\/key>/ {
			getline
			if ($0 ~ /<string>ios<\/string>/) {
				platform = "ios"
			} else if ($0 ~ /<string>macos<\/string>/ || $0 ~ /<string>macosx<\/string>/) {
				platform = "macos"
			}
			next
		}
		depth == 2 && /<key>SupportedPlatformVariant<\/key>/ {
			getline
			if ($0 ~ /<string>simulator<\/string>/) {
				variant = "simulator"
			}
			next
		}
		depth == 2 && /<key>SupportedArchitectures<\/key>/ {
			in_arches = 1
			next
		}
		depth == 2 && in_arches && /<\/array>/ {
			in_arches = 0
			next
		}
		depth == 2 && in_arches {
			if ($0 ~ "<string>" want_arch "</string>") {
				arch = 1
			}
			next
		}
		/<\/dict>/ {
			if (depth == 2 && platform == want_platform && variant == want_variant && arch) {
				found = 1
			}
			depth--
			next
		}
		END {
			exit found ? 0 : 1
		}
	'
}

cpsl_xcframework_library_identifier() {
	info=$1
	want_platform=$2
	want_variant=$3

	cpsl_xcframework_plist_tokens "$info" | awk -v want_platform="$want_platform" -v want_variant="$want_variant" '
		/<dict>/ {
			depth++
			if (depth == 2) {
				platform = ""
				variant = ""
				identifier = ""
			}
			next
		}
		depth == 2 && /<key>LibraryIdentifier<\/key>/ {
			getline
			identifier = $0
			gsub(/.*<string>/, "", identifier)
			gsub(/<\/string>.*/, "", identifier)
			next
		}
		depth == 2 && /<key>SupportedPlatform<\/key>/ {
			getline
			if ($0 ~ /<string>ios<\/string>/) {
				platform = "ios"
			} else if ($0 ~ /<string>macos<\/string>/ || $0 ~ /<string>macosx<\/string>/) {
				platform = "macos"
			}
			next
		}
		depth == 2 && /<key>SupportedPlatformVariant<\/key>/ {
			getline
			if ($0 ~ /<string>simulator<\/string>/) {
				variant = "simulator"
			}
			next
		}
		/<\/dict>/ {
			if (depth == 2 && platform == want_platform && variant == want_variant && identifier != "") {
				print identifier
				found = 1
				exit
			}
			depth--
			next
		}
		END {
			exit found ? 0 : 1
		}
	'
}

cpsl_xcframework_library_identifier_for_category() {
	info=$1
	category=$2

	case "$category" in
	ios_device)
		cpsl_xcframework_library_identifier "$info" ios ""
		;;
	ios_simulator)
		cpsl_xcframework_library_identifier "$info" ios simulator
		;;
	macos)
		cpsl_xcframework_library_identifier "$info" macos ""
		;;
	*)
		printf '%s\n' "unsupported CPSL XCFramework category: $category" >&2
		return 1
		;;
	esac
}

cpsl_xcframework_has_rust_target() {
	info=$1
	target=$2
	category=$(cpsl_apple_category_for_rust_target "$target") || return 1
	arch=$(cpsl_apple_arch_for_rust_target "$target") || return 1

	case "$category" in
	ios_device)
		cpsl_xcframework_has_library_arch "$info" ios "" "$arch"
		;;
	ios_simulator)
		cpsl_xcframework_has_library_arch "$info" ios simulator "$arch"
		;;
	macos)
		cpsl_xcframework_has_library_arch "$info" macos "" "$arch"
		;;
	*)
		return 1
		;;
	esac
}

cpsl_xcframework_satisfies_targets() {
	info=$1
	ios_device_targets=$2
	ios_simulator_targets=$3
	macos_targets=$4

	for target in $ios_device_targets $ios_simulator_targets $macos_targets; do
		cpsl_xcframework_has_rust_target "$info" "$target" || return 1
	done

	return 0
}

cpsl_xcframework_architecture_keys() {
	info=$1

	cpsl_xcframework_plist_tokens "$info" | awk '
		/<dict>/ {
			depth++
			if (depth == 2) {
				platform = ""
				variant = ""
				arch_count = 0
				in_arches = 0
			}
			next
		}
		depth == 2 && /<key>SupportedPlatform<\/key>/ {
			getline
			value = $0
			gsub(/.*<string>/, "", value)
			gsub(/<\/string>.*/, "", value)
			if (value == "macosx") value = "macos"
			platform = value
			next
		}
		depth == 2 && /<key>SupportedPlatformVariant<\/key>/ {
			getline
			variant = $0
			gsub(/.*<string>/, "", variant)
			gsub(/<\/string>.*/, "", variant)
			next
		}
		depth == 2 && /<key>SupportedArchitectures<\/key>/ {
			in_arches = 1
			next
		}
		depth == 2 && in_arches && /<\/array>/ {
			in_arches = 0
			next
		}
		depth == 2 && in_arches && /<string>/ {
			value = $0
			gsub(/.*<string>/, "", value)
			gsub(/<\/string>.*/, "", value)
			arches[++arch_count] = value
			next
		}
		/<\/dict>/ {
			if (depth == 2 && platform != "") {
				for (i = 1; i <= arch_count; i++) {
					print platform ":" variant ":" arches[i]
				}
			}
			depth--
			next
		}
	'
}

cpsl_xcframework_expected_architecture_keys() {
	for target in "$@"; do
		category=$(cpsl_apple_category_for_rust_target "$target") || return 1
		arch=$(cpsl_apple_arch_for_rust_target "$target") || return 1
		case "$category" in
		ios_device)
			printf 'ios::%s\n' "$arch"
			;;
		ios_simulator)
			printf 'ios:simulator:%s\n' "$arch"
			;;
		macos)
			printf 'macos::%s\n' "$arch"
			;;
		esac
	done
}

cpsl_xcframework_matches_targets() {
	info=$1
	ios_device_targets=$2
	ios_simulator_targets=$3
	macos_targets=$4
	actual=$(cpsl_xcframework_architecture_keys "$info" | LC_ALL=C sort -u) || return 1
	expected=$(cpsl_xcframework_expected_architecture_keys \
		$ios_device_targets $ios_simulator_targets $macos_targets | LC_ALL=C sort -u) || return 1

	[ "$actual" = "$expected" ]
}

cpsl_xcframework_binaries_satisfy_targets() {
	xcframework_path=$1
	ios_device_targets=$2
	ios_simulator_targets=$3
	macos_targets=$4
	info=$(cpsl_xcframework_info_plist "$xcframework_path")

	for target in $ios_device_targets $ios_simulator_targets $macos_targets; do
		category=$(cpsl_apple_category_for_rust_target "$target") || return 1
		arch=$(cpsl_apple_arch_for_rust_target "$target") || return 1
		identifier=$(cpsl_xcframework_library_identifier_for_category "$info" "$category") || return 1
		slice_dir="$xcframework_path/$identifier"
		[ -f "$slice_dir/Headers/cpsl.h" ] || return 1
		[ -f "$slice_dir/Headers/module.modulemap" ] || return 1
		cpsl_pdfium_binary_has_arch "$slice_dir/libcpsl.dylib" "$arch" || return 1
	done

	return 0
}

cpsl_pdfium_slice_for_rust_target() {
	target=$1

	case "$target" in
	aarch64-apple-ios)
		printf '%s\n' ios-arm64
		;;
	aarch64-apple-ios-sim | x86_64-apple-ios)
		printf '%s\n' ios-simulator
		;;
	aarch64-apple-darwin | x86_64-apple-darwin)
		printf '%s\n' macos
		;;
	*)
		printf '%s\n' "unsupported CPSL Apple Rust target: $target" >&2
		return 1
		;;
	esac
}

cpsl_pdfium_lipo_archs() {
	file=$1

	if [ -n "${CPSL_LIPO:-}" ]; then
		"$CPSL_LIPO" -archs "$file"
		return $?
	fi

	if command -v lipo >/dev/null 2>&1; then
		lipo -archs "$file"
		return $?
	fi

	return 127
}

cpsl_pdfium_binary_has_arch() {
	file=$1
	arch=$2

	[ -f "$file" ] || return 1

	if archs=$(cpsl_pdfium_lipo_archs "$file" 2>/dev/null); then
		status=0
	else
		status=$?
	fi
	if [ "$status" -ne 0 ]; then
		[ "$status" -eq 127 ] && return 0
		return 1
	fi

	for found_arch in $archs; do
		[ "$found_arch" = "$arch" ] && return 0
	done

	return 1
}

cpsl_pdfium_has_rust_target() {
	pdfium_root=$1
	target=$2
	slice=$(cpsl_pdfium_slice_for_rust_target "$target") || return 1
	arch=$(cpsl_apple_arch_for_rust_target "$target") || return 1
	lib="$pdfium_root/$slice/lib/libpdfium.dylib"

	cpsl_pdfium_binary_has_arch "$lib" "$arch"
}

cpsl_pdfium_satisfies_targets() {
	pdfium_root=$1
	ios_device_targets=$2
	ios_simulator_targets=$3
	macos_targets=$4

	for target in $ios_device_targets $ios_simulator_targets $macos_targets; do
		cpsl_pdfium_has_rust_target "$pdfium_root" "$target" || return 1
	done

	return 0
}

cpsl_xcframework_has_ios_device() {
	info=$1

	cpsl_xcframework_plist_tokens "$info" | awk '
		/<dict>/ {
			platform = ""
			variant = ""
		}
		/<key>SupportedPlatform<\/key>/ {
			getline
			if ($0 ~ /<string>ios<\/string>/) {
				platform = "ios"
			}
		}
		/<key>SupportedPlatformVariant<\/key>/ {
			getline
			if ($0 ~ /<string>simulator<\/string>/) {
				variant = "simulator"
			}
		}
		/<\/dict>/ {
			if (platform == "ios" && variant != "simulator") {
				found = 1
			}
		}
		END {
			exit found ? 0 : 1
		}
	'
}

cpsl_xcframework_has_ios_simulator() {
	info=$1

	cpsl_xcframework_plist_tokens "$info" | awk '
		/<dict>/ {
			platform = ""
			variant = ""
		}
		/<key>SupportedPlatform<\/key>/ {
			getline
			if ($0 ~ /<string>ios<\/string>/) {
				platform = "ios"
			}
		}
		/<key>SupportedPlatformVariant<\/key>/ {
			getline
			if ($0 ~ /<string>simulator<\/string>/) {
				variant = "simulator"
			}
		}
		/<\/dict>/ {
			if (platform == "ios" && variant == "simulator") {
				found = 1
			}
		}
		END {
			exit found ? 0 : 1
		}
	'
}

cpsl_xcframework_has_macos() {
	info=$1

	cpsl_xcframework_plist_tokens "$info" | awk '
		/<key>SupportedPlatform<\/key>/ {
			getline
			if ($0 ~ /<string>macos<\/string>/ || $0 ~ /<string>macosx<\/string>/) {
				found = 1
			}
		}
		END {
			exit found ? 0 : 1
		}
	'
}

cpsl_xcframework_is_full() {
	info=$1

	cpsl_xcframework_has_ios_device "$info" &&
		cpsl_xcframework_has_ios_simulator "$info" &&
		cpsl_xcframework_has_macos "$info"
}

cpsl_xcframework_placeholder_marker() {
	xcframework_path=$1
	printf '%s/.bootstrap-placeholder' "$xcframework_path"
}

cpsl_xcframework_is_placeholder() {
	xcframework_path=$1
	marker=$(cpsl_xcframework_placeholder_marker "$xcframework_path")
	[ -f "$marker" ]
}

cpsl_xcframework_bootstrap_placeholder() {
	xcframework_path=$1
	header_source=$2
	slice_id_ios_device=ios-arm64
	slice_id_ios_simulator=ios-arm64_x86_64-simulator
	slice_id_macos=macos-arm64_x86_64

	[ -n "$header_source" ] || return 1
	[ -f "$header_source" ] || return 1

	mkdir -p \
		"$xcframework_path/$slice_id_ios_device/Headers" \
		"$xcframework_path/$slice_id_ios_simulator/Headers" \
		"$xcframework_path/$slice_id_macos/Headers"

	cp "$header_source" "$xcframework_path/$slice_id_ios_device/Headers/cpsl.h"
	cp "$header_source" "$xcframework_path/$slice_id_ios_simulator/Headers/cpsl.h"
	cp "$header_source" "$xcframework_path/$slice_id_macos/Headers/cpsl.h"
	printf 'bootstrap placeholder\n' >"$xcframework_path/$slice_id_ios_device/libcpsl.dylib"
	printf 'bootstrap placeholder\n' >"$xcframework_path/$slice_id_ios_simulator/libcpsl.dylib"
	printf 'bootstrap placeholder\n' >"$xcframework_path/$slice_id_macos/libcpsl.dylib"

	cat >"$xcframework_path/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
<key>AvailableLibraries</key>
<array>
<dict>
<key>BinaryPath</key>
<string>libcpsl.dylib</string>
<key>HeadersPath</key>
<string>Headers</string>
<key>LibraryIdentifier</key>
<string>$slice_id_macos</string>
<key>LibraryPath</key>
<string>libcpsl.dylib</string>
<key>SupportedArchitectures</key>
<array>
<string>arm64</string>
<string>x86_64</string>
</array>
<key>SupportedPlatform</key>
<string>macos</string>
</dict>
<dict>
<key>BinaryPath</key>
<string>libcpsl.dylib</string>
<key>HeadersPath</key>
<string>Headers</string>
<key>LibraryIdentifier</key>
<string>$slice_id_ios_simulator</string>
<key>LibraryPath</key>
<string>libcpsl.dylib</string>
<key>SupportedArchitectures</key>
<array>
<string>arm64</string>
<string>x86_64</string>
</array>
<key>SupportedPlatform</key>
<string>ios</string>
<key>SupportedPlatformVariant</key>
<string>simulator</string>
</dict>
<dict>
<key>BinaryPath</key>
<string>libcpsl.dylib</string>
<key>HeadersPath</key>
<string>Headers</string>
<key>LibraryIdentifier</key>
<string>$slice_id_ios_device</string>
<key>LibraryPath</key>
<string>libcpsl.dylib</string>
<key>SupportedArchitectures</key>
<array>
<string>arm64</string>
</array>
<key>SupportedPlatform</key>
<string>ios</string>
</dict>
</array>
<key>CFBundlePackageType</key>
<string>XFWK</string>
<key>XCFrameworkFormatVersion</key>
<string>1.0</string>
</dict>
</plist>
EOF

	printf 'Herm CPSL XCFramework bootstrap placeholder. Rebuilt automatically by ensure-cpsl-apple-xcframework.sh.\n' \
		>"$(cpsl_xcframework_placeholder_marker "$xcframework_path")"
}

cpsl_xcframework_placeholder_prefix() {
	printf '%s' "scripts/cpsl-xcframework-placeholder/cpsl.xcframework"
}

cpsl_xcframework_for_each_tracked_placeholder_file() {
	herm_root=$1
	action=$2

	[ -d "$herm_root/.git" ] || return 0

	git -C "$herm_root" ls-files "$(cpsl_xcframework_placeholder_prefix)" | while IFS= read -r path; do
		[ -n "$path" ] || continue
		"$action" "$herm_root" "$path"
	done
}

cpsl_xcframework_clear_skip_worktree_entry() {
	herm_root=$1
	path=$2

	git -C "$herm_root" update-index --no-skip-worktree "$path" 2>/dev/null || true
}

cpsl_xcframework_set_skip_worktree_entry() {
	herm_root=$1
	path=$2

	git -C "$herm_root" update-index --skip-worktree "$path" 2>/dev/null || true
}

cpsl_xcframework_clear_skip_worktree() {
	herm_root=$1
	cpsl_xcframework_for_each_tracked_placeholder_file "$herm_root" cpsl_xcframework_clear_skip_worktree_entry
}

cpsl_xcframework_set_skip_worktree() {
	herm_root=$1
	cpsl_xcframework_for_each_tracked_placeholder_file "$herm_root" cpsl_xcframework_set_skip_worktree_entry
}

cpsl_xcframework_remove_stray_links() {
	placeholder_dir=$1
	link_path=$2
	entry=

	[ -d "$placeholder_dir" ] || return 0

	for entry in "$placeholder_dir"/cpsl*.xcframework; do
		[ -e "$entry" ] || [ -L "$entry" ] || continue
		[ "$entry" = "$link_path" ] && continue
		rm -rf "$entry"
	done
}

cpsl_xcframework_restore_tracked_placeholder() {
	herm_root=$1
	link_path=$2

	cpsl_xcframework_clear_skip_worktree "$herm_root"
	if git -C "$herm_root" checkout -- "$(cpsl_xcframework_placeholder_prefix)" 2>/dev/null && \
		[ -d "$link_path" ] && cpsl_xcframework_is_placeholder "$link_path"; then
		return 0
	fi
	return 1
}
