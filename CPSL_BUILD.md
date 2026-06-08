# Build Herm With CPSL

This guide builds Herm with a native CPSL local sandbox library on Linux or
macOS. Herm is the entrypoint; CPSL is built as the dynamic library passed to
`herm --cpsl`.

The helper script invokes only native build tools, Go, and Rust. It does not
invoke Python, Node, Docker, package managers, or the CPSL CLI.

Herm owns this build flow. CPSL is fetched as a build dependency into
`.herm-cpsl/`, which is ignored by git so dependency checkouts and generated
artifacts do not get committed by accident.

## Requirements

Common requirements:

- Go 1.24 or newer
- Rust and Cargo
- Native C and C++ build tools (`cc` and `c++`)
- Git, unless `CPSL_ROOT` points at an existing CPSL checkout
- Herm submodules initialized with `git submodule update --init --recursive`

macOS needs Xcode Command Line Tools:

```sh
xcode-select --install
```

Linux needs the distro's native compiler toolchain. On Debian or Ubuntu this is
typically `build-essential`; on Fedora it is the C/C++ development tools group.

Docker is only needed for Herm's default container backend. It is not needed
when Herm is started with `--cpsl`.

## Build

From the Herm repo:

```sh
scripts/build-cpsl-image.sh
```

By default the script fetches CPSL from:

```text
https://github.com/fundamental-research-labs/cpsl.git
```

Until the CPSL PR for this integration lands, it uses the pre-merge
`aduermael/lib-build` branch. Override the source after the PR is merged, or
when testing a local CPSL checkout:

```sh
CPSL_REF=main scripts/build-cpsl-image.sh
CPSL_ROOT=/path/to/cpsl scripts/build-cpsl-image.sh
```

The default build is the minimum Herm CPSL profile. It compiles `fs`, `json`,
`csv`, `http`, and `grep`.

To compile every CPSL core module into the library:

```sh
scripts/build-cpsl-image.sh --all
```

The `--all` profile is larger and can require extra native document/PDF
dependencies. Use the default profile unless you need a specific extra CPSL
module.

## Output

The script builds CPSL's Cargo target directory and host-native output artifacts
under Herm's ignored `.herm-cpsl` directory:

```text
.herm-cpsl/cargo-target/

.herm-cpsl/artifacts/linux-amd64/
  bin/herm
  lib/libcpsl.so
  include/cpsl.h

.herm-cpsl/artifacts/macos-arm64/
  bin/herm
  lib/libcpsl.dylib
  include/cpsl.h
```

The exact output directory depends on the host OS and CPU. Override it with
`OUT_DIR=/path/to/artifacts` if needed.

The script prints a ready-to-run command, for example:

```sh
"/absolute/path/to/.herm-cpsl/artifacts/macos-arm64/bin/herm" --cpsl "/absolute/path/to/.herm-cpsl/artifacts/macos-arm64/lib/libcpsl.dylib"
```

`--cpsl` must receive an absolute path with the platform library extension:

- Linux: `libcpsl.so`
- macOS: `libcpsl.dylib`

## Options

```sh
scripts/build-cpsl-image.sh --minimum
scripts/build-cpsl-image.sh --all
OUT_DIR=/tmp/herm-cpsl scripts/build-cpsl-image.sh
RUN_PROBE=1 scripts/build-cpsl-image.sh
CPSL_REPO=https://github.com/fundamental-research-labs/cpsl.git scripts/build-cpsl-image.sh
CPSL_REF=aduermael/lib-build scripts/build-cpsl-image.sh
CPSL_ROOT=/path/to/cpsl scripts/build-cpsl-image.sh
CPSL_TARGET_DIR=/tmp/cpsl-target scripts/build-cpsl-image.sh
```

`RUN_PROBE=1` runs the ignored CPSL FFI probe test after building. The normal
script run already checks that Herm accepts the generated CPSL library path.

## macOS From Linux

The helper script intentionally builds only for the current host. A normal Linux
machine can cross-build the Go Herm binary, but it cannot build the macOS CPSL
dynamic library without an Apple SDK and macOS-compatible C/C++ toolchain. For
the full Herm + CPSL macOS build, run the script on macOS.

The default CPSL tools are the same on Linux and macOS: `fs`, `json`, `csv`,
`http`, and `grep`. Building on macOS does not unlock additional default tools.
Use `--all` on either platform when you want every CPSL core module and have the
required native dependencies installed.

## Runtime Notes

CPSL mode is an alternative backend, not a container. Herm mounts the current
working directory into CPSL as `/workdir`, starts an internal CPSL worker, and
routes sandbox shell operations through the loaded library.

Network access is policy-gated. Use repeatable `--allow-domain` and
`--deny-domain` flags when running Herm; deny rules take precedence over allow
rules.

```sh
.herm-cpsl/artifacts/linux-amd64/bin/herm \
  --cpsl "$(pwd)/.herm-cpsl/artifacts/linux-amd64/lib/libcpsl.so" \
  --allow-domain example.com
```

CPSL mode does not provide Herm's container development tools, host package
installation, host `git`, Docker/OCI images, CPython, Node, or a system compiler
inside the sandbox.
