# Bazel Linux Experiment

This is a deliberately narrow experiment. Cargo and Go modules remain the
dependency sources of truth; Bazel models only the minimum Linux CPSL FFI
profile and the Herm binary.

The configuration pins Bazel, Go, Rust, and the Bazel rule sets. Crate Universe
reads CPSL's existing Cargo manifests and lockfile, while `go_deps` reads the
root Go module. The Rust targets intentionally select only `ffi-minimal` and
the matching CPSL core features.

After installing Bazel or Bazelisk, reproduce the experiment with:

```sh
bazel mod tidy
bazel build //:linux_experiment
bazel build //:cpsl_ffi //cmd/herm:herm
```

Compare any resulting clean and cached timings with
[`CPSL_BUILD_BASELINE.md`](CPSL_BUILD_BASELINE.md).

## Result and decision

The experiment was run with Bazel 9.1.1 on 2026-07-15. `bazel mod tidy`
completed but warned that CPSL path dependencies were non-hermetic and copied
them into top-level `modules/` and `vendor/` directories. The subsequent
`bazel build //:linux_experiment` failed during analysis because the generated
Crate Universe repository did not declare the `void` dependency required by
the patched `conch-parser` crate. No comparable Bazel timing was produced.

Bazel is not the supported CPSL Apple build system. `rules_rust` can generate
dependencies from Cargo and build a shared Rust library, and Bazel's strongest
additional benefit would be a content-addressed remote cache. This repository
does not currently have that cache infrastructure, while its measured warm
Cargo build is one second and the Xcode path now uses a content-keyed no-op plus
Cargo's Debug incremental compilation. Adopting Bazel today would duplicate the
Cargo feature/dependency graph and still require custom Apple slice, PDFium,
XCFramework, and Xcode integration logic.

Revisit the decision only if cross-machine cache reuse becomes a concrete need.
Before considering Apple integration, require the Linux target to build from a
committed lockfile without non-hermetic path warnings and show a material clean
or cached improvement over the Cargo baseline. Then prove all five Apple Rust
triples and Debug/Release parity independently. See the official
[`rules_rust` Crate Universe documentation](https://bazelbuild.github.io/rules_rust/crate_universe_bzlmod.html)
and [Bazel remote-cache requirements](https://bazel.build/remote/caching).
