# Build Herm With CPSL

This guide builds Herm with a native CPSL local sandbox library on Linux or
macOS. Herm is the entrypoint; CPSL is built as the dynamic library passed to
`herm --cpsl`.

The helper script invokes native build tools, Go, Rust, Git unless `CPSL_ROOT`
is set, and optional PDFium download tooling for `--all`. It does not invoke
Python, Node, Docker, package managers, or the CPSL CLI.

Herm owns this build flow. CPSL source is tracked as the `external/cpsl`
submodule. Generated build artifacts and Cargo output still live under
`.herm-cpsl/`, which is ignored by git so generated files do not get committed
by accident.

## Requirements

Common requirements:

- Go 1.24 or newer
- Rust and Cargo
- Native C and C++ build tools (`cc` and `c++`)
- Git, unless `CPSL_ROOT` points at an existing CPSL checkout
- Herm submodules initialized with
  `git submodule update --init external/langdag external/cpsl`

macOS needs Xcode Command Line Tools:

```sh
xcode-select --install
```

Linux needs the distro's native compiler toolchain. On Debian or Ubuntu this is
typically `build-essential`; on Fedora it is the C/C++ development tools group.
The `--all` profile may also need native GUI/document development packages
before the PDFium probe is reached: `pkg-config` plus GTK/GDK, ATK, Pango,
WebKitGTK, and libsoup-style dev packages are common requirements.

Docker is only needed for Herm's default container backend. It is not needed
when Herm is started with `--cpsl`.

## Build

From the Herm repo:

```sh
scripts/build-cpsl-image.sh
```

By default the script builds CPSL from Herm's submodule:

```text
external/cpsl
```

The current submodule points at CPSL commit
`4376c3bc49045177f8096688f9e350423a79b9b4`, which includes the HTTP policy and
composed mount integration used by Herm. Override the source when testing a
local CPSL checkout:

```sh
CPSL_ROOT=/path/to/cpsl scripts/build-cpsl-image.sh
```

Before compiling CPSL, Herm applies tracked integration patches from
`scripts/cpsl-patches/` to the selected checkout. These patches keep the pinned
CPSL dependency aligned with Herm's app/runtime integration. When a patch is
already present in the submodule commit, the patch helper skips it.

The default build is the minimum Herm CPSL profile. It compiles `fs`, `json`,
`csv`, `http`, and `grep`.

To compile every CPSL core module into the library:

```sh
scripts/build-cpsl-image.sh --all
```

The `--all` profile is larger and can require extra native document/PDF
dependencies. On Linux, install the relevant `pkg-config`, GTK/GDK, ATK, Pango,
WebKitGTK, and libsoup development packages for your distro before retrying a
native dependency failure. For PDF support, the script stages PDFium under the
artifact directory at `libs/pdfium/lib/<platform library>`. If
`PDFIUM_DYNAMIC_LIB_PATH` is set, that library is copied into the artifact;
otherwise the script reuses CPSL's `core/scripts/download-pdfium.sh` helper.
That helper may require `curl` and network access.
Use the default profile unless you need a specific extra CPSL module.

## Output

The script builds CPSL's Cargo target directory and host-native output artifacts
under Herm's ignored `.herm-cpsl` directory:

```text
.herm-cpsl/cargo-target/

.herm-cpsl/artifacts/linux-amd64/
  herm
  libcpsl.so
  include/cpsl.h
  libs/pdfium/lib/libpdfium.so   # --all only

.herm-cpsl/artifacts/macos-arm64/
  herm
  libcpsl.dylib
  include/cpsl.h
  libs/pdfium/lib/libpdfium.dylib # --all only
```

The exact output directory depends on the host OS and CPU. Override it with
`OUT_DIR=/path/to/artifacts` if needed.

The script prints a ready-to-run command, for example:

```sh
cd .herm-cpsl/artifacts/macos-arm64
./herm --cpsl libcpsl.dylib
```

`--cpsl` accepts a relative or absolute path with the platform library
extension:

- Linux: `libcpsl.so`
- macOS: `libcpsl.dylib`

