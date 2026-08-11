#!/bin/sh
# Run Luau create→set→write→reopen against the real cells_xlsx C ABI via CPSL.
set -eu

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
herm_root=$(CDPATH= cd "$script_dir/.." && pwd -P)

"$script_dir/build-cells-xlsx-apple.sh" --platform macosx --archs "$(uname -m)"

stage="$herm_root/.herm-cells/artifacts/apple/macosx"
libdir="$stage/lib"
[ -f "$libdir/libcells_xlsx.a" ] || {
	printf '%s\n' "error: missing $libdir/libcells_xlsx.a" >&2
	exit 1
}

export RUSTFLAGS="${RUSTFLAGS:-} -L${libdir} -lcells_xlsx -lc++"
cd "$script_dir/test-cells-xlsx-luau-eval"
cargo run --quiet
