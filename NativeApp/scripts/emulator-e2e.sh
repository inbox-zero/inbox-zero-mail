#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=lib/emulator-test-helpers.sh
source "${SCRIPT_DIR}/lib/emulator-test-helpers.sh"

GOOGLE_BASE_URL="${INBOX_ZERO_GOOGLE_BASE_URL:-http://localhost:4402}"
MICROSOFT_BASE_URL="${INBOX_ZERO_MICROSOFT_BASE_URL:-http://localhost:4403}"
GOOGLE_CLIENT_ID="inbox-zero-mail-dev"
GOOGLE_CLIENT_SECRET="inbox-zero-google-secret"
MICROSOFT_CLIENT_ID="inbox-zero-mail-dev"
MICROSOFT_CLIENT_SECRET="inbox-zero-microsoft-secret"
PINNED_EMULATE_VERSION="$(sed -n 's/.*@inbox-zero\/emulate@\([^ ]*\) start.*/\1/p' "${REPO_DIR}/compose.yaml" | head -1)"
EMULATE_VERSION="${INBOX_ZERO_EMULATE_VERSION:-${PINNED_EMULATE_VERSION}}"
[[ -n "${EMULATE_VERSION}" ]] || fail "could not determine the pinned @inbox-zero/emulate version"
GOOGLE_REDIRECT_URI="${INBOX_ZERO_GOOGLE_REDIRECT_URI:-${GOOGLE_BASE_URL}/oauth/google}"
MICROSOFT_REDIRECT_URI="${INBOX_ZERO_MICROSOFT_REDIRECT_URI:-${MICROSOFT_BASE_URL}/oauth/microsoft}"
RUN_ID="${INBOX_ZERO_E2E_RUN_ID:-native-e2e-$(date +%s)-$$}"
PKCE_VERIFIER="inbox-zero-native-sdk-e2e-verifier-0123456789-ABCDEFGHIJKLMNOPQRSTUVWXYZ"
PKCE_CHALLENGE="$(base64url_sha256 "${PKCE_VERIFIER}")"
GOOGLE_SCOPE="openid email profile https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/gmail.send"
MICROSOFT_SCOPE="openid email profile offline_access User.Read Mail.ReadWrite Mail.Send"

require_command curl
require_command node
require_command awk
init_http_workspace
trap cleanup_http_workspace EXIT

wait_for_emulator() {
  local attempt=1
  while [[ "${attempt}" -le 30 ]]; do
    if curl -sf "${GOOGLE_BASE_URL}/o/oauth2/v2/auth?client_id=${GOOGLE_CLIENT_ID}&redirect_uri=${GOOGLE_REDIRECT_URI}&response_type=code&scope=openid%20email" >/dev/null \
      && curl -sf "${MICROSOFT_BASE_URL}/oauth2/v2.0/authorize?client_id=${MICROSOFT_CLIENT_ID}&redirect_uri=${MICROSOFT_REDIRECT_URI}&response_type=code&scope=openid%20email" >/dev/null; then
      return
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  fail "Google and Microsoft emulators did not become ready at ${GOOGLE_BASE_URL} and ${MICROSOFT_BASE_URL}"
}

google_authorization_code() {
  local state="$1"
  request 302 "Google authorization callback" \
    -X POST "${GOOGLE_BASE_URL}/o/oauth2/v2/auth/callback" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'email=alpha.inbox@example.com' \
    --data-urlencode "redirect_uri=${GOOGLE_REDIRECT_URI}" \
    --data-urlencode "scope=${GOOGLE_SCOPE}" \
    --data-urlencode "client_id=${GOOGLE_CLIENT_ID}" \
    --data-urlencode "state=${state}" \
    --data-urlencode "code_challenge=${PKCE_CHALLENGE}" \
    --data-urlencode 'code_challenge_method=S256'
  local location
  location="$(header_value "${HTTP_HEADERS_FILE}" location)"
  [[ -n "${location}" ]] || fail "Google callback omitted Location"
  [[ "$(url_query_value "${location}" state)" == "${state}" ]] || fail "Google callback did not round-trip OAuth state"
  GOOGLE_AUTH_CODE="$(url_query_value "${location}" code)"
}

microsoft_authorization_code() {
  local state="$1"
  request 302 "Microsoft authorization callback" \
    -X POST "${MICROSOFT_BASE_URL}/oauth2/v2.0/authorize/callback" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'email=gamma.outlook@example.com' \
    --data-urlencode "redirect_uri=${MICROSOFT_REDIRECT_URI}" \
    --data-urlencode "scope=${MICROSOFT_SCOPE}" \
    --data-urlencode "client_id=${MICROSOFT_CLIENT_ID}" \
    --data-urlencode "state=${state}" \
    --data-urlencode 'response_mode=query' \
    --data-urlencode "code_challenge=${PKCE_CHALLENGE}" \
    --data-urlencode 'code_challenge_method=S256'
  local location
  location="$(header_value "${HTTP_HEADERS_FILE}" location)"
  [[ -n "${location}" ]] || fail "Microsoft callback omitted Location"
  [[ "$(url_query_value "${location}" state)" == "${state}" ]] || fail "Microsoft callback did not round-trip OAuth state"
  MICROSOFT_AUTH_CODE="$(url_query_value "${location}" code)"
}

