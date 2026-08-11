#!/bin/sh
# Build cells_xlsx static library (+ header/modulemap) for Herm Apple targets.
set -eu

die() {
	printf '%s\n' "error: $*" >&2
	exit 1
}

usage() {
	cat <<EOF
Usage:
  build-cells-xlsx-apple.sh [--platform iphoneos|iphonesimulator|macosx] [--archs ARCHS]

Builds the aduermael/cells //apps/ios cells_xlsx static library for linking into
the Herm Apple app. Stages header + lib under:
  \$OUT_DIR  (default: HERM_ROOT/.herm-cells/artifacts/apple/\$platform)

Environment:
  CELLS_ROOT   Path to cells checkout (default: sibling ../cells)
  OUT_DIR      Staging directory override
  BAZEL        Bazel executable (default: bazelisk or bazel)
  CONFIGURATION  Debug|Release (affects compilation_mode)
EOF
}

platform=
archs=
while [ "$#" -gt 0 ]; do
	case "$1" in
	--platform)
		platform=${2:-}
		[ -n "$platform" ] || die "--platform requires a value"
		shift 2
		;;
	--archs)
		archs=${2:-}
		[ -n "$archs" ] || die "--archs requires a value"
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		die "unknown argument: $1"
		;;
	esac
done

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
herm_root=$(CDPATH= cd "$script_dir/.." && pwd -P)
. "$script_dir/lib/host-path.sh"
. "$script_dir/lib/cells-xlsx-apple.sh"

# Xcode run-script phases use a minimal PATH without Homebrew; ensure
# bazelisk/bazel from /opt/homebrew/bin or /usr/local/bin are visible.
herm_ensure_host_tools_path

cells_root=$(cells_xlsx_resolve_root "$herm_root")
bazel=${BAZEL:-}
if [ -z "$bazel" ]; then
	if command -v bazelisk >/dev/null 2>&1; then
		bazel=bazelisk
	elif command -v bazel >/dev/null 2>&1; then
		bazel=bazel
	else
		die "bazel or bazelisk is required to build cells_xlsx (install via: brew install bazelisk)"
	fi
fi

if [ -z "$platform" ]; then
	platform=$(cells_xlsx_platform_from_xcode "${PLATFORM_NAME:-}" "${SDK_NAME:-}")
fi
if [ -z "$archs" ]; then
	archs=$(cells_xlsx_archs_from_xcode "${ARCHS:-}" "${CURRENT_ARCH:-}")
fi

configuration=${CONFIGURATION:-Release}
case "$configuration" in
Debug | debug)
	compilation_mode=dbg
	;;
*)
	compilation_mode=opt
	;;
esac

work_dir=${CELLS_WORK_DIR:-"$herm_root/.herm-cells"}
out_dir=${OUT_DIR:-"$work_dir/artifacts/apple/$platform"}
mkdir -p "$out_dir"
out_dir=$(CDPATH= cd "$out_dir" && pwd -P)

printf 'Building cells_xlsx for platform=%s archs=%s mode=%s\n' \
	"$platform" "$archs" "$compilation_mode"
printf '  cells root: %s\n' "$cells_root"
printf '  out dir:    %s\n' "$out_dir"

cd "$cells_root"

case "$platform" in
macosx)
	cpus=
	for arch in $archs; do
		case "$arch" in
		arm64 | x86_64) ;;
		*) die "unsupported macOS arch for cells_xlsx: $arch" ;;
		esac
		if [ -z "$cpus" ]; then
			cpus=$arch
		else
			cpus="$cpus,$arch"
		fi
	done
	"$bazel" build //apps/ios:cells_xlsx_macos \
		--compilation_mode="$compilation_mode" \
		--macos_cpus="$cpus"
	src_lib=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' \
		"$cells_root/bazel-bin/apps/ios/cells_xlsx_macos_lipo.a")
	;;
iphoneos | iphonesimulator)
	cpus=
	for arch in $archs; do
		cpu=$(cells_xlsx_ios_cpu_for_arch "$platform" "$arch")
		if [ -z "$cpus" ]; then
			cpus=$cpu
		else
			cpus="$cpus,$cpu"
		fi
	done
	"$bazel" build //apps/ios:cells_xlsx_ios \
		--compilation_mode="$compilation_mode" \
		--apple_platform_type=ios \
		--ios_multi_cpus="$cpus"
	src_lib=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' \
		"$cells_root/bazel-bin/apps/ios/cells_xlsx_ios_lipo.a")
	;;
*)
	die "unsupported platform: $platform"
	;;
esac

cells_xlsx_stage_header "$cells_root" "$out_dir"
cells_xlsx_stage_static_lib "$src_lib" "$out_dir"

printf 'Staged cells_xlsx:\n'
printf '  %s\n' "$out_dir/include/cells_xlsx.h"
printf '  %s\n' "$out_dir/lib/libcells_xlsx.a"
printf '  %s\n' "$out_dir/include/module.modulemap"
