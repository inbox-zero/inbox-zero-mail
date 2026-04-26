# Contributing to Inbox Zero Mail

Thanks for your interest in contributing! This guide covers everything you need to set up a local development environment and start hacking on the app.

## Requirements

- macOS with Xcode 26.x installed
- Docker, if you want the local Gmail/Outlook emulator

## Quick Start

From the repo root:

```bash
./tools/dev/run-local.sh
```

That one command:

- starts the local emulator on `4402` and `4403`, or reuses it if those ports are already running
- builds the macOS app into `./.build/xcode`
- opens the app with `--use-emulator --autoconnect-gmail`

Use a different seeded Gmail account:

```bash
./tools/dev/run-local.sh --email beta.inbox@example.com
```

Run with local demo data and no emulator:

```bash
./tools/dev/run-local.sh --demo
```

Run against real Gmail in dev:

```bash
cp tools/dev/live-gmail.env.example .env.local
# edit .env.local with your desktop OAuth client
./tools/dev/run-local.sh --live-gmail
```

## Open In Xcode

```bash
open InboxZeroMail.xcodeproj
```

Then run the `InboxZeroMail` scheme.

Useful launch arguments in Xcode:

- `--use-emulator`
- `--autoconnect-gmail`
- `--seed-demo-data`

Useful environment variables in Xcode:

- `INBOX_ZERO_GMAIL_EMULATOR_EMAIL=alpha.inbox@example.com`
- `INBOX_ZERO_GMAIL_EMULATOR_ACCOUNTS=alpha.inbox@example.com,beta.inbox@example.com`
- `INBOX_ZERO_AUTOCONNECT_GMAIL=1`
- Remote email images default to `img.getinboxzero.com`.
- `INBOX_ZERO_IMAGE_PROXY_BASE_URL=https://img.example.com/proxy` overrides the default privacy proxy. Host-only values like `img.getinboxzero.com` are normalized to `https://img.getinboxzero.com/proxy`.
- `INBOX_ZERO_IMAGE_PROXY_SIGNING_SECRET=...` makes the macOS client emit the same signed `?u=...&e=...&s=...` proxy URLs as the web app. `IMAGE_PROXY_SIGNING_SECRET` is also accepted for CI/shared environment compatibility.
- `INBOX_ZERO_IMAGE_PROXY_BASE_URL=off` disables proxying and falls back to direct remote image loads when that preference is enabled.
- If you embed an image-proxy signing secret into a distributed desktop build, users can extract it. Prefer a desktop-specific low-trust proxy secret or a proxy mode designed for public clients.

## OAuth Setup

Live Gmail OAuth is intentionally not checked into the repo.

- Set `INBOX_ZERO_GMAIL_CLIENT_ID` in your local Xcode scheme or release pipeline if you want real Google OAuth.
- Set `INBOX_ZERO_GMAIL_CLIENT_SECRET` only if your Google client setup still requires it.
- Do not commit either value.
- For Xcode, the preferred local setup is `Config/LocalSecrets.xcconfig`.
- Create it with:
```bash
cp Config/LocalSecrets.xcconfig.example Config/LocalSecrets.xcconfig
open Config/LocalSecrets.xcconfig
```
- `Config/InboxZeroMail.xcconfig` is checked in and automatically includes `LocalSecrets.xcconfig` if it exists.
- Emulator mode uses separate defaults. If you need to override those, use `INBOX_ZERO_GMAIL_EMULATOR_CLIENT_ID` and `INBOX_ZERO_GMAIL_EMULATOR_CLIENT_SECRET`.
- `./tools/dev/run-local.sh` auto-loads `./.env.local` if it exists.

### Self-Hosting OAuth

- Create your own Google OAuth client of type `Desktop app`.
- Put the values in `Config/LocalSecrets.xcconfig` for Xcode builds, or in `.env.local` for `./tools/dev/run-local.sh`.
- Quick setup for Xcode:
```bash
cp Config/LocalSecrets.xcconfig.example Config/LocalSecrets.xcconfig
open Config/LocalSecrets.xcconfig
```

## Run From Terminal

The manual path is still available if you want it:

```bash
xcodebuild \
  -project InboxZeroMail.xcodeproj \
  -scheme InboxZeroMail \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath ./.build/xcode \
  build

INBOX_ZERO_GMAIL_EMULATOR_EMAIL=alpha.inbox@example.com \
./.build/xcode/Build/Products/Debug/InboxZeroMail.app/Contents/MacOS/InboxZeroMail \
  --use-emulator \
  --autoconnect-gmail
```

But the normal dev path should just be:

```bash
./tools/dev/run-local.sh
```

## Debug ACP launch

For local ACP smoke testing, run the macOS app with a debug prompt. The app owns the ACP session and prints the handshake, provider/model discovery when the agent advertises it, the prompt, and the response to the Xcode/app console:

