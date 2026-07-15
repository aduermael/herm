#!/bin/sh
set -eu

die() {
	printf '%s\n' "error: $*" >&2
	exit 1
}

profile=minimum
case "${1:-}" in
'' | --minimum) ;;
--all) profile=all ;;
*) die "usage: scripts/measure-cpsl-build.sh [--minimum|--all]" ;;
esac

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
herm_root=$(CDPATH= cd "$script_dir/.." && pwd -P)
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
benchmark_dir=${CPSL_BENCHMARK_DIR:-"$herm_root/.herm-cpsl/benchmarks/$timestamp-$$"}
mkdir -p "$benchmark_dir"
benchmark_dir=$(CDPATH= cd "$benchmark_dir" && pwd -P)

measure_build() {
	label=$1
	start=$(date +%s)
	CPSL_WORK_DIR="$benchmark_dir" RUN_PROBE=1 \
		"$script_dir/build-cpsl-image.sh" "--$profile"
	end=$(date +%s)
	elapsed=$((end - start))
	printf '%s build: %ss\n' "$label" "$elapsed"
}

measure_build cold
cold_seconds=$elapsed
measure_build warm
warm_seconds=$elapsed

manifest=$(find "$benchmark_dir/artifacts" -name build-manifest.txt -type f -print | sed -n '1p')
[ -n "$manifest" ] || die "build manifest was not produced"
report="$benchmark_dir/benchmark.tsv"
{
	printf 'metric\tvalue\n'
	printf 'measured_at_utc\t%s\n' "$timestamp"
	printf 'profile\t%s\n' "$profile"
	printf 'target\t%s\n' "$(awk -F= '$1 == "target" { print $2 }' "$manifest")"
	printf 'herm_revision\t%s\n' "$(awk -F= '$1 == "herm_revision" { print $2 }' "$manifest")"
	printf 'cpsl_revision\t%s\n' "$(awk -F= '$1 == "cpsl_revision" { print $2 }' "$manifest")"
	printf 'cold_seconds\t%s\n' "$cold_seconds"
	printf 'warm_seconds\t%s\n' "$warm_seconds"
} >"$report"

printf '\nBenchmark report: %s\n' "$report"
