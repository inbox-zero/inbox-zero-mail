import MailCore
import MailFeatures
import SwiftUI

#if canImport(AppUpdates) && !APP_STORE
import AppUpdates
#endif

struct MailAppCommands: Commands {
    let store: MailAppStore
    @ObservedObject var updater: AppUpdateController
    @Environment(\.openWindow) private var openWindow
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

            Button("Open Demo Inbox") {
                store.loadDemoInbox()
                openWindow(id: MailWindowScene.main)
            }
        }

        CommandMenu("Mailbox") {
            Button("Command Palette") {
                activeWindow?.openCommandPalette()
            }
            .keyboardShortcut("k", modifiers: [.command])

            Divider()

            Button("Refresh Inbox") {
                activeWindow?.refresh()
            }
            .keyboardShortcut("r", modifiers: [.command])

            Button("Compose") {
                activeWindow?.openCompose()
            }
            .keyboardShortcut("c", modifiers: [])

            Button(activeWindow?.selectedThread?.isInInbox == false ? "Unarchive Thread" : "Archive Thread") {
                activeWindow?.toggleArchiveSelection()
            }
            .keyboardShortcut("e", modifiers: [])

            Button("Toggle Read") {
                activeWindow?.toggleReadSelection()
            }
            .keyboardShortcut("u", modifiers: [.shift])

            Button("Toggle Star") {
                activeWindow?.toggleStarSelection()
            }
            .keyboardShortcut("s", modifiers: [])

            Button(activeWindow?.selectedThreadSnoozeActionTitle ?? "Snooze Thread…") {
                activeWindow?.performPrimarySnoozeAction()
            }
            .keyboardShortcut("h", modifiers: [])

        }
    }
}
