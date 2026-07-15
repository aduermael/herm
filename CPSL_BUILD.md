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
- Rust 1.95.0 and Cargo (automatically selected by `rust-toolchain.toml` when
  Rust is installed with rustup)
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

The tracked CPSL revision includes the HTTP policy and composed mount
integration used by Herm. The exact revision is recorded in each generated
`build-manifest.txt`; inspect it before comparing or publishing artifacts.
Override the source when testing a local CPSL checkout:

```sh
CPSL_ROOT=/path/to/cpsl scripts/build-cpsl-image.sh
```

Before compiling CPSL, Herm applies the tracked integration patches listed in
`scripts/cpsl-patches/series` to the selected checkout, in manifest order.
These patches keep the pinned CPSL dependency aligned with Herm's app/runtime
integration. Unlisted local files are ignored. When a listed patch is already
present in the submodule commit, the patch helper skips it. The helper also
rejects custom checkouts that lack the web-view PDF network policy required to
keep personal mounts isolated.

The default host-native build is the minimal CPSL FFI profile. It compiles
`fs`, `json`, `csv`, `http`, and `grep`.

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
Herm verifies downloaded PDFium archives against the SHA-256 checksums tracked
for every supported target. Selecting an unrecognized PDFium version or target
fails before extraction until its trusted checksum is added to the CPSL patch.
Use the default profile unless you need a specific extra CPSL module.

## Output

The script builds CPSL's Cargo target directory and host-native output artifacts
under Herm's ignored `.herm-cpsl` directory:

```text
.herm-cpsl/cargo-target/

.herm-cpsl/artifacts/linux-amd64/
  herm
  libcpsl.so
  build-manifest.txt
  include/cpsl.h
  libs/pdfium/lib/libpdfium.so   # --all only

.herm-cpsl/artifacts/macos-arm64/
  herm
  libcpsl.dylib
  build-manifest.txt
  include/cpsl.h
  libs/pdfium/lib/libpdfium.dylib # --all only
```

The exact output directory depends on the host OS and CPU. Override it with
`OUT_DIR=/path/to/artifacts` if needed.

`build-manifest.txt` records the build profile, target, source revisions,
compiler versions, and SHA-256 hashes for the generated Herm, CPSL, header, and
PDFium artifacts that are present.

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

Direct CLI use follows the same source dependency model as the host-native
helper: Herm builds from `external/cpsl` unless `CPSL_ROOT` points at an
existing checkout. Xcode auto-builds are stricter and always build from Herm's
`external/cpsl` submodule, ignoring any `CPSL_ROOT` in the user's environment.

The script builds CPSL's FFI crate for iOS device, iOS simulator, and macOS
targets by default, then packages the dynamic libraries plus `cpsl.h` into one
XCFramework:

```text
.herm-cpsl/artifacts/apple/
  cpsl.xcframework
  build-manifest.txt
  include/cpsl.h
```

Direct CLI builds use Cargo's release profile by default. When invoked from
Xcode, the helper follows Xcode's `CONFIGURATION`: `Debug` uses Cargo's debug
profile and `Release` uses Cargo's release profile.

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

Target lists can also be narrowed explicitly. Empty target variables are
honored, so this builds only an Apple Silicon iOS simulator slice:

```sh
APPLE_PLATFORMS=ios \
  IOS_DEVICE_TARGETS= \
  IOS_SIMULATOR_TARGETS=aarch64-apple-ios-sim \
  scripts/build-cpsl-apple-xcframework.sh
```

The Apple helper builds CPSL's embedded agent FFI profile by default. That
profile keeps the existing minimum modules and adds the pure Rust
cross-platform utility/data modules from CPSL's broad feature set, plus `doc`
with the PDFium backend. HTTP remains present because it was already part of
the minimum profile, but the app still controls network access through its
session policy.

PDFium is staged next to the generated XCFramework:

```text
.herm-cpsl/artifacts/apple/
  cpsl.xcframework
  libs/pdfium/
    ios-arm64/lib/libpdfium.dylib
    ios-simulator/lib/libpdfium.dylib
    macos/lib/libpdfium.dylib
```

During Xcode builds, the `Copy CPSL PDFium` phase copies the platform-matching
`libpdfium.dylib` into the app's Frameworks directory. If Xcode requested only
one simulator architecture, only the matching simulator PDFium input is
downloaded before the staged `ios-simulator` sidecar is written. The Swift app
sets `CPSL_LIBRARY_DIR` to that directory before creating a CPSL session so
`doc.pdfInfo`, structural `doc.read(..., {mode="structural"})`, and other
PDFium-backed `doc` functions can find the library at runtime.

Use `--minimum` only when you explicitly want the older small sandbox profile.
The `--all` profile is intentionally not enabled for Apple app builds; it still
includes modules outside the app-focused pure-Rust/doc set.

For an iOS-only output under `.herm-cpsl/artifacts/ios/`, use the Apple helper
with the iOS platform selected:

