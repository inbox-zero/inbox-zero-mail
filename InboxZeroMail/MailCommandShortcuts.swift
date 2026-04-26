import SwiftUI

struct MailCommandShortcut: Equatable {
    let key: Character
    let modifiers: EventModifiers

    var keyEquivalent: KeyEquivalent { KeyEquivalent(key) }

    var isTextEntrySafe: Bool {
        modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option)
    }
}

enum MailCommandShortcuts {
    static let commandPalette = MailCommandShortcut(key: "k", modifiers: [.command])
    static let assistantSidebar = MailCommandShortcut(key: "\\", modifiers: [.command, .shift])
    static let refresh = MailCommandShortcut(key: "r", modifiers: [.command])

    // Bare-letter shortcuts are unsafe as global menu commands: they steal text from
    // compose fields, search, and the embedded SwiftTerm terminal.
    static let compose: MailCommandShortcut? = nil
    static let archive: MailCommandShortcut? = nil
    static let toggleRead: MailCommandShortcut? = nil
    static let toggleStar: MailCommandShortcut? = nil
    static let snooze: MailCommandShortcut? = nil

    static var mailboxMenuShortcuts: [MailCommandShortcut] {
        [
            commandPalette,
            assistantSidebar,
            refresh,
            compose,
            archive,
            toggleRead,
            toggleStar,
            snooze,
        ].compactMap { $0 }
    }
}

extension View {
    @ViewBuilder
    func mailKeyboardShortcut(_ shortcut: MailCommandShortcut?) -> some View {
        if let shortcut {
            keyboardShortcut(shortcut.keyEquivalent, modifiers: shortcut.modifiers)
        } else {
            self
        }
    }
}
