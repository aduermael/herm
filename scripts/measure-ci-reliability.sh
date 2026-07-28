#!/bin/sh
set -eu

die() {
	printf '%s\n' "error: $*" >&2
	exit 1
}

repository=${1:-aduermael/herm}
workflow=${2:-test.yml}
sample_size=${3:-100}
case "$sample_size" in
'' | *[!0-9]*) die "sample size must be an integer from 1 to 100" ;;
esac
[ "$sample_size" -ge 1 ] && [ "$sample_size" -le 100 ] || \
	die "sample size must be an integer from 1 to 100"

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

url="https://api.github.com/repos/$repository/actions/workflows/$workflow/runs?per_page=$sample_size"
if [ -n "${GITHUB_TOKEN:-}" ]; then
	response=$(curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" "$url")
else
	response=$(curl -fsSL "$url")
fi

successes=$(printf '%s' "$response" | jq '[.workflow_runs[] | select(.conclusion == "success")] | length')
failures=$(printf '%s' "$response" | jq '[.workflow_runs[] | select(.conclusion == "failure")] | length')
completed=$((successes + failures))
[ "$completed" -gt 0 ] || die "the sample contains no successful or failed runs"
failure_rate=$(awk -v failed="$failures" -v total="$completed" 'BEGIN { printf "%.2f", failed * 100 / total }')

printf 'metric\tvalue\n'
printf 'repository\t%s\n' "$repository"
printf 'workflow\t%s\n' "$workflow"
printf 'sample_requested\t%s\n' "$sample_size"
printf 'completed_runs\t%s\n' "$completed"
printf 'successful_runs\t%s\n' "$successes"
printf 'failed_runs\t%s\n' "$failures"
printf 'observed_failure_rate_percent\t%s\n' "$failure_rate"
