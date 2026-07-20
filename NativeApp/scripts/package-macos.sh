#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
native_app_dir="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$native_app_dir/.." && pwd)"
signing_mode="${INBOX_ZERO_SIGNING_MODE:-adhoc}"
output_path="${INBOX_ZERO_PACKAGE_OUTPUT:-$native_app_dir/zig-out/package/Inbox Zero Mail.app}"

generator_args=(--require-gmail)
if [[ -f "$repo_root/Config/LocalSecrets.xcconfig" ]]; then
  generator_args+=(--from-xcconfig "$repo_root/Config/LocalSecrets.xcconfig")
fi

cd "$native_app_dir"
node scripts/write-oauth-config.mjs "${generator_args[@]}"
npx --yes @native-sdk/cli@0.5.3 test . --yes
npx --yes @native-sdk/cli@0.5.3 check . --strict
npx --yes @native-sdk/cli@0.5.3 build . --yes

package_args=(
  --target macos
  --output "$output_path"
  --binary zig-out/bin/inbox-zero-mail-native
  --assets assets
  --signing "$signing_mode"
)
if [[ "$signing_mode" == "identity" ]]; then
  : "${INBOX_ZERO_CODESIGN_IDENTITY:?Set INBOX_ZERO_CODESIGN_IDENTITY for identity signing}"
  package_args+=(--identity "$INBOX_ZERO_CODESIGN_IDENTITY")
fi

npx --yes @native-sdk/cli@0.5.3 package "${package_args[@]}"
echo "Packaged $output_path"