run_oauth_contracts() {
  section "OAuth 2.0 authorization code, PKCE, profile, and refresh"

  request 401 "Google profile rejects missing auth" "${GOOGLE_BASE_URL}/oauth2/v2/userinfo"
  assert_json "${HTTP_BODY_FILE}" "Google missing-auth response is invalid_token" 'data.error === "invalid_token"'
  request 401 "Microsoft profile rejects missing auth" "${MICROSOFT_BASE_URL}/v1.0/me"
  assert_json "${HTTP_BODY_FILE}" "Microsoft missing-auth response is InvalidAuthenticationToken" 'data.error?.code === "InvalidAuthenticationToken"'

  google_authorization_code "google-${RUN_ID}"
  local consumed_google_code="${GOOGLE_AUTH_CODE}"
  request 200 "Google exchanges S256 authorization code" \
    -X POST "${GOOGLE_BASE_URL}/oauth2/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'grant_type=authorization_code' \
    --data-urlencode "code=${GOOGLE_AUTH_CODE}" \
    --data-urlencode "client_id=${GOOGLE_CLIENT_ID}" \
    --data-urlencode "client_secret=${GOOGLE_CLIENT_SECRET}" \
    --data-urlencode "redirect_uri=${GOOGLE_REDIRECT_URI}" \
    --data-urlencode "code_verifier=${PKCE_VERIFIER}"
  GOOGLE_ACCESS_TOKEN="$(json_value "${HTTP_BODY_FILE}" 'data.access_token')"
  GOOGLE_REFRESH_TOKEN="$(json_value "${HTTP_BODY_FILE}" 'data.refresh_token')"
  assert_json "${HTTP_BODY_FILE}" "Google token contains requested mail scopes" 'data.scope.includes("gmail.modify") && data.scope.includes("gmail.send")'

  request 400 "Google authorization code is single use" \
    -X POST "${GOOGLE_BASE_URL}/oauth2/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'grant_type=authorization_code' \
    --data-urlencode "code=${consumed_google_code}" \
    --data-urlencode "client_id=${GOOGLE_CLIENT_ID}" \
    --data-urlencode "client_secret=${GOOGLE_CLIENT_SECRET}" \
    --data-urlencode "redirect_uri=${GOOGLE_REDIRECT_URI}" \
    --data-urlencode "code_verifier=${PKCE_VERIFIER}"
  assert_json "${HTTP_BODY_FILE}" "Google code reuse returns invalid_grant" 'data.error === "invalid_grant"'

  google_authorization_code "google-pkce-error-${RUN_ID}"
  request 400 "Google rejects an invalid PKCE verifier" \
    -X POST "${GOOGLE_BASE_URL}/oauth2/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'grant_type=authorization_code' \
    --data-urlencode "code=${GOOGLE_AUTH_CODE}" \
    --data-urlencode "client_id=${GOOGLE_CLIENT_ID}" \
    --data-urlencode "client_secret=${GOOGLE_CLIENT_SECRET}" \
    --data-urlencode "redirect_uri=${GOOGLE_REDIRECT_URI}" \
    --data-urlencode 'code_verifier=incorrect-pkce-verifier-012345678901234567890123456789'
  assert_json "${HTTP_BODY_FILE}" "Google invalid PKCE verifier returns invalid_grant" 'data.error === "invalid_grant"'

  bearer_request 200 "Google profile resolves OAuth user" "${GOOGLE_ACCESS_TOKEN}" "${GOOGLE_BASE_URL}/oauth2/v2/userinfo"
  assert_json "${HTTP_BODY_FILE}" "Google profile is the selected account" 'data.email === "alpha.inbox@example.com" && data.name === "Alpha Inbox"'

  request 200 "Google refreshes access token" \
    -X POST "${GOOGLE_BASE_URL}/oauth2/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'grant_type=refresh_token' \
    --data-urlencode "refresh_token=${GOOGLE_REFRESH_TOKEN}" \
    --data-urlencode "client_id=${GOOGLE_CLIENT_ID}" \
    --data-urlencode "client_secret=${GOOGLE_CLIENT_SECRET}"
  local refreshed_google_access
  refreshed_google_access="$(json_value "${HTTP_BODY_FILE}" 'data.access_token')"
  [[ "${refreshed_google_access}" != "${GOOGLE_ACCESS_TOKEN}" ]] || fail "Google refresh reused the access token"
  assert_json "${HTTP_BODY_FILE}" "Google refresh preserves scopes and does not rotate refresh token" 'data.scope.includes("gmail.modify") && data.refresh_token === undefined'
  GOOGLE_ACCESS_TOKEN="${refreshed_google_access}"

  microsoft_authorization_code "microsoft-${RUN_ID}"
  local consumed_microsoft_code="${MICROSOFT_AUTH_CODE}"
  request 200 "Microsoft exchanges S256 authorization code" \
    -X POST "${MICROSOFT_BASE_URL}/oauth2/v2.0/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'grant_type=authorization_code' \
    --data-urlencode "code=${MICROSOFT_AUTH_CODE}" \
    --data-urlencode "client_id=${MICROSOFT_CLIENT_ID}" \
    --data-urlencode "client_secret=${MICROSOFT_CLIENT_SECRET}" \
    --data-urlencode "redirect_uri=${MICROSOFT_REDIRECT_URI}" \
    --data-urlencode "code_verifier=${PKCE_VERIFIER}"
  MICROSOFT_ACCESS_TOKEN="$(json_value "${HTTP_BODY_FILE}" 'data.access_token')"
  MICROSOFT_REFRESH_TOKEN="$(json_value "${HTTP_BODY_FILE}" 'data.refresh_token')"
  assert_json "${HTTP_BODY_FILE}" "Microsoft token includes read/write/send and offline scopes" 'data.scope.includes("Mail.ReadWrite") && data.scope.includes("Mail.Send") && data.scope.includes("offline_access")'

  request 400 "Microsoft authorization code is single use" \
    -X POST "${MICROSOFT_BASE_URL}/oauth2/v2.0/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'grant_type=authorization_code' \
    --data-urlencode "code=${consumed_microsoft_code}" \
    --data-urlencode "client_id=${MICROSOFT_CLIENT_ID}" \
    --data-urlencode "client_secret=${MICROSOFT_CLIENT_SECRET}" \
    --data-urlencode "redirect_uri=${MICROSOFT_REDIRECT_URI}" \
    --data-urlencode "code_verifier=${PKCE_VERIFIER}"
  assert_json "${HTTP_BODY_FILE}" "Microsoft code reuse returns invalid_grant" 'data.error === "invalid_grant"'

  microsoft_authorization_code "microsoft-pkce-error-${RUN_ID}"
  request 400 "Microsoft rejects an invalid PKCE verifier" \
    -X POST "${MICROSOFT_BASE_URL}/oauth2/v2.0/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'grant_type=authorization_code' \
    --data-urlencode "code=${MICROSOFT_AUTH_CODE}" \
    --data-urlencode "client_id=${MICROSOFT_CLIENT_ID}" \
    --data-urlencode "client_secret=${MICROSOFT_CLIENT_SECRET}" \
    --data-urlencode "redirect_uri=${MICROSOFT_REDIRECT_URI}" \
    --data-urlencode 'code_verifier=incorrect-pkce-verifier-012345678901234567890123456789'
  assert_json "${HTTP_BODY_FILE}" "Microsoft invalid PKCE verifier returns invalid_grant" 'data.error === "invalid_grant"'

  bearer_request 200 "Microsoft profile resolves OAuth user" "${MICROSOFT_ACCESS_TOKEN}" "${MICROSOFT_BASE_URL}/v1.0/me"
  assert_json "${HTTP_BODY_FILE}" "Microsoft profile is the selected account" 'data.mail === "gamma.outlook@example.com" && data.displayName === "Gamma Outlook"'

  local old_microsoft_refresh="${MICROSOFT_REFRESH_TOKEN}"
  request 200 "Microsoft refreshes and rotates tokens" \
    -X POST "${MICROSOFT_BASE_URL}/oauth2/v2.0/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'grant_type=refresh_token' \
    --data-urlencode "refresh_token=${MICROSOFT_REFRESH_TOKEN}" \
    --data-urlencode "client_id=${MICROSOFT_CLIENT_ID}"
  local refreshed_microsoft_access
  refreshed_microsoft_access="$(json_value "${HTTP_BODY_FILE}" 'data.access_token')"
  MICROSOFT_REFRESH_TOKEN="$(json_value "${HTTP_BODY_FILE}" 'data.refresh_token')"
  [[ "${refreshed_microsoft_access}" != "${MICROSOFT_ACCESS_TOKEN}" ]] || fail "Microsoft refresh reused the access token"
  [[ "${MICROSOFT_REFRESH_TOKEN}" != "${old_microsoft_refresh}" ]] || fail "Microsoft refresh token did not rotate"
  MICROSOFT_ACCESS_TOKEN="${refreshed_microsoft_access}"

  request 400 "Microsoft rejects a rotated refresh token" \
    -X POST "${MICROSOFT_BASE_URL}/oauth2/v2.0/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'grant_type=refresh_token' \
    --data-urlencode "refresh_token=${old_microsoft_refresh}" \
    --data-urlencode "client_id=${MICROSOFT_CLIENT_ID}"
  assert_json "${HTTP_BODY_FILE}" "Old Microsoft refresh token returns invalid_grant" 'data.error === "invalid_grant"'
}

