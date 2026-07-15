# CPSL Build Baseline

Measured on 2026-07-15 with the minimum CPSL profile and runtime probe enabled.

| Metric | Value |
| --- | --- |
| Host | Linux 7.0.11, ARM64, 18 CPUs |
| Herm revision | `96127ed134c2a4ca590874313bc37b4b88ca5c15` |
| CPSL revision | `336369f3f6aeab997b009f02e4716cf48727b96e` |
| Cold target-directory build | 36 seconds |
| Warm target-directory build | 1 second |
| Recent Tests workflow runs | 97 successful, 3 failed |
| Observed workflow failure rate | 3.00% of 100 completed runs |

The cold measurement used an empty Cargo target directory but an existing
Cargo registry cache. Both timings include the Go build, worker smoke test, and
ignored FFI contract probe. The workflow rate is a raw outcome rate from the
GitHub API, not a confirmed infrastructure-flake rate.

Reproduce the measurements with:

```sh
scripts/measure-cpsl-build.sh
scripts/measure-ci-reliability.sh
```
