#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
vet_root="${VET_ROOT:-"$repo_root/external/vet"}"
vet_package="$vet_root/implementations/swift"

if ! command -v swift >/dev/null 2>&1; then
  echo "swift is required to run the Swift vet runner." >&2
  exit 127
fi

if [[ ! -f "$vet_package/Package.swift" ]]; then
  echo "vet Swift runner not found at: $vet_package" >&2
  echo "Clone https://github.com/gdevillele/vet to external/vet or set VET_ROOT." >&2
  exit 2
fi

cd "$repo_root"
swift run --package-path "$vet_package" vet --config "$repo_root/.vet.yaml"
