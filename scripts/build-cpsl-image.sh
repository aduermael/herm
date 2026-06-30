#!/bin/sh
set -eu

die() {
	printf '%s\n' "error: $*" >&2
	exit 1
}

need_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		if [ -n "${2:-}" ]; then
			die "$1 is required; $2"
		fi
		die "$1 is required"
	fi
}

usage() {
	cat <<EOF
Usage:
  build-cpsl-image.sh [--minimum|--all]

Builds Herm's CPSL runtime image for the current host platform.

The image contains a Herm binary plus the CPSL dynamic library passed to
herm --cpsl. By default this script builds CPSL from Herm's external/cpsl
submodule and writes generated files under the gitignored .herm-cpsl work
directory.

Options:
  --minimum   Build the default Herm CPSL library profile. This is the default.
  --all       Build CPSL with every core module enabled.
  -h, --help  Show this help.

Environment:
  CPSL_ROOT      Existing CPSL checkout to use instead of external/cpsl.
  CPSL_WORK_DIR  Gitignored work/artifact root. Defaults to HERM_ROOT/.herm-cpsl.
  CPSL_TARGET_DIR Cargo target directory. Defaults to CPSL_WORK_DIR/cargo-target.
  OUT_DIR        Artifact directory. Defaults to CPSL_WORK_DIR/artifacts/<os>-<arch>.
  RUN_PROBE      Set to 1 to run the ignored CPSL FFI probe test after building.
EOF
}

profile=minimum
while [ "$#" -gt 0 ]; do
	case "$1" in
	--minimum)
		profile=minimum
		;;
	--all)
		profile=all
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

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
herm_root=$(CDPATH= cd "$script_dir/.." && pwd -P)
work_dir=${CPSL_WORK_DIR:-"$herm_root/.herm-cpsl"}
mkdir -p "$work_dir"
work_dir=$(CDPATH= cd "$work_dir" && pwd -P)
default_cpsl_root="$herm_root/external/cpsl"
target_dir=${CPSL_TARGET_DIR:-"$work_dir/cargo-target"}

os_raw=$(uname -s)
case "$os_raw" in
Darwin)
	os_name=macos
	lib_name=libcpsl.dylib
	pdfium_lib_name=libpdfium.dylib
	;;
Linux)
	os_name=linux
	lib_name=libcpsl.so
	pdfium_lib_name=libpdfium.so
	;;
*)
	die "unsupported OS: $os_raw; only Linux and macOS are supported"
	;;
esac

arch_raw=$(uname -m)
case "$arch_raw" in
x86_64 | amd64)
	arch_name=amd64
	;;
arm64 | aarch64)
	arch_name=arm64
	;;
*)
	die "unsupported architecture: $arch_raw; expected amd64 or arm64"
	;;
esac

need_cmd cargo "install Rust from https://rustup.rs"
need_cmd rustc "install Rust from https://rustup.rs"
need_cmd go "install Go 1.24 or newer"
need_cmd cc "install the native C build tools"
need_cmd c++ "install the native C++ build tools"

if [ -n "${CPSL_ROOT:-}" ]; then
	cpsl_root=$(CDPATH= cd "$CPSL_ROOT" && pwd -P) || die "CPSL_ROOT is not a directory: $CPSL_ROOT"
else
	if [ ! -f "$default_cpsl_root/Cargo.toml" ]; then
		need_cmd git "install Git or set CPSL_ROOT to an existing CPSL checkout"
		printf 'Initializing CPSL submodule in %s\n' "$default_cpsl_root"
		git -C "$herm_root" submodule update --init -- external/cpsl
	fi
	cpsl_root=$(CDPATH= cd "$default_cpsl_root" && pwd -P) || \
		die "missing CPSL submodule at $default_cpsl_root; run: git submodule update --init external/cpsl"
fi

sh "$herm_root/scripts/apply-cpsl-patches.sh" "$cpsl_root"

go_version=$(go env GOVERSION 2>/dev/null || true)
case "$go_version" in
go1.*)
	go_minor=${go_version#go1.}
	go_minor=${go_minor%%[!0123456789]*}
	if [ "$go_minor" -lt 24 ]; then
		die "Go 1.24 or newer is required; found $go_version"
	fi
	;;
go[2-9]*)
	;;
*)
	die "Go 1.24 or newer is required; found ${go_version:-unknown}"
	;;
esac

if [ "$os_name" = macos ]; then
	need_cmd xcode-select "run: xcode-select --install"
	xcode-select -p >/dev/null 2>&1 || die "Xcode Command Line Tools are required; run: xcode-select --install"
fi

[ -f "$cpsl_root/Cargo.toml" ] || die "missing CPSL Cargo.toml at $cpsl_root"
[ -f "$cpsl_root/ffi/Cargo.toml" ] || die "missing CPSL FFI crate at $cpsl_root/ffi"
[ -f "$cpsl_root/ffi/include/cpsl.h" ] || die "missing CPSL FFI header at $cpsl_root/ffi/include/cpsl.h"
[ -f "$herm_root/go.mod" ] || die "missing Herm go.mod at $herm_root"
[ -f "$herm_root/external/langdag/go.mod" ] || die "missing Herm submodules; run: git submodule update --init external/langdag external/cpsl"

out_dir=${OUT_DIR:-"$work_dir/artifacts/$os_name-$arch_name"}
include_dir="$out_dir/include"

mkdir -p "$out_dir" "$include_dir"
out_dir=$(CDPATH= cd "$out_dir" && pwd -P)
include_dir="$out_dir/include"
if [ -z "${OUT_DIR:-}" ] && [ -z "${CPSL_WORK_DIR:-}" ]; then
	run_dir=".herm-cpsl/artifacts/$os_name-$arch_name"
