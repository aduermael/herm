# Build Herm With CPSL

This guide builds Herm with a native CPSL local sandbox library on Linux or
macOS. Herm is the entrypoint; CPSL is built as the dynamic library passed to
`herm --cpsl`.

The helper script invokes only native build tools, Go, and Rust. It does not
invoke Python, Node, Docker, package managers, or the CPSL CLI.

## Requirements

Common requirements:

- Go 1.24 or newer
- Rust and Cargo
- Native C and C++ build tools (`cc` and `c++`)
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

From the CPSL repo root:

```sh
herm/scripts/build-cpsl-herm.sh
```

From the Herm repo:

```sh
scripts/build-cpsl-herm.sh
```

If Herm is checked out separately, point the script at the CPSL checkout:

```sh
CPSL_ROOT=/path/to/cpsl scripts/build-cpsl-herm.sh
```

The default build is the minimum Herm CPSL profile. It compiles `fs`, `json`,
`csv`, `http`, and `grep`.

To compile every CPSL core module into the library:

```sh
herm/scripts/build-cpsl-herm.sh --all
```

The `--all` profile is larger and can require extra native document/PDF
dependencies. Use the default profile unless you need a specific extra CPSL
module.

## Output

The script builds host-native artifacts under the CPSL root:

```text
target/herm-cpsl/linux-amd64/
  bin/herm
  lib/libcpsl.so
  include/cpsl.h

target/herm-cpsl/macos-arm64/
  bin/herm
  lib/libcpsl.dylib
  include/cpsl.h
```

The exact output directory depends on the host OS and CPU. Override it with
`OUT_DIR=/path/to/artifacts` if needed.

The script prints a ready-to-run command, for example:

```sh
"/absolute/path/to/target/herm-cpsl/macos-arm64/bin/herm" --cpsl "/absolute/path/to/target/herm-cpsl/macos-arm64/lib/libcpsl.dylib"
```

`--cpsl` must receive an absolute path with the platform library extension:

- Linux: `libcpsl.so`
- macOS: `libcpsl.dylib`

## Options

```sh
scripts/build-cpsl-herm.sh --minimum
scripts/build-cpsl-herm.sh --all
OUT_DIR=/tmp/herm-cpsl scripts/build-cpsl-herm.sh
RUN_PROBE=1 scripts/build-cpsl-herm.sh
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
target/herm-cpsl/linux-amd64/bin/herm \
  --cpsl "$(pwd)/target/herm-cpsl/linux-amd64/lib/libcpsl.so" \
  --allow-domain example.com
```

CPSL mode does not provide Herm's container development tools, host package
installation, host `git`, Docker/OCI images, CPython, Node, or a system compiler
inside the sandbox.
