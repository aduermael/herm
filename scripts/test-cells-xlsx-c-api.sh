#!/bin/sh
# Host smoke test: link real cells_xlsx and exercise create→set→write→reopen→read.
set -eu

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
herm_root=$(CDPATH= cd "$script_dir/.." && pwd -P)
. "$script_dir/lib/cells-xlsx-apple.sh"

scratch=${1:-}
if [ -z "$scratch" ]; then
	scratch=${HERM_CELLS_XLSX_SCRATCH:-"$herm_root/.herm-cells/smoke"}
fi
mkdir -p "$scratch"
scratch=$(CDPATH= cd "$scratch" && pwd -P)

"$script_dir/build-cells-xlsx-apple.sh" --platform macosx --archs "$(uname -m)"

stage="$herm_root/.herm-cells/artifacts/apple/macosx"
include="$stage/include"
libdir="$stage/lib"
[ -f "$include/cells_xlsx.h" ] || cells_xlsx_die "missing staged header"
[ -f "$libdir/libcells_xlsx.a" ] || cells_xlsx_die "missing staged static lib"

src="$scratch/cells_xlsx_smoke.c"
bin="$scratch/cells_xlsx_smoke"
out_xlsx="$scratch/roundtrip.xlsx"

cat >"$src" <<'EOF'
#include "cells_xlsx.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    const char *out_path = argc > 1 ? argv[1] : "/tmp/cells_xlsx_roundtrip.xlsx";
    CellsXlsxWorkbook *wb = cells_xlsx_create();
    if (!wb) {
        fprintf(stderr, "create failed: %s\n", cells_xlsx_last_error());
        return 1;
    }
    if (cells_xlsx_set_string(wb, 0, 0, 0, "hello") != 0) {
        fprintf(stderr, "set_string failed: %s\n", cells_xlsx_last_error());
        return 1;
    }
    if (cells_xlsx_set_number(wb, 0, 1, 0, 42.5) != 0) {
        fprintf(stderr, "set_number failed: %s\n", cells_xlsx_last_error());
        return 1;
    }
    if (cells_xlsx_write(wb, out_path) != 0) {
        fprintf(stderr, "write failed: %s\n", cells_xlsx_last_error());
        return 1;
    }
    cells_xlsx_close(wb);

    wb = cells_xlsx_open(out_path);
    if (!wb) {
        fprintf(stderr, "open failed: %s\n", cells_xlsx_last_error());
        return 1;
    }
    const char *s = cells_xlsx_get_string(wb, 0, 0, 0);
    double n = cells_xlsx_get_number(wb, 0, 1, 0);
    if (!s || strcmp(s, "hello") != 0) {
        fprintf(stderr, "string mismatch: %s\n", s ? s : "(null)");
        return 1;
    }
    if (n != 42.5) {
        fprintf(stderr, "number mismatch: %g\n", n);
        return 1;
    }
    printf("PASS create/set/write/reopen A1=%s B1=%g\n", s, n);
    cells_xlsx_close(wb);

    /* invalid open */
    CellsXlsxWorkbook *missing = cells_xlsx_open("/no/such/path/does_not_exist.xlsx");
    if (missing != NULL) {
        fprintf(stderr, "expected open failure for missing file\n");
        return 1;
    }
    const char *err = cells_xlsx_last_error();
    if (!err || err[0] == '\0') {
        fprintf(stderr, "expected non-empty last_error after failed open\n");
        return 1;
    }
    printf("PASS invalid open error: %s\n", err);
    return 0;
}
EOF

clang -std=c11 \
	-I"$include" \
	"$src" \
	"$libdir/libcells_xlsx.a" \
	-lc++ \
	-o "$bin"

"$bin" "$out_xlsx"
printf 'cells_xlsx C smoke OK (%s)\n' "$out_xlsx"
