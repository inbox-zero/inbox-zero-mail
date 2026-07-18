#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SCREENSHOT_PATH="${APP_DIR}/.zig-cache/native-sdk-automation/screenshot-mail-canvas.png"
COMPOSE_SCREENSHOT_PATH="${APP_DIR}/.zig-cache/native-sdk-automation/screenshot-compose-canvas.png"
SNAPSHOT_PATH="${APP_DIR}/.zig-cache/native-sdk-automation/snapshot.txt"

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
  'Microsoft follow up' \
  'role=button name="drafts"'
run_native automate screenshot mail-canvas

widget_id() {
  local role="$1"
  local name="$2"
  sed -n "s/.*#\\([0-9][0-9]*\\) role=${role} name=\"${name}\".*/\\1/p" "${SNAPSHOT_PATH}" | head -1
}

compose_id="$(widget_id button Compose)"
new_window_id="$(widget_id button 'New window')"
microsoft_message_id="$(sed -n 's/.*#\([0-9][0-9]*\) role=listitem name="Microsoft follow up,.*/\1/p' "${SNAPSHOT_PATH}" | head -1)"
[[ -n "${compose_id}" && -n "${new_window_id}" && -n "${microsoft_message_id}" ]]

# Pointer routing is usable on every host and proves the dynamic secondary
# window descriptor and native compose markup are installed. Native SDK 0.5.3
# Linux still reports UnsupportedViewFocus for semantic text injection; the
# provider save/send sequence is covered by the fake-effects integration tests.
run_native automate widget-click mail-canvas "${compose_id}"
run_native automate assert --timeout-ms 5000 \
  'window @w[0-9]+ "Compose"' \
  'role=textbox name="To"' \
  'role=textbox name="Subject"' \
  'role=textbox name="Message body"' \
  'role=button name="Save draft"' \
  'role=button name="Send"'
run_native automate screenshot compose-canvas

discard_id="$(widget_id button Discard)"
[[ -n "${discard_id}" ]]
run_native automate widget-click compose-canvas "${discard_id}"
run_native automate assert --timeout-ms 5000 'Draft discarded.'

run_native automate widget-click mail-canvas "${microsoft_message_id}"
run_native automate assert --timeout-ms 5000 'role=listitem name="Microsoft follow up,.*selected'
run_native automate widget-click mail-canvas "${new_window_id}"
run_native automate assert --timeout-ms 5000 'window @w[0-9]+ "Microsoft follow up"'

if [[ ! -s "${SCREENSHOT_PATH}" ]]; then
  echo "Automation screenshot was not created: ${SCREENSHOT_PATH}" >&2
  exit 1
fi
if [[ ! -s "${COMPOSE_SCREENSHOT_PATH}" ]]; then
  echo "Compose automation screenshot was not created: ${COMPOSE_SCREENSHOT_PATH}" >&2
  exit 1
fi

echo "Native SDK automation smoke test passed."
echo "Screenshot: ${SCREENSHOT_PATH}"
echo "Compose screenshot: ${COMPOSE_SCREENSHOT_PATH}"
