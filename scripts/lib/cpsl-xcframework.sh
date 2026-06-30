# Shared CPSL XCFramework validation helpers.
# Source this file; do not execute directly.

cpsl_xcframework_info_plist() {
	xcframework_path=$1
	printf '%s/Info.plist' "$xcframework_path"
}

cpsl_xcframework_has_ios_device() {
	info=$1

	[ -f "$info" ] || return 1
	awk '
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
	' "$info"
}

cpsl_xcframework_has_ios_simulator() {
	info=$1

	[ -f "$info" ] || return 1
	awk '
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
	' "$info"
}

cpsl_xcframework_has_macos() {
	info=$1

	[ -f "$info" ] || return 1
	awk '
		/<key>SupportedPlatform<\/key>/ {
			getline
			if ($0 ~ /<string>macos<\/string>/ || $0 ~ /<string>macosx<\/string>/) {
				found = 1
			}
		}
		END {
			exit found ? 0 : 1
		}
	' "$info"
}

cpsl_xcframework_is_full() {
	info=$1

	cpsl_xcframework_has_ios_device "$info" &&
		cpsl_xcframework_has_ios_simulator "$info" &&
		cpsl_xcframework_has_macos "$info"
}

cpsl_xcframework_inputs_newer_than() {
	info_plist=$1
	herm_root=$2

	[ -f "$info_plist" ] || return 0

	for path in \
		"$herm_root/scripts/build-cpsl-apple-xcframework.sh" \
		"$herm_root/scripts/apply-cpsl-patches.sh"
	do
		[ -f "$path" ] || continue
		if [ "$path" -nt "$info_plist" ]; then
			return 0
		fi
	done

	if [ -d "$herm_root/scripts/cpsl-patches" ]; then
		if find "$herm_root/scripts/cpsl-patches" -type f -newer "$info_plist" | grep -q .; then
			return 0
		fi
	fi

	return 1
}