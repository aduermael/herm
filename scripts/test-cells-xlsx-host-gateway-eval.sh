#!/bin/sh
# Product-path: rebuilt libcpsl.dylib host_callbacks_v4 + real cells_xlsx Luau eval.
set -eu

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
herm_root=$(CDPATH= cd "$script_dir/.." && pwd -P)
scratch=${1:-}
if [ -z "$scratch" ]; then
	scratch=${HERM_CELLS_XLSX_SCRATCH:-"$herm_root/.herm-cells/host-gateway-eval"}
fi
mkdir -p "$scratch"
scratch=$(CDPATH= cd "$scratch" && pwd -P)

"$script_dir/build-cells-xlsx-apple.sh" --platform macosx --archs "$(uname -m)"

stage="$herm_root/.herm-cells/artifacts/apple/macosx"
include="$stage/include"
libdir="$stage/lib"

# Prefer freshly rebuilt Debug XCFramework macos slice (bazel apple-app + xlsx).
dylib=""
for candidate in \
	"$herm_root/.herm-cpsl/artifacts/apple/Debug/cpsl.xcframework/macos-arm64_x86_64/libcpsl.dylib" \
	"$herm_root/.herm-cpsl/artifacts/apple/Debug/slices/macos/libcpsl.dylib" \
	"$herm_root/.herm-cpsl/artifacts/apple/Debug/slices/aarch64-apple-darwin/libcpsl.dylib"
do
	if [ -f "$candidate" ] && nm "$candidate" 2>/dev/null | grep -q 'cpsl_session_new_with_host_callbacks_v4'; then
		dylib=$candidate
		break
	fi
done

if [ -z "$dylib" ]; then
	printf '%s\n' "error: no rebuilt libcpsl.dylib with host_callbacks_v4 found under .herm-cpsl" >&2
	exit 1
fi

printf 'Using CPSL dylib: %s\n' "$dylib"
nm "$dylib" | grep 'cpsl_session_new_with_host_callbacks_v4' || true

workdir="$scratch/workdir"
mkdir -p "$workdir"
bin="$scratch/host_gateway_eval"
src="$script_dir/test-cells-xlsx-host-gateway-eval.c"

clang -std=c11 \
	-I"$include" \
	"$src" \
	"$libdir/libcells_xlsx.a" \
	-lc++ \
	-o "$bin"

"$bin" "$dylib" "$workdir"
printf 'host-gateway product path OK\n'