```bash
./.build/xcode/Build/Products/Debug/InboxZeroMail.app/Contents/MacOS/InboxZeroMail \
  --debug-acp-ask "hi to ai"
```

By default this launches `claude-code-acp` from `PATH`. Use launch arguments to point at another ACP-compatible command:

```bash
./.build/xcode/Build/Products/Debug/InboxZeroMail.app/Contents/MacOS/InboxZeroMail \
  --debug-acp-ask "hi to ai" \
  --debug-acp-agent npx \
  --debug-acp-agent-arg -y \
  --debug-acp-agent-arg @zed-industries/claude-code-acp
```

Useful environment-variable equivalents for Xcode schemes:

- `INBOX_ZERO_DEBUG_ACP_ASK=hi to ai`
- `INBOX_ZERO_DEBUG_ACP_AGENT=/path/to/agent`
- `INBOX_ZERO_DEBUG_ACP_AGENT_ARGS="arg1 arg2"`
- `INBOX_ZERO_DEBUG_ACP_CWD=/absolute/session/path`

This is intentionally debug-only: it is a first app-owned ACP client wrapper, not a production AI compose/reply UI.

## App Control CLI

The app control plane is disabled by default.

Enable it explicitly when you want to test terminal or agent control:

```bash
INBOX_ZERO_ENABLE_CONTROL_PLANE=1 ./tools/dev/run-local.sh --demo
```

Or in Xcode, add:

- launch argument: `--enable-control-plane`
- environment variable: `INBOX_ZERO_ENABLE_CONTROL_PLANE=1`

When enabled, the current dev transport listens on `localhost:61432`.

Launch the app, then use:

```bash
./tools/dev/inboxctl windows list
./tools/dev/inboxctl window snapshot
./tools/dev/inboxctl view tab unread
./tools/dev/inboxctl view split-inbox all
./tools/dev/inboxctl search "from:alex newer_than:7d"
./tools/dev/inboxctl thread list
./tools/dev/inboxctl thread open-visible 1
./tools/dev/inboxctl thread read --visible 2
./tools/dev/inboxctl thread current --json
./tools/dev/inboxctl thread open gmail:alpha@example.com/thread-1
./tools/dev/inboxctl draft reply --mode reply
./tools/dev/inboxctl draft reply --visible 1 --mode reply
./tools/dev/inboxctl draft set-body "Thanks -- I'll send the update today."
./tools/dev/inboxctl draft show
```

Notes:

- The CLI targets the active window by default.
- `window snapshot` returns the current window state, visible threads, selected thread, and draft if compose is open.
- `draft reply` can target the current selection, a specific thread id, or a visible thread index.
- This is a first control-plane pass intended for local/dev workflows. It currently focuses on navigation, reading the visible thread, and editing drafts.
- It is intentionally opt-in for now because the current transport is not hardened yet.

For real Gmail in dev, the script gives you a first-class path:

```bash
./tools/dev/run-local.sh --live-gmail
```

You can also override credentials per run:

```bash
./tools/dev/run-local.sh \
  --live-gmail \
  --gmail-client-id your-desktop-client-id.apps.googleusercontent.com \
  --gmail-client-secret your-desktop-client-secret
```

The script will switch to direct launch automatically when live Gmail credentials are involved, because `open` does not pass per-run environment variables through to the app.

## Local Emulator

Start the local Gmail + Microsoft emulator on ports `4402` and `4403`:

```bash
docker compose up -d emulate
```

If another process already has both ports open, `./tools/dev/run-local.sh` will reuse that running emulator instead of trying to bind them again.

Stop it:

```bash
docker compose stop emulate
```

The seed data lives in `tools/emulator/dev-seed.yaml`.

The runner script lives in `tools/dev/run-local.sh`.

## Tests

Run the Swift package tests:

```bash
swift test --package-path Packages/MailFeatures
swift test --package-path Packages/ProviderGmail
```

Build the macOS app target:

```bash
xcodebuild -project InboxZeroMail.xcodeproj -scheme InboxZeroMail -destination 'platform=macOS' build
```

## Open Source Hygiene

- Keep live OAuth credentials out of git. Use local scheme variables, an untracked xcconfig, or CI and release-time injection.
- A shipped desktop app can contain an OAuth client ID. Treat that as public.
- A shipped desktop app cannot keep a client secret truly secret. If you bundle one, assume anyone can extract it. Prefer native-app flows like PKCE and do not treat the secret as a security boundary.

## Direct Releases

The direct-download lane uses Sparkle and GitHub Releases.

- In-app update checks are wired through Sparkle for non-App-Store builds.
- The release workflow publishes signed GitHub release assets and updates the Sparkle appcast on `gh-pages`.
- Setup details live in [`docs/direct-releases.md`](docs/direct-releases.md).
