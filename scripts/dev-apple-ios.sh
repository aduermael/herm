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

usage() {
	cat <<EOF
Usage:
  scripts/dev-apple-ios.sh [options]

Builds the Herm iOS app from the terminal, installs it on a connected device,
and launches it. If exactly one eligible iOS device is connected, it is selected
automatically. If several are connected, the script prompts for one.
By default, signing uses the Xcode project's current settings.

Options:
  --build-only                 Build the app but do not install or launch it.
  --install-only               Build and install the app but do not launch it.
  --console                    Attach devicectl's console when launching.
  --device ID                  Use a specific connected device identifier.
  --device-name NAME           Use a connected device by exact display name.
  --skip-cpsl                  Do not build the CPSL XCFramework; require it to already exist.
  --rebuild-cpsl               Rebuild the CPSL XCFramework before building the app.
  --full-cpsl                  Deprecated: the ensure script always builds the full iOS+macOS framework.
  --universal-cpsl             Build both arm64 and x86_64 iOS simulator CPSL slices.
  --allow-provisioning-updates Allow xcodebuild to update automatic signing assets. Default.
  --no-provisioning-updates    Do not allow xcodebuild to update signing assets.
  --register-device            Also allow xcodebuild to register the selected device.
  --personal-team              Use the first local Apple Development signing identity.
  --team-id TEAM               Override the Xcode project's DEVELOPMENT_TEAM.
  --bundle-id ID               Override the Xcode project's PRODUCT_BUNDLE_IDENTIFIER.
  --configuration C            Build configuration. Defaults to Debug.
  --derived-data P             DerivedData path. Defaults to .herm-apple/DerivedData.
  -h, --help                   Show this help.

Examples:
  scripts/dev-apple-ios.sh
  scripts/dev-apple-ios.sh --device 00008110-001234567890801E
  scripts/dev-apple-ios.sh --personal-team
  scripts/dev-apple-ios.sh --build-only --rebuild-cpsl
EOF
}

cleanup() {
	[ -n "${tmp_dir:-}" ] || return 0
	[ -d "$tmp_dir" ] || return 0
	rm -rf "$tmp_dir"
}

make_temp() {
	if [ -z "${tmp_dir:-}" ]; then
		tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/herm-ios.XXXXXX") || die "failed to create temporary directory"
	fi
	mktemp "$tmp_dir/file.XXXXXX" || die "failed to create temporary file"
}

write_ios_devices() {
	output=$1
	show_destinations=$(make_temp)
	show_errors=$(make_temp)

	if ! xcodebuild \
		-project "$project" \
		-scheme "$scheme" \
		-configuration "$configuration" \
		-showdestinations >"$show_destinations" 2>"$show_errors"; then
		cat "$show_errors" >&2
		die "failed to list Xcode destinations"
	fi

	awk '
		/Available destinations/ {
			available = 1
			next
		}
		/Ineligible destinations/ {
			available = 0
			next
		}
		available && /^[[:space:]]*\{/ && /platform:iOS,/ && !/iOS Simulator/ && !/placeholder/ {
			line = $0
			id = line
			name = line
			sub(/^.* id:/, "", id)
			sub(/,.*$/, "", id)
			sub(/^.* name:/, "", name)
			sub(/[[:space:]]*\}.*/, "", name)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", id)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
			if (id != "" && name != "") {
				print id "\t" name
			}
		}
	' "$show_destinations" >"$output"
}

select_device_by_name() {
	devices=$1
	name=$2

	count=$(awk -F '	' -v name="$name" '$2 == name { count++ } END { print count + 0 }' "$devices")
	case "$count" in
	0)
		printf 'Connected iOS devices:\n' >&2
		awk -F '	' '{ printf "  %s (%s)\n", $2, $1 }' "$devices" >&2
		die "no connected iOS device named: $name"
		;;
	1)
		awk -F '	' -v name="$name" '$2 == name { print $1 "\t" $2; exit }' "$devices"
		;;
	*)
		die "multiple connected iOS devices are named '$name'; rerun with --device ID"
		;;
	esac
}

