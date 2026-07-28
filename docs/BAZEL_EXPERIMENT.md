# Bazel CPSL Build

Bazel is the default build system for CPSL Apple XCFrameworks. Cargo remains
the source of truth for Rust dependency versions and is available as an
explicit Apple fallback. Host-native Linux CPSL builds continue to use Cargo.

The Bazel module pins Bazel, Go, Rust, and the Bazel rule sets. Crate Universe
reads the registry dependency mirror in `bazel/cpsl-deps`, whose lockfile is
derived from CPSL's committed Cargo lockfile. Herm models CPSL's first-party
path crates directly so repository generation does not write into the source
tree.

The `//:cpsl` shared-library target supports the minimal and Apple app feature
profiles. The Apple wrapper builds it once per requested target platform,
combines architecture slices where necessary, stages PDFium, and uses
`xcodebuild -create-xcframework` for the final package.

## Commands

On macOS with full Xcode selected and Bazelisk or Bazel installed:

```sh
scripts/build-cpsl-apple-xcframework.sh
```

The wrapper selects `--config=cpsl-apple`. Its five supported platform labels
are defined in `bazel/platforms/BUILD.bazel` for iOS device arm64, iOS
simulator arm64 and x86_64, and macOS arm64 and x86_64.

For the small profile, use:

```sh
scripts/build-cpsl-apple-xcframework.sh --minimum
```

To diagnose or temporarily bypass the Bazel path:

```sh
CPSL_APPLE_BUILD_SYSTEM=cargo scripts/build-cpsl-apple-xcframework.sh
```

The Cargo fallback requires a host Rust installation and the requested Apple
targets. It is also the only Apple path that accepts a separate `CPSL_ROOT`.

## Historical experiment

The original 2026-07-15 Linux-only experiment failed because Crate Universe
treated CPSL path dependencies as external generated repositories and did not
model the patched `conch-parser` dependency correctly. The adopted graph fixes
that by declaring first-party CPSL crates in the root Bazel package, using a
registry-only dependency manifest, and carrying a small `luau0-src` runfiles
compatibility patch. A Linux-safe `//:cpsl` minimum-profile build now completes;
native Apple builds are exercised by the macOS Xcode CI job.