## Apple XCFramework

To build CPSL for Apple app targets, run the Apple helper from macOS with Xcode
installed:

```sh
scripts/build-cpsl-apple-xcframework.sh
```

This follows the same source dependency model as the host-native helper: Herm
builds from `external/cpsl` unless `CPSL_ROOT` points at an existing checkout.

The script builds CPSL's FFI crate for iOS device, iOS simulator, and macOS
targets, then packages the dynamic libraries plus `cpsl.h` into one
multi-platform XCFramework:

```text
.herm-cpsl/artifacts/apple/
  cpsl.xcframework
  include/cpsl.h
```

Install Rust with [rustup](https://rustup.rs/), then add the Apple targets before
building:

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios aarch64-apple-darwin x86_64-apple-darwin
```

Xcode run scripts do not use your login-shell `PATH`. The CPSL build scripts
source `~/.cargo/env` and prepend `~/.cargo/bin` automatically. If Xcode still
cannot find `cargo`, restart Xcode after installing Rust.

Override the source or output path the same way as the host-native helper:

```sh
CPSL_ROOT=/path/to/cpsl scripts/build-cpsl-apple-xcframework.sh
OUT_DIR=/tmp/cpsl-apple scripts/build-cpsl-apple-xcframework.sh
APPLE_PLATFORMS=ios scripts/build-cpsl-apple-xcframework.sh
APPLE_PLATFORMS=macos scripts/build-cpsl-apple-xcframework.sh
```

The Apple helper currently builds the minimum Herm CPSL profile. The `--all`
profile is intentionally not enabled until the Apple PDFium/runtime artifact
path is defined.

For an iOS-only output under `.herm-cpsl/artifacts/ios/`, use the Apple helper
with the iOS platform selected:

```sh
APPLE_PLATFORMS=ios OUT_DIR=.herm-cpsl/artifacts/ios scripts/build-cpsl-apple-xcframework.sh
```

## Xcode auto-build

Opening `app/apple/herm.xcodeproj` in Xcode and building the `herm` target
automatically ensures the CPSL XCFramework exists before Swift compilation.

The `herm` target depends on a **Build CPSL XCFramework** aggregate target that
runs before compilation. On every build it runs:

```sh
"${SRCROOT}/../../scripts/link-cpsl-xcframework-for-xcode.sh"
```

That helper calls `ensure-cpsl-apple-xcframework.sh` to build or reuse
`.herm-cpsl/artifacts/apple/cpsl.xcframework`, then symlinks the Xcode-linked
path at `scripts/cpsl-xcframework-placeholder/cpsl.xcframework` to the built
artifact.

The phase is marked always-out-of-date so Xcode invokes the script each build,
but the ensure script itself is cheap when nothing changed: it reuses
`.herm-cpsl/artifacts/apple/cpsl.xcframework` when all three slices are present
(iOS device, iOS simulator, macOS) and staleness inputs are not newer than
`Info.plist`. It rebuilds when the artifact is missing, incomplete, or stale
because files under `scripts/cpsl-patches/`, `scripts/build-cpsl-apple-xcframework.sh`,
or `scripts/apply-cpsl-patches.sh` changed.

Xcode builds always produce the full iOS+macOS XCFramework, even when the active
destination only needs one platform.

Xcode validates linked XCFrameworks before any target runs. A tracked bootstrap
placeholder at `scripts/cpsl-xcframework-placeholder/cpsl.xcframework`
satisfies that check on fresh clones. The ensure script then builds the real
XCFramework under gitignored `.herm-cpsl/artifacts/apple/`, and the Xcode helper
replaces the placeholder path with a local symlink to that artifact during the
build. The link step marks the tracked bootstrap files `skip-worktree` so
`git status` stays clean while the symlink is present. Do not commit the
symlink; only the bootstrap directory belongs in git.

### First-build prerequisites

The first full XCFramework build compiles five Rust targets and may take several
minutes. You need:

- **Full Xcode** installed and selected (Command Line Tools alone is not enough)
- The Rust Apple targets listed in [Apple XCFramework](#apple-xcframework)

Initialize Xcode from Terminal if needed:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
```

The `herm` target sets `ENABLE_USER_SCRIPT_SANDBOXING = NO` so the run-script
phase can invoke Cargo, Git, `xcodebuild`, and write under `.herm-cpsl/`.

### Force rebuild

To force a CPSL rebuild from Terminal or by exporting before an Xcode build:

```sh
HERM_CPSL_REBUILD=1 scripts/ensure-cpsl-apple-xcframework.sh
```

### visionOS

The `herm` target lists visionOS in `SUPPORTED_PLATFORMS`, but CPSL does not
yet support visionOS. Building for an `xros` or `xrsimulator` destination fails
early in the ensure script with a clear error before any Rust build starts.

### Dev launchers

`scripts/dev-apple-macos.sh` and `scripts/dev-apple-ios.sh` call the same
ensure script. Use `--skip-cpsl` to require an existing full XCFramework without
building, or `--rebuild-cpsl` to set `HERM_CPSL_REBUILD=1` before the ensure
step. The `--full-cpsl` flag is deprecated; the ensure script always builds the
full framework.

## macOS App From Terminal

Use the macOS dev launcher when you want to build and run the SwiftUI app
without opening Xcode:

```sh
scripts/dev-apple-macos.sh
```

The launcher must run from a macOS host shell with full Xcode selected.
Command Line Tools alone, usually selected as `/Library/Developer/CommandLineTools`,
is not enough for this Xcode project flow. It calls
`scripts/ensure-cpsl-apple-xcframework.sh` to build or reuse the CPSL
XCFramework, builds the `herm` app target for macOS, clears local extended
attributes from the finished bundle, ad-hoc signs it, then runs the app
executable directly so stdout and stderr stay attached to the terminal.

If Xcode is installed but Command Line Tools is selected, either select and
initialize Xcode globally:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
```

Or use Xcode only for one launch:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/dev-apple-macos.sh
```

For an LLDB session:

```sh
scripts/dev-apple-macos.sh --debug
```

For a build-only check:

```sh
scripts/dev-apple-macos.sh --build-only
```

By default, the launcher ensures the full iOS+macOS CPSL XCFramework via the
shared ensure script. Use `--universal-cpsl` when you want both arm64 and
x86_64 macOS slices. Use `--project-signing` if you want Xcode's configured
team/signing settings instead of local ad hoc signing.

## Options

```sh
scripts/build-cpsl-image.sh --minimum
scripts/build-cpsl-image.sh --all
OUT_DIR=/tmp/herm-cpsl scripts/build-cpsl-image.sh
RUN_PROBE=1 scripts/build-cpsl-image.sh
CPSL_ROOT=/path/to/cpsl scripts/build-cpsl-image.sh
CPSL_TARGET_DIR=/tmp/cpsl-target scripts/build-cpsl-image.sh
scripts/build-cpsl-apple-xcframework.sh
```

`RUN_PROBE=1` runs the ignored CPSL FFI probe test after building. The normal
script run already checks that Herm accepts the generated CPSL library path and
that the CPSL worker can load the library, create a session, and run a simple
Luau eval. With `--all`, the normal probe also checks `doc.pdfInfo()` and
structural `doc.read()` against CPSL's PDF fixture.

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

When running with an artifact built by `--all`, Herm tells CPSL where the loaded
library lives so PDFium can be discovered from `libs/pdfium/lib/` next to the
CPSL library. `PDFIUM_DYNAMIC_LIB_PATH` still takes precedence if you set it
explicitly.

Network access is policy-gated. Use repeatable `--allow-domain` and
`--deny-domain` flags when running Herm; deny rules take precedence over allow
rules.

```sh
cd .herm-cpsl/artifacts/linux-amd64
./herm --cpsl libcpsl.so --allow-domain example.com
```

CPSL mode does not provide Herm's container development tools, host package
installation, host `git`, Docker/OCI images, CPython, Node, or a system compiler
inside the sandbox.