select_device_interactive() {
	devices=$1
	count=$2

	if [ "$count" -eq 1 ]; then
		awk -F '	' 'NR == 1 { print $1 "\t" $2 }' "$devices"
		return 0
	fi

	[ -t 0 ] || die "multiple connected iOS devices found; rerun with --device ID or --device-name NAME"

	printf '\nConnected iOS devices:\n' >&2
	awk -F '	' '{ printf "  %d) %s (%s)\n", NR, $2, $1 }' "$devices" >&2
	while :; do
		printf 'Select device [1-%s]: ' "$count" >&2
		IFS= read -r choice || die "no device selected"
		case "$choice" in
		''|*[!0-9]*)
			printf 'Enter a number from 1 to %s.\n' "$count" >&2
			;;
		*)
			if [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
				awk -F '	' -v choice="$choice" 'NR == choice { print $1 "\t" $2; exit }' "$devices"
				return 0
			fi
			printf 'Enter a number from 1 to %s.\n' "$count" >&2
			;;
		esac
	done
}

bundle_identifier() {
	info_plist=$1
	plutil -extract CFBundleIdentifier raw -o - "$info_plist" 2>/dev/null || return 1
}

detect_apple_development_team_id() {
	identities=$(make_temp)
	security find-identity -v -p codesigning >"$identities" 2>/dev/null || return 1
	awk '
		/"Apple Development:/ {
			team = $0
			sub(/^.*\(/, "", team)
			sub(/\).*$/, "", team)
			if (length(team) == 10 && team !~ /[^A-Z0-9]/) {
				print team
				exit
			}
		}
	' "$identities"
}

default_personal_bundle_id() {
	team=$1
	component=$(printf '%s' "$team" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
	[ -n "$component" ] || component=local
	printf 'dev.herm.%s\n' "$component"
}

run_xcodebuild() {
	set +e
	if [ "$allow_provisioning_updates" -eq 1 ]; then
		if [ "$register_device" -eq 1 ]; then
			xcodebuild \
				-project "$project" \
				-scheme "$scheme" \
				-configuration "$configuration" \
				-sdk iphoneos \
				-destination "$destination" \
				-derivedDataPath "$derived_data" \
				${signing_style_setting:+"$signing_style_setting"} \
				${team_setting:+"$team_setting"} \
				${bundle_id_setting:+"$bundle_id_setting"} \
				-allowProvisioningUpdates \
				-allowProvisioningDeviceRegistration \
				build
			status=$?
		else
			xcodebuild \
				-project "$project" \
				-scheme "$scheme" \
				-configuration "$configuration" \
				-sdk iphoneos \
				-destination "$destination" \
				-derivedDataPath "$derived_data" \
				${signing_style_setting:+"$signing_style_setting"} \
				${team_setting:+"$team_setting"} \
				${bundle_id_setting:+"$bundle_id_setting"} \
				-allowProvisioningUpdates \
				build
			status=$?
		fi
	else
		xcodebuild \
			-project "$project" \
			-scheme "$scheme" \
			-configuration "$configuration" \
			-sdk iphoneos \
			-destination "$destination" \
			-derivedDataPath "$derived_data" \
			${signing_style_setting:+"$signing_style_setting"} \
			${team_setting:+"$team_setting"} \
			${bundle_id_setting:+"$bundle_id_setting"} \
			build
		status=$?
	fi
	set -e
	return "$status"
}

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
root=$(CDPATH= cd "$script_dir/.." && pwd -P)
tmp_dir=
trap cleanup EXIT HUP INT TERM

mode=run
cpsl_mode=auto
cpsl_ios_simulator_targets=${IOS_SIMULATOR_TARGETS:-}
cpsl_macos_targets=${MACOS_TARGETS:-}
configuration=Debug
derived_data="$root/.herm-apple/DerivedData"
device_id=${IOS_DEVICE_ID:-}
device_name=${IOS_DEVICE_NAME:-}
allow_provisioning_updates=1
register_device=0
attach_console=0
team_id=${IOS_TEAM_ID:-}
explicit_team_id=0
personal_team=0
bundle_id_override=${IOS_BUNDLE_ID:-}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--build-only)
		mode=build
		;;
	--install-only)
		mode=install
		;;
	--console)
		attach_console=1
		;;
	--device)
		shift
		[ "$#" -gt 0 ] || die "--device requires a value"
		device_id=$1
		;;
	--device-name)
		shift
		[ "$#" -gt 0 ] || die "--device-name requires a value"
		device_name=$1
		;;
	--skip-cpsl)
		cpsl_mode=skip
		;;
	--rebuild-cpsl)
		cpsl_mode=rebuild
		;;
	--full-cpsl)
		;;
	--universal-cpsl)
		cpsl_ios_simulator_targets="aarch64-apple-ios-sim x86_64-apple-ios"
		;;
	--allow-provisioning-updates)
		allow_provisioning_updates=1
		;;
	--no-provisioning-updates)
		allow_provisioning_updates=0
		register_device=0
		;;
	--register-device)
		allow_provisioning_updates=1
		register_device=1
		;;
	--personal-team)
		personal_team=1
		allow_provisioning_updates=1
		register_device=1
		;;
	--team-id)
		shift
		[ "$#" -gt 0 ] || die "--team-id requires a value"
		team_id=$1
		explicit_team_id=1
		;;
	--bundle-id)
		shift
		[ "$#" -gt 0 ] || die "--bundle-id requires a value"
		bundle_id_override=$1
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