else
	run_dir="$out_dir"
fi

install_pdfium_artifact() {
	pdfium_out="$out_dir/libs/pdfium"
	pdfium_lib_dir="$pdfium_out/lib"
	mkdir -p "$pdfium_lib_dir"

	if [ -n "${PDFIUM_DYNAMIC_LIB_PATH:-}" ]; then
		if [ -d "$PDFIUM_DYNAMIC_LIB_PATH" ]; then
			pdfium_src="$PDFIUM_DYNAMIC_LIB_PATH/$pdfium_lib_name"
		else
			pdfium_src="$PDFIUM_DYNAMIC_LIB_PATH"
		fi
		[ -f "$pdfium_src" ] || die "PDFIUM_DYNAMIC_LIB_PATH does not point to $pdfium_lib_name: $PDFIUM_DYNAMIC_LIB_PATH"
		cp "$pdfium_src" "$pdfium_lib_dir/$pdfium_lib_name"
	else
		[ -f "$cpsl_root/core/scripts/download-pdfium.sh" ] || die "missing CPSL PDFium downloader at $cpsl_root/core/scripts/download-pdfium.sh"
		"$cpsl_root/core/scripts/download-pdfium.sh" --output "$pdfium_out"
	fi

	[ -f "$pdfium_lib_dir/$pdfium_lib_name" ] || die "expected PDFium library not found: $pdfium_lib_dir/$pdfium_lib_name"
}

printf 'Building CPSL FFI (%s) for %s/%s\n' "$profile" "$os_name" "$arch_name"
if [ "$profile" = all ]; then
	cargo build --manifest-path "$cpsl_root/Cargo.toml" --target-dir "$target_dir" -p cpsl-ffi --release --features all
else
	cargo build --manifest-path "$cpsl_root/Cargo.toml" --target-dir "$target_dir" -p cpsl-ffi --release
fi

cpsl_lib_src="$target_dir/release/$lib_name"
[ -f "$cpsl_lib_src" ] || die "expected CPSL library not found: $cpsl_lib_src"

cp "$cpsl_lib_src" "$out_dir/$lib_name"
cp "$cpsl_root/ffi/include/cpsl.h" "$include_dir/cpsl.h"
if [ "$profile" = all ]; then
	install_pdfium_artifact
fi

printf 'Building Herm\n'
(cd "$herm_root" && go build -o "$out_dir/herm" ./cmd/herm)
chmod +x "$out_dir/herm"

(cd "$out_dir" && ./herm --version --cpsl "$lib_name") >/dev/null
probe_request='{"id":1,"op":"eval","language":"luau","input":"print(\"ok\")","timeout_ms":10000}'
if ! probe_output=$(printf '%s\n' "$probe_request" | "$out_dir/herm" __cpsl-worker --library "$out_dir/$lib_name" --workspace "$herm_root" 2>&1); then
	die "CPSL worker probe failed:
$probe_output"
fi
case "$probe_output" in
*'"ok":true'*'"exit_code":0'*)
	;;
*)
	die "CPSL worker probe returned an unexpected response:
$probe_output"
	;;
esac

if [ "$profile" = all ]; then
	pdf_fixture="$cpsl_root/core/tests/fixtures/pdf/simple_text.pdf"
	[ -f "$pdf_fixture" ] || die "missing PDF probe fixture: $pdf_fixture"
	pdf_probe_request='{"id":2,"op":"eval","language":"luau","input":"local path = \"/workdir/core/tests/fixtures/pdf/simple_text.pdf\"\nlocal info = doc.pdfInfo(path)\nif info.pageCount ~= 1 then error(\"unexpected page count: \" .. tostring(info.pageCount)) end\nlocal text = doc.read(path, {mode=\"structural\"})\nif not string.find(text, \"Hello\") then error(\"structural doc.read did not extract fixture text\") end\nprint(\"pdf ok\")","timeout_ms":10000}'
	if ! pdf_probe_output=$(
		unset PDFIUM_DYNAMIC_LIB_PATH
		printf '%s\n' "$pdf_probe_request" | CPSL_REQUIRE_STAGED_PDFIUM=1 "$out_dir/herm" __cpsl-worker --library "$out_dir/$lib_name" --workspace "$cpsl_root" 2>&1
	); then
		die "CPSL PDF worker probe failed:
$pdf_probe_output"
	fi
	case "$pdf_probe_output" in
	*'"ok":true'*'"exit_code":0'*)
		case "$pdf_probe_output" in
		*'"stdout":"pdf ok\n"'*)
			;;
		*)
			die "CPSL PDF worker probe did not print the expected stdout:
$pdf_probe_output"
			;;
		esac
		;;
	*)
		die "CPSL PDF worker probe returned an unexpected response:
$pdf_probe_output"
		;;
	esac
fi

if [ "${RUN_PROBE:-0}" = 1 ]; then
	printf 'Running CPSL FFI probe\n'
	CPSL_FFI_LIB="$out_dir/$lib_name" cargo test --manifest-path "$cpsl_root/Cargo.toml" --target-dir "$target_dir" -p cpsl-ffi --test probe -- --ignored
fi

printf '\nBuilt Herm CPSL image (%s) for %s/%s\n' "$profile" "$os_name" "$arch_name"
printf '  image: %s\n' "$out_dir"
printf '  herm: %s\n' "$out_dir/herm"
printf '  cpsl library: %s\n' "$out_dir/$lib_name"
if [ "$profile" = all ]; then
	printf '  pdfium: %s\n' "$out_dir/libs/pdfium/lib/$pdfium_lib_name"
fi
printf '  header: %s\n' "$include_dir/cpsl.h"
printf '\nRun:\n  $ cd %s\n  $ ./herm --cpsl %s\n' "$run_dir" "$lib_name"