gmail_header_assertion() {
  local file="$1"
  local name="$2"
  local expected="$3"
  JSON_EXPECTED_NAME="${name}" JSON_EXPECTED="${expected}" assert_json "${file}" "Gmail ${name} header is ${expected}" \
    '[data, data.message, ...(data.messages || [])].some((item) => item?.payload?.headers?.some((header) => header.name.toLowerCase() === process.env.JSON_EXPECTED_NAME.toLowerCase() && header.value === process.env.JSON_EXPECTED))'
}

run_gmail_contracts() {
  section "Gmail live read, mutation, draft, send, reply, reply-all, and forward"
  local auth=(-H "Authorization: Bearer ${GOOGLE_ACCESS_TOKEN}")
  local json=(-H 'Content-Type: application/json')
  local source_subject="${RUN_ID} Gmail source"
  local direct_subject="${RUN_ID} Gmail direct"
  local draft_subject="${RUN_ID} Gmail draft"
  local updated_draft_subject="${RUN_ID} Gmail draft updated"
  local sent_draft_subject="${RUN_ID} Gmail draft sent"
  local forward_subject="Fwd: ${RUN_ID} Gmail source"

  bearer_request 200 "Gmail lists threads" "${GOOGLE_ACCESS_TOKEN}" \
    "${GOOGLE_BASE_URL}/gmail/v1/users/me/threads?maxResults=128&includeSpamTrash=true"
  assert_json "${HTTP_BODY_FILE}" "Gmail thread listing is an array" 'Array.isArray(data.threads)'
  bearer_request 200 "Gmail lists drafts" "${GOOGLE_ACCESS_TOKEN}" \
    "${GOOGLE_BASE_URL}/gmail/v1/users/me/drafts?maxResults=50"
  assert_json "${HTTP_BODY_FILE}" "Gmail draft listing is an array or empty" 'data.drafts === undefined || Array.isArray(data.drafts)'

  local source_raw source_json
  source_raw="$(gmail_raw_message "${source_subject}" "Unique inbox source ${RUN_ID}" 'alpha.inbox@example.com' "Message-ID: <${RUN_ID}-gmail-source@example.test>" 'Ops <ops@example.com>')"
  source_json="$(gmail_message_json "${source_raw}")"
  bearer_request 200 "Gmail imports deterministic inbox source" "${GOOGLE_ACCESS_TOKEN}" \
    -X POST "${GOOGLE_BASE_URL}/gmail/v1/users/me/messages/import" "${json[@]}" --data "${source_json}"
  local gmail_source_message_id gmail_source_thread_id
  gmail_source_message_id="$(json_value "${HTTP_BODY_FILE}" 'data.id')"
  gmail_source_thread_id="$(json_value "${HTTP_BODY_FILE}" 'data.threadId')"
  assert_json "${HTTP_BODY_FILE}" "Imported source starts in inbox and unread" 'data.labelIds.includes("INBOX") && data.labelIds.includes("UNREAD")'

  bearer_request 200 "Gmail fetches source thread detail" "${GOOGLE_ACCESS_TOKEN}" \
    "${GOOGLE_BASE_URL}/gmail/v1/users/me/threads/${gmail_source_thread_id}?format=full"
  assert_json "${HTTP_BODY_FILE}" "Gmail detail contains imported source" 'data.messages.length === 1'
  gmail_header_assertion "${HTTP_BODY_FILE}" Subject "${source_subject}"

  local reply_raw reply_json
  reply_raw="$(gmail_raw_message "Re: ${source_subject}" "Unique reply ${RUN_ID}" 'ops@example.com' "In-Reply-To: <${RUN_ID}-gmail-source@example.test>
References: <${RUN_ID}-gmail-source@example.test>")"
  reply_json="$(gmail_message_json "${reply_raw}" "${gmail_source_thread_id}")"
  bearer_request 200 "Gmail sends threaded reply" "${GOOGLE_ACCESS_TOKEN}" \
    -X POST "${GOOGLE_BASE_URL}/gmail/v1/users/me/messages/send" "${json[@]}" --data "${reply_json}"
  assert_json_with_expected "${HTTP_BODY_FILE}" "Gmail reply preserves thread ID" "${gmail_source_thread_id}" 'data.threadId === process.env.JSON_EXPECTED'

  local reply_all_raw reply_all_json
  reply_all_raw="$(gmail_raw_message "Re: ${source_subject}" "Unique reply-all ${RUN_ID}" 'ops@example.com' "Cc: teammate@example.com
In-Reply-To: <${RUN_ID}-gmail-source@example.test>
References: <${RUN_ID}-gmail-source@example.test>")"
  reply_all_json="$(gmail_message_json "${reply_all_raw}" "${gmail_source_thread_id}")"
  bearer_request 200 "Gmail sends threaded reply-all" "${GOOGLE_ACCESS_TOKEN}" \
    -X POST "${GOOGLE_BASE_URL}/gmail/v1/users/me/messages/send" "${json[@]}" --data "${reply_all_json}"
  assert_json_with_expected "${HTTP_BODY_FILE}" "Gmail reply-all preserves thread ID" "${gmail_source_thread_id}" 'data.threadId === process.env.JSON_EXPECTED'

  bearer_request 200 "Gmail thread contains source and two replies" "${GOOGLE_ACCESS_TOKEN}" \
    "${GOOGLE_BASE_URL}/gmail/v1/users/me/threads/${gmail_source_thread_id}?format=full"
  assert_json "${HTTP_BODY_FILE}" "Gmail threaded sends appended two messages" 'data.messages.length === 3'

  bearer_request 200 "Gmail marks thread read" "${GOOGLE_ACCESS_TOKEN}" \
    -X POST "${GOOGLE_BASE_URL}/gmail/v1/users/me/threads/${gmail_source_thread_id}/modify" "${json[@]}" \
    --data '{"addLabelIds":[],"removeLabelIds":["UNREAD"]}'
  assert_json "${HTTP_BODY_FILE}" "Gmail read mutation removes UNREAD" 'data.messages.every((message) => !message.labelIds.includes("UNREAD"))'
  bearer_request 200 "Gmail stars thread" "${GOOGLE_ACCESS_TOKEN}" \
    -X POST "${GOOGLE_BASE_URL}/gmail/v1/users/me/threads/${gmail_source_thread_id}/modify" "${json[@]}" \
    --data '{"addLabelIds":["STARRED"],"removeLabelIds":[]}'
  assert_json "${HTTP_BODY_FILE}" "Gmail star mutation adds STARRED" 'data.messages.every((message) => message.labelIds.includes("STARRED"))'
  bearer_request 200 "Gmail archives thread" "${GOOGLE_ACCESS_TOKEN}" \
    -X POST "${GOOGLE_BASE_URL}/gmail/v1/users/me/threads/${gmail_source_thread_id}/modify" "${json[@]}" \
    --data '{"addLabelIds":[],"removeLabelIds":["INBOX"]}'
  assert_json "${HTTP_BODY_FILE}" "Gmail archive mutation removes INBOX" 'data.messages.every((message) => !message.labelIds.includes("INBOX"))'
  bearer_request 200 "Gmail trashes thread" "${GOOGLE_ACCESS_TOKEN}" \
    -X POST "${GOOGLE_BASE_URL}/gmail/v1/users/me/threads/${gmail_source_thread_id}/trash" "${json[@]}" --data '{}'
  assert_json "${HTTP_BODY_FILE}" "Gmail trash mutation adds TRASH" 'data.messages.every((message) => message.labelIds.includes("TRASH"))'

  local direct_raw direct_json
  direct_raw="$(gmail_raw_message "${direct_subject}" "Unique direct send ${RUN_ID}" 'recipient@example.com')"
  direct_json="$(gmail_message_json "${direct_raw}")"
  bearer_request 200 "Gmail sends new mail directly" "${GOOGLE_ACCESS_TOKEN}" \
    -X POST "${GOOGLE_BASE_URL}/gmail/v1/users/me/messages/send" "${json[@]}" --data "${direct_json}"
  local gmail_direct_thread_id
  gmail_direct_thread_id="$(json_value "${HTTP_BODY_FILE}" 'data.threadId')"
  assert_json "${HTTP_BODY_FILE}" "Gmail direct send is in Sent" 'data.labelIds.includes("SENT")'

  local forward_raw forward_json
  forward_raw="$(gmail_raw_message "${forward_subject}" "Forwarded source body ${RUN_ID}" 'forward-recipient@example.com')"
  forward_json="$(gmail_message_json "${forward_raw}")"
  bearer_request 200 "Gmail sends forward as a new conversation" "${GOOGLE_ACCESS_TOKEN}" \
    -X POST "${GOOGLE_BASE_URL}/gmail/v1/users/me/messages/send" "${json[@]}" --data "${forward_json}"
  local gmail_forward_thread_id
  gmail_forward_thread_id="$(json_value "${HTTP_BODY_FILE}" 'data.threadId')"
  [[ "${gmail_forward_thread_id}" != "${gmail_source_thread_id}" ]] || fail "Gmail forward stayed in the source thread"

  local draft_raw draft_json
  draft_raw="$(gmail_raw_message "${draft_subject}" "Initial draft body ${RUN_ID}" 'draft-recipient@example.com')"
  draft_json="$(gmail_draft_json "${draft_raw}")"
  bearer_request 200 "Gmail creates provider draft" "${GOOGLE_ACCESS_TOKEN}" \
    -X POST "${GOOGLE_BASE_URL}/gmail/v1/users/me/drafts" "${json[@]}" --data "${draft_json}"
  local gmail_draft_id
  gmail_draft_id="$(json_value "${HTTP_BODY_FILE}" 'data.id')"

  bearer_request 200 "Gmail lists created provider draft" "${GOOGLE_ACCESS_TOKEN}" \
    "${GOOGLE_BASE_URL}/gmail/v1/users/me/drafts?maxResults=50"
  assert_json_with_expected "${HTTP_BODY_FILE}" "Gmail draft list contains created draft" "${gmail_draft_id}" \
    'data.drafts.some((draft) => draft.id === process.env.JSON_EXPECTED)'
  bearer_request 200 "Gmail fetches provider draft detail" "${GOOGLE_ACCESS_TOKEN}" \
    "${GOOGLE_BASE_URL}/gmail/v1/users/me/drafts/${gmail_draft_id}?format=full"
  gmail_header_assertion "${HTTP_BODY_FILE}" Subject "${draft_subject}"

  local updated_draft_raw updated_draft_json
  updated_draft_raw="$(gmail_raw_message "${updated_draft_subject}" "Updated draft body ${RUN_ID}" 'draft-recipient@example.com')"
  updated_draft_json="$(gmail_draft_json "${updated_draft_raw}")"
  bearer_request 200 "Gmail updates provider draft" "${GOOGLE_ACCESS_TOKEN}" \
    -X PUT "${GOOGLE_BASE_URL}/gmail/v1/users/me/drafts/${gmail_draft_id}" "${json[@]}" --data "${updated_draft_json}"
  gmail_header_assertion "${HTTP_BODY_FILE}" Subject "${updated_draft_subject}"
  bearer_request 204 "Gmail deletes provider draft" "${GOOGLE_ACCESS_TOKEN}" \
    -X DELETE "${GOOGLE_BASE_URL}/gmail/v1/users/me/drafts/${gmail_draft_id}"
  bearer_request 404 "Gmail deleted draft is gone" "${GOOGLE_ACCESS_TOKEN}" \
    "${GOOGLE_BASE_URL}/gmail/v1/users/me/drafts/${gmail_draft_id}?format=full"

  local sent_draft_raw sent_draft_json
  sent_draft_raw="$(gmail_raw_message "${sent_draft_subject}" "Sent draft body ${RUN_ID}" 'draft-send@example.com')"
  sent_draft_json="$(gmail_draft_json "${sent_draft_raw}")"
  bearer_request 200 "Gmail creates draft for delivery" "${GOOGLE_ACCESS_TOKEN}" \
    -X POST "${GOOGLE_BASE_URL}/gmail/v1/users/me/drafts" "${json[@]}" --data "${sent_draft_json}"
  local gmail_sent_draft_id
  gmail_sent_draft_id="$(json_value "${HTTP_BODY_FILE}" 'data.id')"
  bearer_request 200 "Gmail sends provider draft" "${GOOGLE_ACCESS_TOKEN}" \
    -X POST "${GOOGLE_BASE_URL}/gmail/v1/users/me/drafts/send" "${json[@]}" --data "{\"id\":\"${gmail_sent_draft_id}\"}"
  local gmail_sent_draft_thread_id
  gmail_sent_draft_thread_id="$(json_value "${HTTP_BODY_FILE}" 'data.threadId')"
  bearer_request 404 "Gmail sent draft no longer exists" "${GOOGLE_ACCESS_TOKEN}" \
    "${GOOGLE_BASE_URL}/gmail/v1/users/me/drafts/${gmail_sent_draft_id}?format=full"
  bearer_request 200 "Gmail fetches sent draft message" "${GOOGLE_ACCESS_TOKEN}" \
    "${GOOGLE_BASE_URL}/gmail/v1/users/me/threads/${gmail_sent_draft_thread_id}?format=full"
  gmail_header_assertion "${HTTP_BODY_FILE}" Subject "${sent_draft_subject}"

  # These unique test messages have no user value; hard deletion keeps repeated
  # local runs small and cannot affect seeded fixtures.
  bearer_request 204 "Gmail cleans source test thread" "${GOOGLE_ACCESS_TOKEN}" \
    -X DELETE "${GOOGLE_BASE_URL}/gmail/v1/users/me/threads/${gmail_source_thread_id}"
  bearer_request 204 "Gmail cleans direct-send test thread" "${GOOGLE_ACCESS_TOKEN}" \
    -X DELETE "${GOOGLE_BASE_URL}/gmail/v1/users/me/threads/${gmail_direct_thread_id}"
  bearer_request 204 "Gmail cleans forward test thread" "${GOOGLE_ACCESS_TOKEN}" \
    -X DELETE "${GOOGLE_BASE_URL}/gmail/v1/users/me/threads/${gmail_forward_thread_id}"
  bearer_request 204 "Gmail cleans sent-draft test thread" "${GOOGLE_ACCESS_TOKEN}" \
    -X DELETE "${GOOGLE_BASE_URL}/gmail/v1/users/me/threads/${gmail_sent_draft_thread_id}"
  : "${gmail_source_message_id}"
}

