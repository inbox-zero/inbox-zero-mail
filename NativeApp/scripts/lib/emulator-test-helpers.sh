#!/usr/bin/env bash

# Shared helpers for live emulate.dev contract tests. The caller owns strict
# shell mode so these functions can also be sourced from focused diagnostics.

fail() {
  echo "emulator-e2e: ERROR: $*" >&2
  exit 1
}

section() {
  echo
  echo "==> $*"
}

known_gap() {
  echo "emulator-e2e: KNOWN EMULATOR GAP: $*" >&2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

init_http_workspace() {
  EMULATOR_E2E_TMP="$(mktemp -d "${TMPDIR:-/tmp}/inbox-zero-emulator-e2e.XXXXXX")"
  EMULATOR_E2E_REQUEST_NUMBER=0
  export EMULATOR_E2E_TMP EMULATOR_E2E_REQUEST_NUMBER
}

cleanup_http_workspace() {
  if [[ -n "${EMULATOR_E2E_TMP:-}" && -d "${EMULATOR_E2E_TMP}" ]]; then
    rm -r -- "${EMULATOR_E2E_TMP}"
  fi
}

# Usage: request EXPECTED_STATUS LABEL curl-arguments...
# Sets HTTP_BODY_FILE and HTTP_STATUS for the assertion helpers below.
request() {
  local expected_status="$1"
  local label="$2"
  shift 2

  EMULATOR_E2E_REQUEST_NUMBER=$((EMULATOR_E2E_REQUEST_NUMBER + 1))
  HTTP_BODY_FILE="${EMULATOR_E2E_TMP}/response-${EMULATOR_E2E_REQUEST_NUMBER}.body"
  local headers_file="${EMULATOR_E2E_TMP}/response-${EMULATOR_E2E_REQUEST_NUMBER}.headers"
  HTTP_STATUS="$(curl -sS -D "${headers_file}" -o "${HTTP_BODY_FILE}" -w '%{http_code}' "$@")" \
    || fail "${label}: curl failed"
  HTTP_HEADERS_FILE="${headers_file}"
  export HTTP_BODY_FILE HTTP_HEADERS_FILE HTTP_STATUS

  if [[ "${HTTP_STATUS}" != "${expected_status}" ]]; then
    echo "emulator-e2e: ${label}: expected HTTP ${expected_status}, got ${HTTP_STATUS}" >&2
    sed -n '1,40p' "${HTTP_HEADERS_FILE}" >&2
    sed -n '1,120p' "${HTTP_BODY_FILE}" >&2
    exit 1
  fi
}

bearer_request() {
  local expected_status="$1"
  local label="$2"
  local token="$3"
  shift 3
  request "${expected_status}" "${label}" -H "Authorization: Bearer ${token}" "$@"
}

json_value() {
  local file="$1"
  local expression="$2"
  JSON_FILE="${file}" JSON_EXPRESSION="${expression}" node <<'NODE'
const fs = require('node:fs');
const data = JSON.parse(fs.readFileSync(process.env.JSON_FILE, 'utf8'));
const value = Function('data', `return (${process.env.JSON_EXPRESSION});`)(data);
if (value === undefined || value === null) process.exit(2);
if (typeof value === 'object') process.stdout.write(JSON.stringify(value));
else process.stdout.write(String(value));
NODE
}

assert_json() {
  local file="$1"
  local description="$2"
  local expression="$3"
  JSON_FILE="${file}" \
    JSON_DESCRIPTION="${description}" \
    JSON_EXPRESSION="${expression}" \
    JSON_EXPECTED="${JSON_EXPECTED:-}" \
    JSON_EXPECTED_NAME="${JSON_EXPECTED_NAME:-}" \
    JSON_DIRECT_SUBJECT="${JSON_DIRECT_SUBJECT:-}" \
    JSON_FORWARD_SUBJECT="${JSON_FORWARD_SUBJECT:-}" \
    JSON_RUN_ID="${JSON_RUN_ID:-}" \
    JSON_CONVERSATION="${JSON_CONVERSATION:-}" \
    node <<'NODE'
const fs = require('node:fs');
const data = JSON.parse(fs.readFileSync(process.env.JSON_FILE, 'utf8'));
let passed = false;
try {
  passed = Boolean(Function('data', `return (${process.env.JSON_EXPRESSION});`)(data));
} catch (error) {
  console.error(`emulator-e2e: assertion threw (${process.env.JSON_DESCRIPTION}): ${error.message}`);
  process.exit(1);
}
if (!passed) {
  console.error(`emulator-e2e: assertion failed: ${process.env.JSON_DESCRIPTION}`);
  console.error(JSON.stringify(data, null, 2).slice(0, 8000));
  process.exit(1);
}
NODE
}

assert_json_with_expected() {
  local file="$1"
  local description="$2"
  local expected="$3"
  local expression="$4"
  JSON_EXPECTED="${expected}" assert_json "${file}" "${description}" "${expression}"
}

header_value() {
  local file="$1"
  local header_name="$2"
  awk -v wanted="${header_name}" '
    index(tolower($0), tolower(wanted) ":") == 1 {
      sub("^[^:]*:[[:space:]]*", "")
      sub("\r$", "")
      value = $0
    }
    END { print value }
  ' "${file}"
}

url_query_value() {
  local url="$1"
  local key="$2"
  URL_VALUE="${url}" URL_KEY="${key}" node <<'NODE'
const url = new URL(process.env.URL_VALUE);
const value = url.searchParams.get(process.env.URL_KEY);
if (value === null) process.exit(2);
process.stdout.write(value);
NODE
}

base64url_sha256() {
  VALUE="$1" node <<'NODE'
const crypto = require('node:crypto');
process.stdout.write(crypto.createHash('sha256').update(process.env.VALUE).digest('base64url'));
NODE
}

gmail_raw_message() {
  local subject="$1"
  local body="$2"
  local to_address="$3"
  local extra_headers="${4:-}"
  local from_header="${5:-Alpha Inbox <alpha.inbox@example.com>}"
  GMAIL_SUBJECT="${subject}" \
    GMAIL_BODY="${body}" \
    GMAIL_TO="${to_address}" \
    GMAIL_EXTRA_HEADERS="${extra_headers}" \
    GMAIL_FROM="${from_header}" \
    node <<'NODE'
const headers = [
  `From: ${process.env.GMAIL_FROM}`,
  `To: ${process.env.GMAIL_TO}`,
  `Subject: ${process.env.GMAIL_SUBJECT}`,
  'MIME-Version: 1.0',
  'Content-Type: text/plain; charset=utf-8',
  'Content-Transfer-Encoding: 8bit',
];
if (process.env.GMAIL_EXTRA_HEADERS) {
  headers.splice(3, 0, ...process.env.GMAIL_EXTRA_HEADERS.split('\n'));
}
const raw = `${headers.join('\r\n')}\r\n\r\n${process.env.GMAIL_BODY}\r\n`;
process.stdout.write(Buffer.from(raw).toString('base64url'));
NODE
}

gmail_message_json() {
  local raw="$1"
  local thread_id="${2:-}"
  GMAIL_RAW="${raw}" GMAIL_THREAD_ID="${thread_id}" node <<'NODE'
const message = { raw: process.env.GMAIL_RAW };
if (process.env.GMAIL_THREAD_ID) message.threadId = process.env.GMAIL_THREAD_ID;
process.stdout.write(JSON.stringify(message));
NODE
}

gmail_draft_json() {
  local raw="$1"
  local thread_id="${2:-}"
  GMAIL_RAW="${raw}" GMAIL_THREAD_ID="${thread_id}" node <<'NODE'
const message = { raw: process.env.GMAIL_RAW };
if (process.env.GMAIL_THREAD_ID) message.threadId = process.env.GMAIL_THREAD_ID;
process.stdout.write(JSON.stringify({ message }));
NODE
}

graph_message_json() {
  local subject="$1"
  local body="$2"
  local to_address="$3"
  GRAPH_SUBJECT="${subject}" GRAPH_BODY="${body}" GRAPH_TO="${to_address}" node <<'NODE'
process.stdout.write(JSON.stringify({
  subject: process.env.GRAPH_SUBJECT,
  body: { contentType: 'text', content: process.env.GRAPH_BODY },
  toRecipients: [{ emailAddress: { address: process.env.GRAPH_TO } }],
  ccRecipients: [],
  bccRecipients: [],
}));
NODE
}