[ -z "$device_id" ] || [ -z "$device_name" ] || die "--device and --device-name are mutually exclusive"
[ "$personal_team" -eq 0 ] || [ "$explicit_team_id" -eq 0 ] || die "--personal-team and --team-id are mutually exclusive"

[ "$(uname -s)" = Darwin ] || die "run this from a macOS terminal, not Linux or a container"

need_cmd xcode-select "install full Xcode, then select and initialize it with xcode-select/xcodebuild"
need_cmd xcodebuild "install full Xcode"
need_cmd xcrun "install full Xcode"
need_cmd plutil "install full Xcode or Command Line Tools"
if [ "$personal_team" -eq 1 ]; then
	need_cmd security "macOS Keychain access is required to detect your Apple Development identity"
fi

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

if [ "$mode" != build ]; then
	xcrun --find devicectl >/dev/null 2>&1 || die "devicectl is required; install Xcode 15 or newer"
fi

project="$root/app/apple/herm.xcodeproj"
target=herm
scheme=herm
app_path="$derived_data/Build/Products/$configuration-iphoneos/$target.app"
xcframework_path="$root/.herm-cpsl/artifacts/apple/cpsl.xcframework"
host_arch=$(uname -m)
signing_style_setting=
team_setting=
bundle_id_setting=

[ -d "$project" ] || die "missing Xcode project: $project"

if [ "$personal_team" -eq 1 ]; then
	detected_team_id=$(detect_apple_development_team_id || printf '')
	[ -n "$detected_team_id" ] || die "could not find an Apple Development signing identity; in Xcode, open Settings > Accounts > Manage Certificates and create an Apple Development certificate"
	team_id=$detected_team_id
	if [ -z "$bundle_id_override" ]; then
		bundle_id_override=$(default_personal_bundle_id "$team_id")
	fi
	printf 'Using Personal Team: %s\n' "$team_id"
	printf 'Using personal bundle ID: %s\n' "$bundle_id_override"
fi

if [ -n "$team_id" ]; then
	signing_style_setting=CODE_SIGN_STYLE=Automatic
	team_setting="DEVELOPMENT_TEAM=$team_id"
fi
if [ -n "$bundle_id_override" ]; then
	signing_style_setting=CODE_SIGN_STYLE=Automatic
	bundle_id_setting="PRODUCT_BUNDLE_IDENTIFIER=$bundle_id_override"
fi

if [ -z "$cpsl_ios_simulator_targets" ]; then
	case "$host_arch" in
	arm64 | aarch64)
		cpsl_ios_simulator_targets=aarch64-apple-ios-sim
		;;
	x86_64)
		cpsl_ios_simulator_targets=x86_64-apple-ios
		;;
	*)
		die "unsupported host architecture for iOS simulator CPSL build: $host_arch"
		;;
	esac
fi

if [ -z "$cpsl_macos_targets" ]; then
	case "$host_arch" in
	arm64 | aarch64)
		cpsl_macos_targets=aarch64-apple-darwin
		;;
	x86_64)
		cpsl_macos_targets=x86_64-apple-darwin
		;;
	*)
		cpsl_macos_targets=
		;;
	esac
