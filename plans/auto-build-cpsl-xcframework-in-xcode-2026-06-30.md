# Auto-Build CPSL XCFramework In Xcode

**Goal:** Add a repo-tracked Xcode run-script build phase so opening the herm project in Xcode and building "just works" — the full CPSL XCFramework is built automatically before Swift compilation when missing, incomplete, or stale.

**Context:**

- The herm target already links `../../.herm-cpsl/artifacts/apple/cpsl.xcframework` and Swift code uses `import CPSL`.
- `scripts/build-cpsl-apple-xcframework.sh` already produces a full XCFramework (iOS device, iOS simulator, macOS).
- `scripts/dev-apple-macos.sh` and `scripts/dev-apple-ios.sh` already contain overlapping CPSL ensure logic (presence, patch staleness, partial slice checks). This plan consolidates that into one shared script to avoid drift.
- The Xcode project has `ENABLE_USER_SCRIPT_SANDBOXING = YES` at the project level and no run-script build phases today.
- The target lists `xros` / `xrsimulator` in `SUPPORTED_PLATFORMS`, but the CPSL builder supports only iOS and macOS.

**Key files:**

- `scripts/build-cpsl-apple-xcframework.sh` — full XCFramework builder (unchanged behavior)
- `scripts/dev-apple-macos.sh` — macOS dev launcher (refactor to call ensure script)
- `scripts/dev-apple-ios.sh` — iOS dev launcher (refactor to call ensure script)
- `scripts/cpsl-patches/` — tracked integration patches
- `app/apple/herm.xcodeproj/project.pbxproj` — add run-script phase, disable sandbox at target level
- `CPSL_BUILD.md` — document Xcode auto-build flow

---

## Contracts

### Shared library: `scripts/lib/cpsl-xcframework.sh`

Sourced by the ensure script and dev launchers. Contains the validation and staleness helpers currently duplicated in `dev-apple-*.sh`:

- `cpsl_xcframework_info_plist PATH` — returns `Info.plist` path for an XCFramework
- `cpsl_xcframework_has_ios_device INFO_PLIST` — `SupportedPlatform: ios` without `SupportedPlatformVariant: simulator`
- `cpsl_xcframework_has_ios_simulator INFO_PLIST` — `SupportedPlatform: ios` with `SupportedPlatformVariant: simulator`
- `cpsl_xcframework_has_macos INFO_PLIST` — `SupportedPlatform: macosx`
- `cpsl_xcframework_is_full INFO_PLIST` — all three slices above present
- `cpsl_xcframework_inputs_newer_than INFO_PLIST HERM_ROOT` — true when any staleness input is newer than `Info.plist`

**Staleness inputs** (compare newest mtime against `$xcframework/Info.plist`):

```text
scripts/cpsl-patches/**
scripts/build-cpsl-apple-xcframework.sh
scripts/apply-cpsl-patches.sh
```

### Ensure script: `scripts/ensure-cpsl-apple-xcframework.sh`

Single source of truth for "is the full CPSL XCFramework ready?"

**Behavior:**

1. **visionOS guard** — if Xcode build env indicates `xros` or `xrsimulator` (check `PLATFORM_NAME` and/or `SDKROOT`), exit with a clear error before any build attempt. Message should state that CPSL does not yet support visionOS and name the supported platforms.
2. **Force rebuild** — if `HERM_CPSL_REBUILD=1`, always invoke the builder.
3. **No-op** — if the XCFramework exists, `cpsl_xcframework_is_full` passes, and staleness inputs are not newer than `Info.plist`, print a short reuse message and exit 0.
4. **Rebuild** — otherwise call `scripts/build-cpsl-apple-xcframework.sh` with `APPLE_PLATFORMS=ios macos` (full XCFramework regardless of active Xcode destination).
5. **Env passthrough** — existing overrides (`CPSL_ROOT`, `CPSL_REF`, `CPSL_WORK_DIR`, `OUT_DIR`, Rust target env vars) flow through unchanged to the builder.

**Optional lock file** (recommended): acquire `.herm-cpsl/.cpsl-xcframework-build.lock` during rebuild to reduce concurrent-build races when two Xcode builds start on a missing artifact. Release on exit; stale locks older than a reasonable timeout may be overwritten.

### Xcode run-script phase

- Name: `Build CPSL XCFramework`
- Insert **before** Sources in the herm target `buildPhases` list
- Shell script body: `"${SRCROOT}/../../scripts/ensure-cpsl-apple-xcframework.sh"`
- `alwaysOutOfDate = 1` — the ensure script performs the cheap staleness check; no-op path must be fast
- Keep the existing framework reference at `../../.herm-cpsl/artifacts/apple/cpsl.xcframework`

### Target build settings

Set `ENABLE_USER_SCRIPT_SANDBOXING = NO` on the **herm target** Debug and Release configurations (not project-wide). The CPSL builder needs Cargo, Git, `xcodebuild`, and writes under `.herm-cpsl/`.

### Dev launcher refactor

`dev-apple-macos.sh` and `dev-apple-ios.sh` replace their inline CPSL ensure blocks with calls to `ensure-cpsl-apple-xcframework.sh`:

- `--skip-cpsl` — require existing full XCFramework; error if missing or incomplete (no build)
- `--rebuild-cpsl` — set `HERM_CPSL_REBUILD=1` before calling ensure script
- `--full-cpsl` — no longer needed for platform selection when using ensure script (ensure always builds full framework); keep flag as alias/no-op or deprecate with a note in help text
- Platform-specific partial builds (`APPLE_PLATFORMS=macos` default in macOS launcher) move to explicit env overrides on the builder for advanced use; the ensure script and Xcode path always use full framework

**Note:** First full XCFramework build compiles five Rust targets and may take several minutes. Requires full Xcode (not Command Line Tools alone) and all five Apple Rust targets installed (`CPSL_BUILD.md` documents the `rustup target add` command).

---

## Phase 1: Shared CPSL XCFramework helpers and ensure script

- [x] 1a: Add `scripts/lib/cpsl-xcframework.sh` with slice validation helpers (`ios device`, `ios simulator`, `macos`) and staleness detection over the three input paths listed above. Extract logic from `dev-apple-macos.sh` / `dev-apple-ios.sh`; extend macOS launcher's platform check to distinguish device vs simulator slices.
- [x] 1b: Add `scripts/ensure-cpsl-apple-xcframework.sh` implementing visionOS guard, `HERM_CPSL_REBUILD=1`, full-framework validation, staleness check, optional lock file, and delegation to `build-cpsl-apple-xcframework.sh` with `APPLE_PLATFORMS=ios macos`.
- [x] 1c: Refactor `scripts/dev-apple-macos.sh` and `scripts/dev-apple-ios.sh` to call `ensure-cpsl-apple-xcframework.sh` instead of inline CPSL logic. Map `--skip-cpsl` / `--rebuild-cpsl` to ensure-script behavior; update `--help` for `--full-cpsl` deprecation note.

## Phase 2: Xcode project integration

- [x] 2a: Edit `app/apple/herm.xcodeproj/project.pbxproj` — add `PBXShellScriptBuildPhase` named `Build CPSL XCFramework` before Sources, with `alwaysOutOfDate = 1` and shell script `"${SRCROOT}/../../scripts/ensure-cpsl-apple-xcframework.sh"`.
- [x] 2b: Set `ENABLE_USER_SCRIPT_SANDBOXING = NO` on herm target Debug and Release build configurations in `project.pbxproj`.

## Phase 3: Documentation

- [x] 3a: Update `CPSL_BUILD.md` with an "Xcode auto-build" section: run-script phase behavior, first-build prerequisites (full Xcode, Rust Apple targets), `HERM_CPSL_REBUILD=1`, visionOS unsupported, and note that dev launchers now share the ensure script.

## Phase 4: Verification

- [x] 4a: Static syntax checks: `sh -n scripts/lib/cpsl-xcframework.sh`, `sh -n scripts/ensure-cpsl-apple-xcframework.sh`, `sh -n scripts/build-cpsl-apple-xcframework.sh`, `sh -n scripts/dev-apple-macos.sh`, `sh -n scripts/dev-apple-ios.sh`.
- [x] 4b: On macOS with full Xcode and Rust Apple targets: remove `.herm-cpsl/artifacts/apple/cpsl.xcframework`, build herm in Xcode or via `xcodebuild` — CPSL builds before Swift compilation.
- [x] 4c: Rebuild immediately — ensure script reuses existing XCFramework (fast no-op).
- [x] 4d: Build iOS simulator and macOS destinations — both link/embed the same full XCFramework.
- [x] 4e: Touch a file under `scripts/cpsl-patches/` and rebuild — ensure script rebuilds CPSL.
- [x] 4f: Touch `scripts/build-cpsl-apple-xcframework.sh` and rebuild — ensure script rebuilds CPSL.
- [x] 4g: Build for a visionOS destination — clear unsupported-platform error before Rust build starts.
- [x] 4h: Run `scripts/dev-apple-macos.sh --build-only` — confirm it still works via the shared ensure script.

---

## Assumptions

- Xcode builds always produce the full iOS+macOS XCFramework, even when the active destination only needs one platform.
- visionOS remains unsupported until `build-cpsl-apple-xcframework.sh` gains xros slices; the ensure script fails early rather than attempting a partial build.
- Changes are made directly in `project.pbxproj`, not through the Xcode UI, because the run-script phase and sandbox override are repo-tracked infrastructure.
- Deployment target mismatch (Xcode target 26.5 vs CPSL builder defaults 17.0/14.0) is acceptable for the dylib artifacts.

## Success criteria

- Fresh clone + Xcode build creates `.herm-cpsl/artifacts/apple/cpsl.xcframework` with all three slices before Swift compiles.
- Subsequent builds skip rebuild when artifact is complete and inputs are unchanged.
- Dev launchers and Xcode share one ensure implementation with no duplicated validation logic.
- visionOS builds fail with an actionable message.
- `CPSL_BUILD.md` documents the workflow for developers who do not use the dev launchers.