```sh
APPLE_PLATFORMS=ios OUT_DIR=.herm-cpsl/artifacts/ios scripts/build-cpsl-apple-xcframework.sh
```

## Xcode auto-build

Opening `app/apple/herm.xcodeproj` in Xcode and building the `herm` target
automatically ensures the CPSL XCFramework exists before Swift compilation.

The `herm` target depends on a **Build CPSL XCFramework** helper target that
runs before Swift compilation. On every build it runs:

```sh
"${SRCROOT}/../../scripts/link-cpsl-xcframework-for-xcode.sh"
```

That helper calls `ensure-cpsl-apple-xcframework.sh` to build or reuse
the configuration-scoped CPSL artifact and its PDFium sidecar libraries, then
links the built XCFramework into the Xcode-linked path at
`scripts/cpsl-xcframework-placeholder/cpsl.xcframework`.

The helper target is built as a dependency of `herm`, so it receives the same
`PLATFORM_NAME`/`SDK_NAME`, `ARCHS`, and `CONFIGURATION` values as the app
build and finishes before `ProcessXCFramework` runs. Its declared output is a
DerivedData stamp file so Xcode does not create a dependency cycle with the
linked XCFramework path. The phase has no declared inputs, so dependency
analysis invokes it on each build without forcing the phase out of date. The
ensure script itself is cheap when nothing changed:
it reuses
`.herm-cpsl/artifacts/apple/Debug/cpsl.xcframework` or
`.herm-cpsl/artifacts/apple/Release/cpsl.xcframework` when it contains the
platform and architectures selected by Xcode's `PLATFORM_NAME`/`SDK_NAME` and
`ARCHS`, and staleness inputs are not newer than `Info.plist`. For Xcode
auto-builds, reuse also requires the adjacent `.cpsl-source.stamp` to show that
the artifact was built from Herm's `external/cpsl` submodule at the current
revision and matching Cargo profile. It rebuilds when the artifact is missing,
lacks the requested slice, was built from another CPSL checkout, revision, or
Cargo profile, or is stale because the CPSL patch series or one of its listed
patches, `scripts/build-cpsl-apple-xcframework.sh`,
`scripts/lib/cpsl-xcframework.sh`, or `scripts/apply-cpsl-patches.sh` changed.

Xcode keeps Debug and Release CPSL artifacts separate:

```text
.herm-cpsl/artifacts/apple/Debug/
  cpsl.xcframework
  libs/pdfium/

.herm-cpsl/artifacts/apple/Release/
  cpsl.xcframework
  libs/pdfium/
```

Xcode builds produce only the selected platform and architectures. For example,
an Apple Silicon iPhone simulator build creates `aarch64-apple-ios-sim` and the
simulator PDFium sidecar; it does not also build x86_64 simulator, iOS device,
or macOS slices. A later build for another destination rebuilds the cached
artifact for that destination.

Xcode validates linked XCFrameworks before any target runs. A tracked bootstrap
placeholder at `scripts/cpsl-xcframework-placeholder/cpsl.xcframework`
satisfies that check on fresh clones. The ensure script then builds the real
XCFramework under the gitignored configuration artifact directory. The Xcode
helper keeps the linked path in the full bootstrap placeholder shape and
overlays only the real slice directory requested by the current build. For
simulator and macOS overlays, any unrequested architecture advertised by the
placeholder (`arm64` or `x86_64`) is filled with a tiny validation stub dylib,
not a CPSL build, so a failed build still leaves a pre-validation-safe linked
path. After Xcode has linked and embedded the real slice, the later `Copy CPSL
PDFium` phase restores the tracked bootstrap placeholder and removes the local
link stamp so the next build overlays again. This keeps the source-tree linked
path valid for later destination switches before run scripts execute, without
building every platform up front. The temporary overlay marks the tracked
bootstrap files `skip-worktree` so `git status` stays clean while local built
slices are present. Do not commit the local overlay; only the bootstrap
directory belongs in git.

If a local checkout has an older broken symlink at the placeholder path, restore
the bootstrap directory once before opening Xcode:

```sh
scripts/bootstrap-cpsl-xcframework-placeholder.sh
```

### First-build prerequisites

The first CPSL XCFramework build for a destination may take several minutes.
You need:

- **Full Xcode** installed and selected (Command Line Tools alone is not enough)
- The Rust Apple target(s) for the selected Xcode destination, or all targets
  listed in [Apple XCFramework](#apple-xcframework) if you want the direct CLI
  default output

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
ensure script. Use `--skip-cpsl` to require an existing matching XCFramework
without building, or `--rebuild-cpsl` to set `HERM_CPSL_REBUILD=1` before the
ensure step. The `--full-cpsl` flag is deprecated; the ensure script builds the
framework slices requested by its environment. These terminal launchers pass
their selected `--configuration` into CPSL preflight, so a Debug launcher build
uses the Debug CPSL artifact and a Release launcher build uses the Release CPSL
artifact.

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
