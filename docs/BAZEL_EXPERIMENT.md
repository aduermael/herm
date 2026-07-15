# Bazel Linux Experiment

This is a deliberately narrow experiment. Cargo and Go modules remain the
dependency sources of truth; Bazel models only the minimum Linux CPSL FFI
profile and the Herm binary.

The configuration pins Bazel, Go, Rust, and the Bazel rule sets. Crate Universe
reads CPSL's existing Cargo manifests and lockfile, while `go_deps` reads the
root Go module. The Rust targets intentionally select only `ffi-minimal` and
the matching CPSL core features.

After installing Bazel or Bazelisk, validate and build with:

```sh
bazel mod tidy
bazel build //:linux_experiment
bazel build //:cpsl_ffi //cmd/herm:herm
```

Compare the resulting clean and cached timings with
[`CPSL_BUILD_BASELINE.md`](CPSL_BUILD_BASELINE.md). Do not add Apple or web
targets until this Linux experiment builds reproducibly and demonstrates a
useful cache improvement.

`MODULE.bazel.lock` is intentionally absent from the initial scaffold because
the repository did not have Bazel available when it was created. Commit the
lockfile produced by the first successful `bazel mod tidy` validation.
