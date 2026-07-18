#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
NATIVE_ZIG="${INBOX_ZERO_NATIVE_ZIG:-${HOME}/.native/toolchains/zig-0.16.0/zig}"

if [[ ! -x "${NATIVE_ZIG}" ]]; then
  (cd "${APP_DIR}" && npx --yes @native-sdk/cli@0.5.3 test . --yes >/dev/null)
fi

if [[ ! -x "${NATIVE_ZIG}" ]]; then
  echo "oauth-coordinator-emulator: Native SDK Zig 0.16.0 toolchain was not installed" >&2
  exit 1
fi

cd "${APP_DIR}"
"${NATIVE_ZIG}" run src/oauth_emulator_integration_runner.zig
