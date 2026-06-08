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
herm --cpsl. By default this script fetches CPSL into a gitignored Herm-local
work directory, so the Herm repo remains the parent checkout.

Options:
  --minimum   Build the default Herm CPSL library profile. This is the default.
  --all       Build CPSL with every core module enabled.
  -h, --help  Show this help.

Environment:
  CPSL_REPO      CPSL git URL. Defaults to the public CPSL repository.
  CPSL_REF       CPSL git ref to fetch. Defaults to the pre-merge integration branch.
  CPSL_ROOT      Existing CPSL checkout to use instead of fetching.
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
cpsl_repo=${CPSL_REPO:-"https://github.com/fundamental-research-labs/cpsl.git"}
cpsl_ref=${CPSL_REF:-"aduermael/lib-build"}
managed_cpsl_root="$work_dir/cpsl"
target_dir=${CPSL_TARGET_DIR:-"$work_dir/cargo-target"}

os_raw=$(uname -s)
case "$os_raw" in
Darwin)
	os_name=macos
	lib_name=libcpsl.dylib
	;;
Linux)
	os_name=linux
	lib_name=libcpsl.so
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
	need_cmd git "install Git or set CPSL_ROOT to an existing CPSL checkout"
	if [ -e "$managed_cpsl_root" ] && [ ! -d "$managed_cpsl_root/.git" ]; then
		die "$managed_cpsl_root exists but is not a Git checkout"
	fi
	if [ ! -d "$managed_cpsl_root/.git" ]; then
		printf 'Initializing CPSL checkout in %s\n' "$managed_cpsl_root"
		git -c init.defaultBranch=main init "$managed_cpsl_root" >/dev/null
		git -C "$managed_cpsl_root" remote add origin "$cpsl_repo"
	else
		git -C "$managed_cpsl_root" remote set-url origin "$cpsl_repo"
	fi
	printf 'Fetching CPSL %s from %s\n' "$cpsl_ref" "$cpsl_repo"
	git -C "$managed_cpsl_root" fetch --depth 1 origin "$cpsl_ref"
	git -C "$managed_cpsl_root" checkout --detach FETCH_HEAD
	cpsl_root=$(CDPATH= cd "$managed_cpsl_root" && pwd -P)
fi

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
[ -f "$herm_root/external/langdag/go.mod" ] || die "missing Herm submodules; run: git submodule update --init --recursive"

out_dir=${OUT_DIR:-"$work_dir/artifacts/$os_name-$arch_name"}
bin_dir="$out_dir/bin"
lib_dir="$out_dir/lib"
include_dir="$out_dir/include"

mkdir -p "$bin_dir" "$lib_dir" "$include_dir"
out_dir=$(CDPATH= cd "$out_dir" && pwd -P)
bin_dir="$out_dir/bin"
lib_dir="$out_dir/lib"
include_dir="$out_dir/include"

printf 'Building CPSL FFI (%s) for %s/%s\n' "$profile" "$os_name" "$arch_name"
if [ "$profile" = all ]; then
	cargo build --manifest-path "$cpsl_root/Cargo.toml" --target-dir "$target_dir" -p cpsl-ffi --release --features all
else
	cargo build --manifest-path "$cpsl_root/Cargo.toml" --target-dir "$target_dir" -p cpsl-ffi --release
fi

cpsl_lib_src="$target_dir/release/$lib_name"
[ -f "$cpsl_lib_src" ] || die "expected CPSL library not found: $cpsl_lib_src"

cp "$cpsl_lib_src" "$lib_dir/$lib_name"
cp "$cpsl_root/ffi/include/cpsl.h" "$include_dir/cpsl.h"

printf 'Building Herm\n'
(cd "$herm_root" && go build -o "$bin_dir/herm" ./cmd/herm)
chmod +x "$bin_dir/herm"

"$bin_dir/herm" --version --cpsl "$lib_dir/$lib_name" >/dev/null

if [ "${RUN_PROBE:-0}" = 1 ]; then
	printf 'Running CPSL FFI probe\n'
	CPSL_FFI_LIB="$lib_dir/$lib_name" cargo test --manifest-path "$cpsl_root/Cargo.toml" --target-dir "$target_dir" -p cpsl-ffi --test probe -- --ignored
fi

printf '\nBuilt Herm CPSL image (%s) for %s/%s\n' "$profile" "$os_name" "$arch_name"
printf '  herm: %s\n' "$bin_dir/herm"
printf '  cpsl library: %s\n' "$lib_dir/$lib_name"
printf '  header: %s\n' "$include_dir/cpsl.h"
printf '\nRun:\n  "%s" --cpsl "%s"\n' "$bin_dir/herm" "$lib_dir/$lib_name"