fi

selected_device=
if [ "$mode" = build ] && [ -z "$device_id" ] && [ -z "$device_name" ]; then
	destination="generic/platform=iOS"
else
	if [ -z "$device_id" ]; then
		device_file=$(make_temp)
		write_ios_devices "$device_file"
		device_count=$(wc -l <"$device_file" | tr -d '[:space:]')
		[ "$device_count" -gt 0 ] || die "no eligible connected iOS devices found; connect and unlock a trusted device, or run with --build-only"

		if [ -n "$device_name" ]; then
			selected_device=$(select_device_by_name "$device_file" "$device_name")
		else
			selected_device=$(select_device_interactive "$device_file" "$device_count")
		fi
		device_id=${selected_device%%	*}
		device_name=${selected_device#*	}
	fi
	destination="platform=iOS,id=$device_id"
	if [ -n "$device_name" ]; then
		printf 'Using iOS device: %s (%s)\n' "$device_name" "$device_id"
	else
		printf 'Using iOS device: %s\n' "$device_id"
	fi
fi

if [ "$cpsl_mode" = rebuild ]; then
	HERM_CPSL_REBUILD=1
	export HERM_CPSL_REBUILD
fi
if [ -n "$cpsl_ios_simulator_targets" ]; then
	export IOS_SIMULATOR_TARGETS="$cpsl_ios_simulator_targets"
fi
if [ -n "$cpsl_macos_targets" ]; then
	export MACOS_TARGETS="$cpsl_macos_targets"
fi
if [ "$cpsl_mode" = skip ]; then
	"$root/scripts/link-cpsl-xcframework-for-xcode.sh" --skip
else
	"$root/scripts/link-cpsl-xcframework-for-xcode.sh"
fi

clean_xattrs "$root/app/apple/herm" "$xcframework_path" "$app_path"

printf 'Building %s (%s) for iOS\n' "$target" "$configuration"
if ! run_xcodebuild; then
	cat >&2 <<EOF

iOS signing failed. For a physical device build, Xcode needs a local Apple
account and an iOS App Development provisioning profile for the bundle ID.

Try:
  1. Open Xcode > Settings > Accounts and add your Apple ID.
  2. For a Personal Team, rerun with:
       scripts/dev-apple-ios.sh --personal-team
  3. Rerun with --team-id YOURTEAMID if your account is not the project default.
  4. If your team cannot provision com.herm.herm, rerun with a unique bundle ID:
       scripts/dev-apple-ios.sh --team-id YOURTEAMID --bundle-id com.yourname.herm --register-device
  5. If Xcode only shows an old organization and no Personal Team, sign into
     Xcode with a separate personal Apple Account or ask Apple Developer Support
     to remove/fix the old team association.

EOF
	exit 1
fi

[ -d "$app_path" ] || die "expected app was not built: $app_path"

case "$mode" in
build)
	printf '\nBuilt app: %s\n' "$app_path"
	;;
install)
	printf '\nInstalling app on device: %s\n' "$device_id"
	xcrun devicectl device install app --device "$device_id" "$app_path"
	printf '\nInstalled app: %s\n' "$app_path"
	;;
run)
	app_info="$app_path/Info.plist"
	[ -f "$app_info" ] || die "expected app Info.plist was not built: $app_info"
	bundle_id=$(bundle_identifier "$app_info") || die "failed to read CFBundleIdentifier from $app_info"
	[ -n "$bundle_id" ] || die "empty CFBundleIdentifier in $app_info"

	printf '\nInstalling app on device: %s\n' "$device_id"
	xcrun devicectl device install app --device "$device_id" "$app_path"

	printf '\nLaunching %s on device: %s\n' "$bundle_id" "$device_id"
	if [ "$attach_console" -eq 1 ]; then
		exec xcrun devicectl device process launch --console --device "$device_id" "$bundle_id"
	else
		exec xcrun devicectl device process launch --device "$device_id" "$bundle_id"
	fi
	;;
*)
	die "internal error: unknown mode $mode"
	;;
esac
