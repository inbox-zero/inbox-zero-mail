#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SCREENSHOT_PATH="${APP_DIR}/.zig-cache/native-sdk-automation/screenshot-mail-canvas.png"

cd "${APP_DIR}"

run_native() {
  npx --yes @native-sdk/cli@0.5.3 "$@"
}

# This script deliberately does not start or stop shared services. The emulator
# and an automation-enabled app instance must already be running from APP_DIR.
run_native automate wait
run_native automate assert --timeout-ms 30000 \
  'Combined inbox' \
  'Release checklist' \
  'VIP migration timeline' \
  'Microsoft follow up'
run_native automate screenshot mail-canvas

if [[ ! -s "${SCREENSHOT_PATH}" ]]; then
  echo "Automation screenshot was not created: ${SCREENSHOT_PATH}" >&2
  exit 1
fi

echo "Native SDK automation smoke test passed."
echo "Screenshot: ${SCREENSHOT_PATH}"
