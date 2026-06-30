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
<key>BinaryPath</key><string>libcpsl.dylib</string>
<key>HeadersPath</key><string>Headers</string>
<key>LibraryIdentifier</key><string>$slice_id_macos</string>
<key>LibraryPath</key><string>libcpsl.dylib</string>
<key>SupportedArchitectures</key><array><string>arm64</string><string>x86_64</string></array>
<key>SupportedPlatform</key><string>macos</string>
</dict>
<dict>
<key>BinaryPath</key><string>libcpsl.dylib</string>
<key>HeadersPath</key><string>Headers</string>
<key>LibraryIdentifier</key><string>$slice_id_ios_simulator</string>
<key>LibraryPath</key><string>libcpsl.dylib</string>
<key>SupportedArchitectures</key><array><string>arm64</string><string>x86_64</string></array>
<key>SupportedPlatform</key><string>ios</string>
<key>SupportedPlatformVariant</key><string>simulator</string>
</dict>
<dict>
<key>BinaryPath</key><string>libcpsl.dylib</string>
<key>HeadersPath</key><string>Headers</string>
<key>LibraryIdentifier</key><string>$slice_id_ios_device</string>
<key>LibraryPath</key><string>libcpsl.dylib</string>
<key>SupportedArchitectures</key><array><string>arm64</string></array>
<key>SupportedPlatform</key><string>ios</string>
</dict>
</array>
<key>CFBundlePackageType</key><string>XFWK</string>
<key>XCFrameworkFormatVersion</key><string>1.0</string>
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

	git -C "$herm_root" ls-files -z "$(cpsl_xcframework_placeholder_prefix)" | while IFS= read -r -d '' path; do
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
		[ -e "$entry" ] || continue
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