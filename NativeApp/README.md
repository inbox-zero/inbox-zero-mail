# Inbox Zero Mail for Native SDK

This directory contains the cross-platform Native SDK client. Its UI is native
markup rendered by Native SDK and its state/provider logic is Zig. It targets
macOS, Windows, and Linux without an embedded browser runtime.

## Current product slice

- Gmail and Outlook emulator accounts in one synchronized model.
- Combined inbox and per-account views.
- All, unread, starred, snoozed, archive, and trash filters.
- Provider-backed drafts with search, reopen, autosave, save-and-close, and
  discard.
- New mail, reply, reply-all, and forward with To/Cc/Bcc and provider-threaded
  delivery through Gmail and Microsoft Graph.
- Search and a split sidebar/list/detail layout, including draft search.
- Gmail and Outlook archive, read/unread, star, and trash mutations with
  optimistic rollback on provider failure.
- Keyboard navigation and actions (`J`/`K`, arrows, `C`, `R`, `A`, `F`, `E`,
  `S`, `Shift+U`, `H`, `/`, `Enter`).
- Up to three independent message windows plus a native compose window, all
  backed by the shared mail store and stable model identities.
- Native SDK model, parser, effects, markup, and automation tests.

The emulator bearer tokens are development-only identities seeded in
`tools/emulator/dev-seed.yaml` and isolated in `src/config/emulator.zig`.
Production OAuth and OS credential storage are intentionally not replaced with
plaintext files.

The current compose path is plain text (with a generated multipart
plain/HTML MIME body for Gmail) and caps a message body at 16 KiB and each
recipient field at 32 addresses. Incoming Gmail plain-text and HTML-only bodies
and Outlook text/HTML bodies are readable. Attachment download/upload,
production account onboarding, background pagination beyond the in-memory
store, and offline SQLite caching remain separate parity work.

Synced provider drafts that contain HTML or attachments are deliberately
read-only in the plain-text composer: they can be sent unchanged or discarded,
but are never rewritten, so opening them cannot silently strip formatting,
inline content, or files. Plain-text provider drafts remain fully editable.

## Prerequisites

- Node.js 24 (the CI version; current maintained Node releases also work).
- Docker for the Google and Microsoft emulator services.
- Native SDK CLI 0.5.3, invoked through `npx` below so no global install is
  required.

The first CLI run installs the checksum-verified Zig 0.16.0 toolchain under
`~/.native/toolchains` when necessary.

## Run against the emulator

From the repository root:

```sh
docker compose up -d emulate
cd NativeApp
npx --yes @native-sdk/cli@0.5.3 dev . --yes -Dautomation=true
```

Run the CLI from `NativeApp`: Native SDK's automation IPC directory is resolved
from the current working directory. The development tokens in the seed are
only for the local emulator.

## Static checks and tests

```sh
cd NativeApp
npx --yes @native-sdk/cli@0.5.3 test . --yes
npx --yes @native-sdk/cli@0.5.3 check . --strict
```

The test command builds the Native SDK model contract used by the strict
markup/binding check. CI runs both commands and then cross-builds the Windows
executable.

## Automation smoke test

Start the emulator and the automation-enabled app as shown above. From a
second terminal:

```sh
cd NativeApp
./scripts/automation-smoke.sh
```

The smoke test waits for the app, polls its accessibility snapshot for both
providers, opens the native compose window, verifies its controls, opens a
message window and the drafts view, and writes deterministic mail and compose
screenshots under `.zig-cache/native-sdk-automation/`. It assumes the shared
emulator and app are already running and does not stop either process.

## Windows cross-build

```sh
cd NativeApp
npx --yes @native-sdk/cli@0.5.3 build . --yes \
  -Dtarget=x86_64-windows-gnu \
  -Dplatform=windows \
  -Dautomation=true
test -s zig-out/bin/inbox-zero-mail-native.exe
npx --yes @native-sdk/cli@0.5.3 package \
  --target windows \
  --binary zig-out/bin/inbox-zero-mail-native.exe
```

Native SDK 0.5.3 currently emits a directory-based Windows distributable; its
Windows installer and signing story is still early.

On Linux, the same Win32 host path exercised by Native SDK itself can be
smoke-tested through Wine:

```sh
sudo apt-get install wine xvfb
cd NativeApp
./scripts/windows-wine-smoke.sh
```

That smoke verifies non-blank Win32 software rendering, account and filter
input, the `/` keyboard shortcut, and a deterministic screenshot. Provider
HTTP is covered separately against the native Linux host and emulator because
Zig 0.16 socket setup currently hits an unsupported Wine AFD option.

## Native SDK 0.5.3 Linux host limitation

The unmodified GTK host starts under Xvfb and publishes complete accessibility
snapshots, so the Linux smoke can verify sync, pointer actions, dynamic windows,
and screenshot artifacts. Native SDK 0.5.3 still reports repeated
`ViewNotFound` frame diagnostics and `UnsupportedViewFocus` for semantic text
injection on this headless Linux host; `gpu_nonblank` is also unavailable on
that presentation path. The same compose text actions are exercised by the
Win32 Wine smoke, while save/send/provider sequencing is covered by deterministic
fake-effects integration tests. Retest the Linux text-injection assertions when
an upstream SDK release fixes its host view lookup.
