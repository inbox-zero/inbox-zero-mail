import MailCore
import MailFeatures
import SwiftUI

#if canImport(AppUpdates) && !APP_STORE
import AppUpdates
#endif

struct MailAppCommands: Commands {
    let store: MailAppStore
    @ObservedObject var updater: AppUpdateController
    @FocusedValue(\.windowModel) var activeWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
#if !APP_STORE
            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .disabled(updater.canCheckForUpdates == false)
#endif
        }

        // Let macOS provide the default "New Window" (Cmd+N) for WindowGroup.
        // Add Account uses Cmd+Shift+N.
        CommandGroup(after: .newItem) {
            if store.availableAccountProviders.count <= 1, let provider = store.availableAccountProviders.first {
                Button("Add \(provider.displayName) Account…") {
                    store.connectAccount(kind: provider)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            } else if store.availableAccountProviders.isEmpty == false {
                ForEach(store.availableAccountProviders, id: \.self) { provider in
                    Button("Add \(provider.displayName) Account…") {
                        store.connectAccount(kind: provider)
                    }
                }
            }

            Divider()

            Button("Load Demo Data") {
                activeWindow?.loadDemoInbox()
            }
        }

        CommandMenu("Mailbox") {
            Button("Command Palette") {
                activeWindow?.openCommandPalette()
            }
            .mailKeyboardShortcut(MailCommandShortcuts.commandPalette)

            Button(activeWindow?.isAssistantSidebarVisible == true ? "Hide Assistant Sidebar" : "Show Assistant Sidebar") {
                activeWindow?.toggleAssistantSidebar()
            }
            .mailKeyboardShortcut(MailCommandShortcuts.assistantSidebar)

            Button("Open Assistant Terminal") {
                activeWindow?.selectAssistantSidebarMode(.terminal)
            }

            Divider()

            Button("Refresh Inbox") {
                activeWindow?.refresh()
            }
            .mailKeyboardShortcut(MailCommandShortcuts.refresh)

            Button("Compose") {
                activeWindow?.openCompose()
            }
            .mailKeyboardShortcut(MailCommandShortcuts.compose)

            Button(activeWindow?.selectedThread?.isInInbox == false ? "Unarchive Thread" : "Archive Thread") {
                activeWindow?.toggleArchiveSelection()
            }
            .mailKeyboardShortcut(MailCommandShortcuts.archive)

            Button("Toggle Read") {
                activeWindow?.toggleReadSelection()
            }
            .mailKeyboardShortcut(MailCommandShortcuts.toggleRead)

            Button("Toggle Star") {
                activeWindow?.toggleStarSelection()
            }
            .mailKeyboardShortcut(MailCommandShortcuts.toggleStar)

            Button(activeWindow?.selectedThreadSnoozeActionTitle ?? "Snooze Thread…") {
                activeWindow?.performPrimarySnoozeAction()
            }
            .mailKeyboardShortcut(MailCommandShortcuts.snooze)

        }
    }
}
