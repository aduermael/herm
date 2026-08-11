# Shared helpers for building/linking cells_xlsx into the Herm Apple app.
# Source this file; do not execute directly.

cells_xlsx_die() {
	printf '%s\n' "error: $*" >&2
	exit 1
}

cells_xlsx_resolve_root() {
	herm_root=$1
	explicit=${CELLS_ROOT:-}

	if [ -n "$explicit" ]; then
		[ -d "$explicit" ] || cells_xlsx_die "CELLS_ROOT is not a directory: $explicit"
		[ -f "$explicit/apps/ios/cells_xlsx.h" ] || \
			cells_xlsx_die "CELLS_ROOT missing apps/ios/cells_xlsx.h: $explicit"
		CDPATH= cd "$explicit" && pwd -P
		return 0
	fi

	sibling=$(CDPATH= cd "$herm_root/../cells" 2>/dev/null && pwd -P) || sibling=
	if [ -n "$sibling" ] && [ -f "$sibling/apps/ios/cells_xlsx.h" ]; then
		printf '%s\n' "$sibling"
		return 0
	fi

	cells_xlsx_die "cells checkout not found; set CELLS_ROOT or clone aduermael/cells next to herm"
}

cells_xlsx_platform_from_xcode() {
	platform_name=${1:-}
	sdk_name=${2:-}

	case "$platform_name" in
	iphoneos | iphonesimulator | macosx)
		printf '%s\n' "$platform_name"
		return 0
		;;
	"")
		;;
	*)
		cells_xlsx_die "unsupported Apple platform for cells_xlsx: $platform_name"
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
	*)
		cells_xlsx_die "unsupported Apple SDK for cells_xlsx: ${sdk_name:-unknown}"
		;;
	esac
}

cells_xlsx_archs_from_xcode() {
	archs=${1:-}
	current_arch=${2:-}

	if [ -n "$archs" ]; then
		printf '%s\n' "$archs"
		return 0
	fi
	if [ -n "$current_arch" ]; then
		printf '%s\n' "$current_arch"
		return 0
	fi
	uname -m
}

cells_xlsx_ios_cpu_for_arch() {
	platform=$1
	arch=$2

	case "$platform/$arch" in
	iphoneos/arm64)
		printf '%s\n' arm64
		;;
	iphonesimulator/arm64)
		printf '%s\n' sim_arm64
		;;
	iphonesimulator/x86_64)
		printf '%s\n' sim_x86_64
		;;
	*)
		cells_xlsx_die "unsupported iOS cells_xlsx arch: platform=$platform arch=$arch"
		;;
	esac
}

cells_xlsx_stage_header() {
	cells_root=$1
	stage_dir=$2

	mkdir -p "$stage_dir/include"
	cp "$cells_root/apps/ios/cells_xlsx.h" "$stage_dir/include/cells_xlsx.h"
	cat >"$stage_dir/include/module.modulemap" <<'EOF'
module CellsXlsx {
    header "cells_xlsx.h"
    export *
}
EOF
}

cells_xlsx_stage_static_lib() {
	src_lib=$1
	stage_dir=$2

	[ -f "$src_lib" ] || cells_xlsx_die "cells_xlsx static library missing: $src_lib"
	mkdir -p "$stage_dir/lib"
	# Resolve symlinks from Bazel into a real file Xcode can cache.
	# Bazel outputs are often mode 0555; replace atomically so re-stage works.
	dst="$stage_dir/lib/libcells_xlsx.a"
	tmp="$dst.tmp.$$"
	cp -L "$src_lib" "$tmp"
	chmod u+w "$tmp" 2>/dev/null || true
	mv -f "$tmp" "$dst"
	chmod u+w "$dst" 2>/dev/null || true
}
