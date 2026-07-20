#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SCREENSHOT_PATH="${APP_DIR}/.zig-cache/native-sdk-automation/screenshot-mail-canvas.png"
COMPOSE_SCREENSHOT_PATH="${APP_DIR}/.zig-cache/native-sdk-automation/screenshot-compose-canvas.png"
INBOX_WINDOW_SCREENSHOT_PATH="${APP_DIR}/.zig-cache/native-sdk-automation/screenshot-inbox-canvas-1.png"
SNAPSHOT_PATH="${APP_DIR}/.zig-cache/native-sdk-automation/snapshot.txt"

cd "${APP_DIR}"

run_native() {
  npx --yes @native-sdk/cli@0.5.3 "$@"
}

# This script deliberately does not start or stop shared services. The emulator
# and an automation-enabled app instance must already be running from APP_DIR.
run_native automate wait
# Normalize any modal and return to the All split after an interrupted run.
run_native automate widget-key mail-canvas escape
run_native automate focus mail-canvas
run_native automate shortcut mail.command-palette
for _ in $(seq 1 3); do run_native automate widget-key mail-canvas arrowdown; done
run_native automate widget-key mail-canvas enter
run_native automate assert --timeout-ms 30000 \
  'role=tab name="All  [0-9]+"' \
  'role=tab name="Unread  [0-9]+"' \
  'Release checklist' \
  'VIP migration timeline' \
  'Microsoft follow up' \
  'role=button name="Open navigation"'
run_native automate screenshot mail-canvas

widget_id() {
  local role="$1"
  local name="$2"
  sed -n "s/.*#\\([0-9][0-9]*\\) role=${role} name=\"${name}\".*/\\1/p" "${SNAPSHOT_PATH}" | head -1
}

compose_id="$(widget_id button Compose)"
navigation_id="$(widget_id button 'Open navigation')"
microsoft_message_id="$(sed -n 's/.*#\([0-9][0-9]*\) role=listitem name="Microsoft follow up,.*/\1/p' "${SNAPSHOT_PATH}" | head -1)"
[[ -n "${compose_id}" && -n "${navigation_id}" && -n "${microsoft_message_id}" ]]

# Account connection and secondary mailbox views stay available without
# permanently consuming the left side of the compact inbox.
run_native automate widget-click mail-canvas "${navigation_id}"
run_native automate assert --timeout-ms 5000 \
  'Mailboxes and folders' \
  'All accounts' \
  'role=button name="Connect Gmail"' \
  'role=button name="Connect Outlook"' \
  'role=button name="Drafts"'
run_native automate widget-key mail-canvas escape

# The command palette is the discoverable path for opening one live window per
# mailbox. Command-N remains the fast path for another All Inboxes window.
run_native automate focus mail-canvas
run_native automate shortcut mail.command-palette
run_native automate assert --timeout-ms 5000 \
  'role=dialog name="Command palette"' \
  'role=listitem name="Compose".*focused=true.*selected' \
  'role=listitem name="Search mail"' \
  'role=listitem name="Open All Inboxes window"' \
  'Up/Down to navigate.*Enter to open.*Esc to close'
for _ in $(seq 1 8); do run_native automate widget-key mail-canvas arrowdown; done
run_native automate assert --timeout-ms 5000 'role=listitem name="Open All Inboxes window".*focused=true.*selected'
run_native automate widget-key mail-canvas enter
run_native automate assert --timeout-ms 5000 \
  'view @w[0-9]+/inbox-canvas-1' \
  'inbox-canvas-1.*role=text name="All Inboxes"'
run_native automate screenshot inbox-canvas-1

run_native automate focus mail-canvas
run_native automate shortcut mail.command-palette
run_native automate assert --timeout-ms 5000 'role=dialog name="Command palette"'
run_native automate widget-key mail-canvas arrowdown
run_native automate assert --timeout-ms 5000 \
  'role=listitem name="Search mail".*focused=true.*selected' \
  'role=listitem name="Compose".*value=0'
run_native automate widget-key mail-canvas enter
run_native automate assert --timeout-ms 5000 \
  'role=textbox name="Search mail".*focused=true'
search_id="$(widget_id button Search)"
[[ -n "${search_id}" ]]
run_native automate widget-click mail-canvas "${search_id}"

# Tab and Shift-Tab move between the top split inboxes.
run_native automate widget-key mail-canvas tab
run_native automate assert --timeout-ms 5000 'role=tab name="Unread  [0-9]+".*selected'
for _ in $(seq 1 4); do run_native automate widget-key mail-canvas tab; done
run_native automate assert --timeout-ms 5000 'role=tab name="All  [0-9]+".*selected'

