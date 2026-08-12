#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
apple_root="${SRCROOT:-"$repo_root/app/apple"}"
output="${APPLE_ENV_CONSTANTS_OUTPUT:-"$apple_root/herm/Generated/CPSLEnvConstants.swift"}"
generator="$repo_root/scripts/generate-apple-env-constants.swift"

if command -v xcrun >/dev/null 2>&1; then
  swift_command=(xcrun --sdk macosx swift)
elif command -v swift >/dev/null 2>&1; then
  swift_command=(swift)
else
  echo "swift is required to generate Apple environment constants." >&2
  exit 127
fi

"${swift_command[@]}" "$generator" "$output" \
  "$repo_root/.env" \
  "$apple_root/herm/.env" \
  "$apple_root/herm/Resources/.env" \
  "$repo_root/.env.local" \
  "$apple_root/herm/.env.local" \
  "$apple_root/herm/Resources/.env.local"

# Also regenerate the PCC runtime bridge (stub on SDK < 27, full on SDK 27+).
"${repo_root}/scripts/generate-apple-pcc-runtime.sh"
