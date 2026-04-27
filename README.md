# Inbox Zero Mail

**The open-source, privacy-first, native macOS email client.** Built in Swift for people who want email to feel fast, private, and fully under their control.

![Inbox Zero Mail inbox](docs/screenshot.png)

## Why Inbox Zero Mail?

Most modern email clients are Electron apps that can eat 2 GB of RAM just to show your inbox. Inbox Zero Mail is a real macOS app, built with SwiftUI, that typically uses ~100 MB. It launches quickly, scrolls smoothly, and stays out of the way.

It is also yours. The code is open source, the architecture is modular, and the app is easy to hack on: point Claude Code, Codex, or your editor at the repo and change the workflow, UI, shortcuts, or provider behavior to match how you actually handle email.

**Want AI-powered email features?** Check out [getinboxzero.com](https://getinboxzero.com), our companion open-source project for AI triage, auto-responses, and more.

> **Beta notice:** Inbox Zero Mail is under active development. We use it daily, but you may encounter rough edges. Bug reports and contributions are very welcome!

## Highlights

- 🛠️ **Open source & hackable** -- fork it, theme it, add features, or ask Claude Code/Codex to make the email client you want.
- 🔒 **Privacy-first** -- your mail talks directly to Gmail today, with Microsoft/Outlook support coming soon. Remote images are routed through a privacy proxy by default, so senders do not get your IP just because you opened an email.
- ⚡ **Native Swift + SwiftUI** -- ~100 MB of RAM vs. 2 GB for Electron-based alternatives. Instant launch, smooth scrolling, no lag.
- 📬 **First-class multi-address support** -- connect multiple Gmail accounts today, with Outlook/Microsoft support coming soon. See every address in one unified view, split inbox tabs, or separate windows.
- ⌨️ **Keyboard-first workflow** -- navigate your entire inbox without touching the mouse. Archive, reply, star, snooze, switch views, and run actions from the keyboard.
- 🔎 **Command palette** (<kbd>Cmd</kbd>+<kbd>K</kbd>) -- jump to any action, account, or label instantly.
- 🗂️ **Split inbox** -- organize your inbox into customizable tabs (Unread, Starred, Snoozed, by label, or custom search queries).

## Features

| Feature | Status |
|---|---|
| Gmail support | Stable |
| Outlook support | Coming soon |
| Unified multi-account inbox | Stable |
| Split inbox with custom tabs | Stable |
| Command palette (<kbd>Cmd</kbd>+<kbd>K</kbd>) | Stable |
| Keyboard shortcuts | Stable |
| Thread view & conversation grouping | Stable |
| Compose (inline, floating, fullscreen) | Stable |
| Archive, star, snooze, read/unread | Stable |
| Labels & label management | Stable |
| Search with full query syntax | Stable |
| Multi-select & bulk actions | Stable |
| Focus & split layout modes | Stable |
| Undo actions | Stable |
| Remote image privacy proxy | Stable |
| Auto-updates via Sparkle | Stable |

## Keyboard Shortcuts

| Key | Action |
|---|---|
| <kbd>Cmd</kbd>+<kbd>K</kbd> | Command palette |
| <kbd>Cmd</kbd>+<kbd>B</kbd> | Toggle sidebar |
| <kbd>C</kbd> | Compose |
| <kbd>E</kbd> | Archive / unarchive |
| <kbd>S</kbd> | Star / unstar |
| <kbd>Shift</kbd>+<kbd>U</kbd> | Toggle read / unread |
| <kbd>H</kbd> | Snooze |
| <kbd>Cmd</kbd>+<kbd>R</kbd> | Refresh inbox |
| <kbd>Cmd</kbd>+<kbd>Shift</kbd>+<kbd>N</kbd> | Add Gmail account |

## Getting Started

### Download

Download the latest macOS release:

[Download Inbox Zero for macOS](../../releases/latest)

On the release page, download `Inbox-Zero-*.zip`, unzip it, and move
`Inbox Zero.app` to your Applications folder.

Requires macOS 14+ on Apple Silicon.

### Build from Source

Requires macOS with Xcode 26+.

```bash
git clone https://github.com/inbox-zero/inbox-zero-mail.git
cd inbox-zero-mail
./tools/dev/run-local.sh
```

That's it. The script starts a local email emulator, builds the app, and opens it. See [CONTRIBUTING.md](CONTRIBUTING.md) for the full development setup, OAuth configuration, and more.

## Privacy

Inbox Zero Mail talks directly to the Gmail (and soon Microsoft) APIs. Your mail does not pass through any Inbox Zero servers.

The one exception is remote images. By default, image requests are routed through `img.getinboxzero.com` so that senders can't learn your IP or other client details just from you opening their email. You have three options:

- **Use the default proxy** (recommended for most users) -- zero setup.
- **Use your own proxy** -- enter your proxy URL in Settings > General > Privacy. The proxy is open source and runs for free on Cloudflare Workers; see the [main Inbox Zero repo](https://getinboxzero.com/github) to host one.
- **Turn it off** -- disable remote images in Settings.

Developers can set `INBOX_ZERO_IMAGE_PROXY_BASE_URL` to configure the default proxy URL for local or custom builds, or set it to `off` to disable proxying in that build.

## Architecture

Inbox Zero Mail is built as a modular Swift package architecture:

```
InboxZeroMail (app)
 +-- MailFeatures    -- UI, window management, state
 +-- MailCore        -- shared models & protocols
 +-- MailData        -- local persistence (GRDB/SQLite)
 +-- ProviderGmail   -- Gmail API integration
 +-- ProviderOutlook -- Outlook/Microsoft Graph (WIP)
 +-- ProviderCore    -- shared provider abstractions
 +-- AppUpdates      -- Sparkle auto-update integration
```

## Contributing

We'd love your help! See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, running tests, and project conventions.

## License

AGPL-3.0
