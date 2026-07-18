#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
AUTOMATION_DIR="${APP_DIR}/.zig-cache/native-sdk-automation"
APP_LOG="${TMPDIR:-/tmp}/inbox-zero-windows-wine.log"

if [[ -z "${DISPLAY:-}" ]]; then
  exec xvfb-run -a --server-args="-screen 0 1600x900x24" "$0" "$@"
fi

export WINEPREFIX="${WINEPREFIX:-${APP_DIR}/.zig-cache/wineprefix}"
export WINEDEBUG="${WINEDEBUG:--all}"

app_pid=""
cleanup() {
  if [[ -n "${app_pid}" ]]; then
    kill "${app_pid}" >/dev/null 2>&1 || true
  fi
  wineserver -k >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() {
  echo "Windows Wine smoke failed: $1" >&2
  if [[ -f "${AUTOMATION_DIR}/snapshot.txt" ]]; then
    tail -40 "${AUTOMATION_DIR}/snapshot.txt" >&2
  fi
  tail -80 "${APP_LOG}" >&2 2>/dev/null || true
  exit 1
}

run_native() {
  npx --yes @native-sdk/cli@0.5.3 "$@"
}

cd "${APP_DIR}"
[[ -s zig-out/bin/inbox-zero-mail-native.exe ]] || fail "Windows executable is missing"

mkdir -p "$(dirname -- "${WINEPREFIX}")"
# Wine can return a non-zero status while still completing first-run prefix
# initialization on a headless runner (for example when optional wine32 is
# absent). The readiness assertion below is the authoritative launch check.
wineboot --init >"${APP_LOG}" 2>&1 || true
wineserver --wait >/dev/null 2>&1 || true
rm -rf "${AUTOMATION_DIR}"
wine zig-out/bin/inbox-zero-mail-native.exe >>"${APP_LOG}" 2>&1 &
app_pid=$!

run_native automate wait --timeout-ms 180000 >/dev/null || fail "app did not publish an automation snapshot"
run_native automate assert --timeout-ms 60000 \
  'gpu_backend=software' \
  'gpu_nonblank=true' \
  'Combined inbox' \
  'All accounts' || fail "Win32 canvas did not render"

snapshot="${AUTOMATION_DIR}/snapshot.txt"
archive_id="$(sed -n 's/.*#\([0-9][0-9]*\) role=button name="archive".*/\1/p' "${snapshot}" | head -1)"
alpha_id="$(sed -n 's/.*#\([0-9][0-9]*\) role=listitem name="Alpha Inbox".*/\1/p' "${snapshot}" | head -1)"
[[ -n "${archive_id}" && -n "${alpha_id}" ]] || fail "interactive widgets were not published"

run_native automate widget-action mail-canvas "${archive_id}" press >/dev/null
run_native automate assert --timeout-ms 5000 'role=button name="archive".*selected' >/dev/null \
  || fail "filter action did not update state"
run_native automate widget-click mail-canvas "${alpha_id}" >/dev/null
run_native automate assert --timeout-ms 5000 'role=listitem name="Alpha Inbox".*selected' >/dev/null \
  || fail "account click did not update state"
run_native automate widget-key mail-canvas / >/dev/null
run_native automate assert --timeout-ms 5000 'role=textbox name="Search mail".*focused=true' >/dev/null \
  || fail "keyboard shortcut did not focus search"

run_native automate screenshot mail-canvas >/dev/null
[[ -s "${AUTOMATION_DIR}/screenshot-mail-canvas.png" ]] || fail "screenshot is empty"

echo "Windows Wine smoke passed: Win32 render, account/filter input, keyboard focus, and screenshot."
