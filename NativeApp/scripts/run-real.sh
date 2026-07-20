#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
native_app_dir="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$native_app_dir/.." && pwd)"

generator_args=(--require-gmail)
if [[ -f "$repo_root/Config/LocalSecrets.xcconfig" ]]; then
  generator_args+=(--from-xcconfig "$repo_root/Config/LocalSecrets.xcconfig")
fi

cd "$native_app_dir"
node scripts/write-oauth-config.mjs "${generator_args[@]}"
unset INBOX_ZERO_EMULATE
exec npx --yes @native-sdk/cli@0.5.3 dev . --yes "$@"
