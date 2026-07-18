# Inbox Zero Mail for Native SDK

This directory contains the cross-platform Native SDK client. Its UI is native
markup rendered by Native SDK and its state/provider logic is Zig. It targets
macOS, Windows, and Linux without an embedded browser runtime.

## Current product slice

- Gmail and Outlook emulator accounts in one synchronized model.
- Combined inbox and per-account views.
- All, unread, starred, snoozed, archive, and trash filters.
- Search and a split sidebar/list/detail layout.
- Gmail and Outlook archive, read/unread, star, and trash mutations with
  optimistic rollback on provider failure.
- Keyboard navigation and actions (`J`/`K`, arrows, `E`, `S`, `Shift+U`, `H`,
  `/`, `Enter`).
- Up to three independent message windows backed by the shared mail store.
- Native SDK model, parser, effects, markup, and automation tests.

The emulator bearer tokens are development-only identities seeded in
`tools/emulator/dev-seed.yaml`. Production OAuth and OS credential storage are
intentionally not replaced with plaintext files.

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

The smoke test waits for the app, polls its accessibility snapshot for the
combined inbox and a seeded subject from each provider account, and writes a
deterministic screenshot to
`.zig-cache/native-sdk-automation/screenshot-mail-canvas.png`. It assumes the
shared emulator and app are already running and does not stop either process.

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

On Ubuntu, Native SDK 0.5.3 with its Zig 0.16.0 toolchain builds this app but
the GTK host aborts at startup with a `General protection exception` in
`gtk_host.c:native_sdk_gtk_create_view`. The failure occurs while
`native_sdk_strndup(role, role_len)` reads corrupted trailing C ABI arguments.
We reproduced the same crash in the SDK's unchanged `examples/system-monitor`,
so this is an upstream Linux host ABI issue rather than an Inbox Zero provider
or UI failure. A local experiment that ignored those trailing metadata strings
allowed snapshot assertions and deterministic screenshots to complete, but
the GTK host still reported `UnsupportedViewFocus` / `ViewNotFound` for focus
and frame operations; that workaround is not included here.

The strict model/markup checks, unit tests, and Windows cross-build remain
valid. Retest the unmodified macOS, Windows, and Linux native hosts when an
upstream Native SDK release fixes the ABI boundary. The automation smoke script
intentionally does not assert `gpu_nonblank=true` while this host defect is
open; it still captures the screenshot artifact and verifies its file is
non-empty.