run_microsoft_contracts() {
  section "Microsoft Graph live read, mutation, draft, send, reply, reply-all, and forward"
  local json=(-H 'Content-Type: application/json')
  local source_subject="${RUN_ID} Graph source"
  local draft_subject="${RUN_ID} Graph draft"
  local updated_draft_subject="${RUN_ID} Graph draft updated"
  local sent_draft_subject="${RUN_ID} Graph draft sent"
  local direct_subject="${RUN_ID} Graph direct"
  local forward_subject="Fwd: ${RUN_ID} Graph source"

  local folder
  for folder in inbox archive deleteditems drafts; do
    bearer_request 200 "Graph lists ${folder} messages" "${MICROSOFT_ACCESS_TOKEN}" \
      "${MICROSOFT_BASE_URL}/v1.0/me/mailFolders/${folder}/messages?%24top=50&%24orderby=receivedDateTime%20desc"
    assert_json "${HTTP_BODY_FILE}" "Graph ${folder} listing is an array" 'Array.isArray(data.value)'
  done

  local source_json
  source_json="$(graph_message_json "${source_subject}" "Unique Graph source ${RUN_ID}" 'gamma.outlook@example.com')"
  bearer_request 201 "Graph creates source as a draft" "${MICROSOFT_ACCESS_TOKEN}" \
    -X POST "${MICROSOFT_BASE_URL}/v1.0/me/messages" "${json[@]}" --data "${source_json}"
  local graph_source_id graph_source_conversation_id
  graph_source_id="$(json_value "${HTTP_BODY_FILE}" 'data.id')"
  graph_source_conversation_id="$(json_value "${HTTP_BODY_FILE}" 'data.conversationId')"
  bearer_request 200 "Graph moves unique source into inbox" "${MICROSOFT_ACCESS_TOKEN}" \
    -X POST "${MICROSOFT_BASE_URL}/v1.0/me/messages/${graph_source_id}/move" "${json[@]}" --data '{"destinationId":"inbox"}'
  assert_json "${HTTP_BODY_FILE}" "Graph source is in inbox and not a draft" 'data.parentFolderId === "inbox" && data.isDraft === false'

  bearer_request 200 "Graph fetches message detail" "${MICROSOFT_ACCESS_TOKEN}" \
    "${MICROSOFT_BASE_URL}/v1.0/me/messages/${graph_source_id}"
  assert_json_with_expected "${HTTP_BODY_FILE}" "Graph detail has unique subject" "${source_subject}" 'data.subject === process.env.JSON_EXPECTED'
  bearer_request 200 "Graph inbox contains unique source" "${MICROSOFT_ACCESS_TOKEN}" \
    "${MICROSOFT_BASE_URL}/v1.0/me/mailFolders/inbox/messages?%24top=50&%24orderby=receivedDateTime%20desc"
  assert_json_with_expected "${HTTP_BODY_FILE}" "Graph inbox list contains source" "${graph_source_id}" \
    'data.value.some((message) => message.id === process.env.JSON_EXPECTED)'

  bearer_request 200 "Graph marks source read" "${MICROSOFT_ACCESS_TOKEN}" \
    -X PATCH "${MICROSOFT_BASE_URL}/v1.0/me/messages/${graph_source_id}" "${json[@]}" --data '{"isRead":true}'
  assert_json "${HTTP_BODY_FILE}" "Graph read mutation persisted" 'data.isRead === true'
  bearer_request 200 "Graph sends flag patch used by Native client" "${MICROSOFT_ACCESS_TOKEN}" \
    -X PATCH "${MICROSOFT_BASE_URL}/v1.0/me/messages/${graph_source_id}" "${json[@]}" --data '{"flag":{"flagStatus":"flagged"}}'
  assert_json_with_expected "${HTTP_BODY_FILE}" "Graph flag request returns the source message" "${graph_source_id}" 'data.id === process.env.JSON_EXPECTED'
  if ! JSON_FILE="${HTTP_BODY_FILE}" node -e 'const fs=require("node:fs"); const d=JSON.parse(fs.readFileSync(process.env.JSON_FILE,"utf8")); process.exit(d.flag?.flagStatus === "flagged" ? 0 : 1)' 2>/dev/null; then
    known_gap "@inbox-zero/emulate ${EMULATE_VERSION} accepts Graph flag patches but does not persist or return flagStatus"
  fi

  bearer_request 201 "Graph creates reply draft" "${MICROSOFT_ACCESS_TOKEN}" \
    -X POST "${MICROSOFT_BASE_URL}/v1.0/me/messages/${graph_source_id}/createReply"
  local graph_reply_draft_id
  graph_reply_draft_id="$(json_value "${HTTP_BODY_FILE}" 'data.id')"
  assert_json_with_expected "${HTTP_BODY_FILE}" "Graph reply draft keeps conversation" "${graph_source_conversation_id}" 'data.conversationId === process.env.JSON_EXPECTED && data.isDraft === true'
  local reply_patch
  reply_patch="$(graph_message_json "Re: ${source_subject}" "Reply draft body ${RUN_ID}" 'gamma.outlook@example.com')"
  bearer_request 200 "Graph updates reply draft" "${MICROSOFT_ACCESS_TOKEN}" \
    -X PATCH "${MICROSOFT_BASE_URL}/v1.0/me/messages/${graph_reply_draft_id}" "${json[@]}" --data "${reply_patch}"
  assert_json_with_expected "${HTTP_BODY_FILE}" "Graph reply draft body persisted" "Reply draft body ${RUN_ID}" 'data.body.content === process.env.JSON_EXPECTED'
  bearer_request 200 "Graph sends reply draft" "${MICROSOFT_ACCESS_TOKEN}" \
    -X POST "${MICROSOFT_BASE_URL}/v1.0/me/messages/${graph_reply_draft_id}/send"
  assert_json "${HTTP_BODY_FILE}" "Graph sent reply leaves drafts" 'data.isDraft === false && data.parentFolderId === "sentitems"'

  bearer_request 201 "Graph creates reply-all draft" "${MICROSOFT_ACCESS_TOKEN}" \
    -X POST "${MICROSOFT_BASE_URL}/v1.0/me/messages/${graph_source_id}/createReplyAll"
  local graph_reply_all_draft_id
  graph_reply_all_draft_id="$(json_value "${HTTP_BODY_FILE}" 'data.id')"
  local reply_all_patch
  reply_all_patch="$(graph_message_json "Re: ${source_subject}" "Reply-all draft body ${RUN_ID}" 'gamma.outlook@example.com')"
  bearer_request 200 "Graph updates reply-all draft" "${MICROSOFT_ACCESS_TOKEN}" \
    -X PATCH "${MICROSOFT_BASE_URL}/v1.0/me/messages/${graph_reply_all_draft_id}" "${json[@]}" --data "${reply_all_patch}"
  bearer_request 200 "Graph sends reply-all draft" "${MICROSOFT_ACCESS_TOKEN}" \
    -X POST "${MICROSOFT_BASE_URL}/v1.0/me/messages/${graph_reply_all_draft_id}/send"
  assert_json "${HTTP_BODY_FILE}" "Graph sent reply-all leaves drafts" 'data.isDraft === false && data.parentFolderId === "sentitems"'

  bearer_request 202 "Graph sends direct reply" "${MICROSOFT_ACCESS_TOKEN}" \
    -X POST "${MICROSOFT_BASE_URL}/v1.0/me/messages/${graph_source_id}/reply" "${json[@]}" \
    --data "{\"comment\":\"Direct reply ${RUN_ID}\"}"
  bearer_request 202 "Graph sends direct reply-all" "${MICROSOFT_ACCESS_TOKEN}" \
    -X POST "${MICROSOFT_BASE_URL}/v1.0/me/messages/${graph_source_id}/replyAll" "${json[@]}" \
    --data "{\"comment\":\"Direct reply-all ${RUN_ID}\"}"

  local forward_message forward_body
  forward_message="$(graph_message_json "${forward_subject}" "Forward body ${RUN_ID}" 'forward@example.com')"
  forward_body="$(GRAPH_MESSAGE="${forward_message}" node -e 'process.stdout.write(JSON.stringify({message:JSON.parse(process.env.GRAPH_MESSAGE)}))')"
  bearer_request 202 "Graph sends direct forward" "${MICROSOFT_ACCESS_TOKEN}" \
    -X POST "${MICROSOFT_BASE_URL}/v1.0/me/messages/${graph_source_id}/forward" "${json[@]}" --data "${forward_body}"
  bearer_request 404 "Graph exposes missing createForward route" "${MICROSOFT_ACCESS_TOKEN}" \
    -X POST "${MICROSOFT_BASE_URL}/v1.0/me/messages/${graph_source_id}/createForward"
  known_gap "@inbox-zero/emulate ${EMULATE_VERSION} lacks Graph createForward, which the Native saved-forward flow requires"

  local draft_json
  draft_json="$(graph_message_json "${draft_subject}" "Initial Graph draft ${RUN_ID}" 'draft@example.com')"
  bearer_request 201 "Graph creates provider draft" "${MICROSOFT_ACCESS_TOKEN}" \
    -X POST "${MICROSOFT_BASE_URL}/v1.0/me/messages" "${json[@]}" --data "${draft_json}"
  local graph_draft_id
  graph_draft_id="$(json_value "${HTTP_BODY_FILE}" 'data.id')"
  bearer_request 200 "Graph lists created draft" "${MICROSOFT_ACCESS_TOKEN}" \
    "${MICROSOFT_BASE_URL}/v1.0/me/mailFolders/drafts/messages?%24top=50&%24orderby=receivedDateTime%20desc"
  assert_json_with_expected "${HTTP_BODY_FILE}" "Graph draft list contains created draft" "${graph_draft_id}" \
    'data.value.some((message) => message.id === process.env.JSON_EXPECTED)'
  local updated_graph_draft
  updated_graph_draft="$(graph_message_json "${updated_draft_subject}" "Updated Graph draft ${RUN_ID}" 'draft@example.com')"
  bearer_request 200 "Graph updates provider draft" "${MICROSOFT_ACCESS_TOKEN}" \
    -X PATCH "${MICROSOFT_BASE_URL}/v1.0/me/messages/${graph_draft_id}" "${json[@]}" --data "${updated_graph_draft}"
  assert_json_with_expected "${HTTP_BODY_FILE}" "Graph draft subject update persisted" "${updated_draft_subject}" 'data.subject === process.env.JSON_EXPECTED'
  bearer_request 204 "Graph deletes provider draft" "${MICROSOFT_ACCESS_TOKEN}" \
    -X DELETE "${MICROSOFT_BASE_URL}/v1.0/me/messages/${graph_draft_id}"
  bearer_request 200 "Graph deleted draft is in Deleted Items" "${MICROSOFT_ACCESS_TOKEN}" \
    "${MICROSOFT_BASE_URL}/v1.0/me/messages/${graph_draft_id}"
  assert_json "${HTTP_BODY_FILE}" "Graph delete removed draft and moved it to Deleted Items" 'data.isDraft === false && data.parentFolderId === "deleteditems"'

  local sent_draft_json
  sent_draft_json="$(graph_message_json "${sent_draft_subject}" "Sent Graph draft ${RUN_ID}" 'draft-send@example.com')"
  bearer_request 201 "Graph creates draft for delivery" "${MICROSOFT_ACCESS_TOKEN}" \
    -X POST "${MICROSOFT_BASE_URL}/v1.0/me/messages" "${json[@]}" --data "${sent_draft_json}"
  local graph_sent_draft_id
  graph_sent_draft_id="$(json_value "${HTTP_BODY_FILE}" 'data.id')"
  bearer_request 200 "Graph sends provider draft" "${MICROSOFT_ACCESS_TOKEN}" \
    -X POST "${MICROSOFT_BASE_URL}/v1.0/me/messages/${graph_sent_draft_id}/send"
  assert_json_with_expected "${HTTP_BODY_FILE}" "Graph sent draft is in Sent Items" "${sent_draft_subject}" \
    'data.isDraft === false && data.parentFolderId === "sentitems" && data.subject === process.env.JSON_EXPECTED'

  local direct_message direct_body
  direct_message="$(graph_message_json "${direct_subject}" "Direct Graph send ${RUN_ID}" 'direct@example.com')"
  direct_body="$(GRAPH_MESSAGE="${direct_message}" node -e 'process.stdout.write(JSON.stringify({message:JSON.parse(process.env.GRAPH_MESSAGE),saveToSentItems:true}))')"
  bearer_request 202 "Graph sends new mail directly" "${MICROSOFT_ACCESS_TOKEN}" \
    -X POST "${MICROSOFT_BASE_URL}/v1.0/me/sendMail" "${json[@]}" --data "${direct_body}"
  bearer_request 200 "Graph Sent Items contain direct send and forward" "${MICROSOFT_ACCESS_TOKEN}" \
    "${MICROSOFT_BASE_URL}/v1.0/me/mailFolders/sentitems/messages?%24top=50&%24orderby=receivedDateTime%20desc"
  JSON_DIRECT_SUBJECT="${direct_subject}" JSON_FORWARD_SUBJECT="${forward_subject}" assert_json "${HTTP_BODY_FILE}" \
    "Graph Sent Items persist direct send and forward" \
    'data.value.some((message) => message.subject === process.env.JSON_DIRECT_SUBJECT) && data.value.some((message) => message.subject === process.env.JSON_FORWARD_SUBJECT)'
  JSON_RUN_ID="${RUN_ID}" JSON_CONVERSATION="${graph_source_conversation_id}" assert_json "${HTTP_BODY_FILE}" \
    "Graph Sent Items persist direct reply and reply-all" \
    'data.value.some((message) => message.conversationId === process.env.JSON_CONVERSATION && message.body.content === `Direct reply ${process.env.JSON_RUN_ID}`) && data.value.some((message) => message.conversationId === process.env.JSON_CONVERSATION && message.body.content === `Direct reply-all ${process.env.JSON_RUN_ID}`)'

  bearer_request 200 "Graph archives source" "${MICROSOFT_ACCESS_TOKEN}" \
    -X POST "${MICROSOFT_BASE_URL}/v1.0/me/messages/${graph_source_id}/move" "${json[@]}" --data '{"destinationId":"archive"}'
  assert_json "${HTTP_BODY_FILE}" "Graph archive move persisted" 'data.parentFolderId === "archive"'
  bearer_request 200 "Graph trashes source" "${MICROSOFT_ACCESS_TOKEN}" \
    -X POST "${MICROSOFT_BASE_URL}/v1.0/me/messages/${graph_source_id}/move" "${json[@]}" --data '{"destinationId":"deleteditems"}'
  assert_json "${HTTP_BODY_FILE}" "Graph trash move persisted" 'data.parentFolderId === "deleteditems"'
}