# Open a specific account window from the expanded palette command list.
run_native automate shortcut mail.command-palette
for _ in $(seq 1 9); do run_native automate widget-key mail-canvas arrowdown; done
run_native automate assert --timeout-ms 5000 'role=listitem name="Alpha Inbox".*selected'
run_native automate widget-key mail-canvas enter
run_native automate assert --timeout-ms 5000 \
  'view @w[0-9]+/inbox-canvas-2' \
  'inbox-canvas-2.*role=text name="Alpha Inbox"' \
  'inbox-canvas-2.*Release checklist'

alpha_message_id="$(sed -n 's/.*inbox-canvas-2#\([0-9][0-9]*\) role=listitem name="Release checklist,.*/\1/p' "${SNAPSHOT_PATH}" | head -1)"
[[ -n "${alpha_message_id}" ]]
run_native automate widget-click inbox-canvas-2 "${alpha_message_id}"
run_native automate assert --timeout-ms 5000 \
  'inbox-canvas-2.*role=button name="Back to inbox"' \
  'inbox-canvas-2.*role=text name="Release checklist"'
run_native automate assert --absent --timeout-ms 5000 'window @w[0-9]+ "Release checklist"'
alpha_back_id="$(sed -n 's/.*inbox-canvas-2#\([0-9][0-9]*\) role=button name="Back to inbox".*/\1/p' "${SNAPSHOT_PATH}" | head -1)"
[[ -n "${alpha_back_id}" ]]
run_native automate widget-click inbox-canvas-2 "${alpha_back_id}"
run_native automate assert --timeout-ms 5000 'inbox-canvas-2.*role=listitem name="Release checklist,.*selected'

# Pointer routing is usable on every host and proves the dynamic compose
# descriptor and native markup are installed. Native SDK 0.5.3 Linux still
# reports UnsupportedViewFocus for semantic text injection; provider save/send
# sequencing is covered by the fake-effects integration tests.
run_native automate focus mail-canvas
run_native automate widget-click mail-canvas "${compose_id}"
run_native automate assert --timeout-ms 5000 \
  'window @w[0-9]+ "Compose"' \
  'role=textbox name="To recipients, separated by commas"' \
  'role=textbox name="Subject"' \
  'role=textbox name="Message body"' \
  'role=button name="Save draft"' \
  'role=button name="Send"'
run_native automate screenshot compose-canvas

discard_id="$(widget_id button Discard)"
[[ -n "${discard_id}" ]]
run_native automate widget-click compose-canvas "${discard_id}"
run_native automate assert --absent --timeout-ms 5000 'view @w[0-9]+/compose-canvas'

run_native automate focus mail-canvas
run_native automate shortcut mail.new-window
run_native automate assert --timeout-ms 5000 'view @w[0-9]+/inbox-canvas-3'

run_native automate widget-click mail-canvas "${microsoft_message_id}"
run_native automate assert --timeout-ms 5000 \
  'role=button name="Back to inbox"' \
  'role=text name="Microsoft follow up"'
run_native automate assert --absent --timeout-ms 5000 'window @w[0-9]+ "Microsoft follow up"'
back_id="$(widget_id button 'Back to inbox')"
[[ -n "${back_id}" ]]
run_native automate widget-click mail-canvas "${back_id}"
run_native automate focus mail-canvas
run_native automate widget-key mail-canvas arrowdown
run_native automate assert --timeout-ms 5000 'role=listitem name="Contract redlines,.*selected'
run_native automate widget-key mail-canvas enter
run_native automate assert --timeout-ms 5000 \
  'role=button name="Back to inbox"' \
  'role=text name="Contract redlines"'

if [[ ! -s "${SCREENSHOT_PATH}" ]]; then
  echo "Automation screenshot was not created: ${SCREENSHOT_PATH}" >&2
  exit 1
fi
if [[ ! -s "${COMPOSE_SCREENSHOT_PATH}" ]]; then
  echo "Compose automation screenshot was not created: ${COMPOSE_SCREENSHOT_PATH}" >&2
  exit 1
fi
if [[ ! -s "${INBOX_WINDOW_SCREENSHOT_PATH}" ]]; then
  echo "Inbox-window automation screenshot was not created: ${INBOX_WINDOW_SCREENSHOT_PATH}" >&2
  exit 1
fi

echo "Native SDK automation smoke test passed."
echo "Screenshot: ${SCREENSHOT_PATH}"
echo "Compose screenshot: ${COMPOSE_SCREENSHOT_PATH}"
echo "Inbox window screenshot: ${INBOX_WINDOW_SCREENSHOT_PATH}"