finish_oauth_error_contracts() {
  section "OAuth invalid refresh and documented strict-auth limitations"
  request 200 "Google revokes refresh token" \
    -X POST "${GOOGLE_BASE_URL}/oauth2/revoke" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "token=${GOOGLE_REFRESH_TOKEN}"
  request 400 "Google rejects revoked refresh token" \
    -X POST "${GOOGLE_BASE_URL}/oauth2/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'grant_type=refresh_token' \
    --data-urlencode "refresh_token=${GOOGLE_REFRESH_TOKEN}" \
    --data-urlencode "client_id=${GOOGLE_CLIENT_ID}" \
    --data-urlencode "client_secret=${GOOGLE_CLIENT_SECRET}"
  assert_json "${HTTP_BODY_FILE}" "Google revoked refresh token returns invalid_grant" 'data.error === "invalid_grant"'

  request 200 "Microsoft revokes rotated refresh token" \
    -X POST "${MICROSOFT_BASE_URL}/oauth2/v2.0/revoke" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "token=${MICROSOFT_REFRESH_TOKEN}"
  request 400 "Microsoft rejects revoked refresh token" \
    -X POST "${MICROSOFT_BASE_URL}/oauth2/v2.0/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'grant_type=refresh_token' \
    --data-urlencode "refresh_token=${MICROSOFT_REFRESH_TOKEN}" \
    --data-urlencode "client_id=${MICROSOFT_CLIENT_ID}"
  assert_json "${HTTP_BODY_FILE}" "Microsoft revoked refresh token returns invalid_grant" 'data.error === "invalid_grant"'

  known_gap "the fork maps every unknown non-empty bearer token to its first seeded user; invalid/expired/wrong-provider bearer rejection and scope enforcement cannot be asserted"
}

wait_for_emulator
echo "emulator-e2e: run id ${RUN_ID}"
run_oauth_contracts
run_gmail_contracts
run_microsoft_contracts
finish_oauth_error_contracts

echo
echo "emulator-e2e: PASS — live Google and Microsoft OAuth/mail contracts completed for ${RUN_ID}"
