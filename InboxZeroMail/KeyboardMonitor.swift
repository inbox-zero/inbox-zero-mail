import AppKit
import MailCore
import MailFeatures
import SwiftUI

struct KeyboardMonitor: ViewModifier {
    @Bindable var model: WindowModel
    @Binding var showShortcuts: Bool

    func body(content: Content) -> some View {
        content
            .background(KeyMonitorRepresentable(model: model, showShortcuts: $showShortcuts))
    }
}

private struct KeyMonitorRepresentable: NSViewRepresentable {
    @Bindable var model: WindowModel
    @Binding var showShortcuts: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        let shortcuts = $showShortcuts
        let coordinator = context.coordinator
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            Self.handleKeyDown(event, model: model, showShortcuts: shortcuts, coordinatorView: coordinator.view)
        }
        context.coordinator.monitor = monitor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        // Replace the monitor so it captures the latest model / binding values.
        if let old = context.coordinator.monitor {
            NSEvent.removeMonitor(old)
        }
        let shortcuts = $showShortcuts
        let coordinator = context.coordinator
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            Self.handleKeyDown(event, model: model, showShortcuts: shortcuts, coordinatorView: coordinator.view)
        }
        context.coordinator.monitor = monitor
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor {
            NSEvent.removeMonitor(monitor)
            coordinator.monitor = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var monitor: Any?
        weak var view: NSView?
    }

    private static func handleKeyDown(
        _ event: NSEvent,
        model: WindowModel,
        showShortcuts: Binding<Bool>,
        coordinatorView: NSView?
    ) -> NSEvent? {
        // Only handle keyboard shortcuts for the focused (key) window
        guard let window = coordinatorView?.window, window === NSApp.keyWindow else { return event }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Escape dismisses active compose
        if event.keyCode == 53, model.isComposeActive { // 53 = Escape
            model.dismissCompose()
            return nil
        }

        // Cmd+Shift+P pops out inline compose to floating
        if modifiers.contains(.command) && modifiers.contains(.shift),
           event.charactersIgnoringModifiers == "p",
           model.composeMode == .inline {
            model.popOutCompose()
            return nil
        }

        guard model.isModalPresented == false else { return event }

        let hasSystemModifier = modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option)

        // Cmd+K opens the command palette even when inline search is focused.
        if modifiers.contains(.command), event.charactersIgnoringModifiers == "k" {
            model.openCommandPalette()
            return nil
        }

        guard NSApp.keyWindow?.firstResponder is NSTextView == false else { return event }

        // Cmd+B toggles sidebar.
        if modifiers.contains(.command), event.charactersIgnoringModifiers == "b" {
            model.toggleSidebar()
            return nil
        }

        // Cmd+A to select all
        if modifiers.contains(.command), event.charactersIgnoringModifiers == "a" {
            model.selectAll()
            return nil
        }

        switch event.charactersIgnoringModifiers {
        case "j":
            guard hasSystemModifier == false else { return event }
            if event.modifierFlags.contains(.shift) {
                model.extendSelection(by: 1)
            } else {
                model.moveHover(by: 1)
            }
            return nil
        case "k":
            guard hasSystemModifier == false else { return event }
            if event.modifierFlags.contains(.shift) {
                model.extendSelection(by: -1)
            } else {
                model.moveHover(by: -1)
            }
            return nil
        case "x":
            guard hasSystemModifier == false else { return event }
            model.toggleMultiSelectCurrent()
            return nil
        case "e":
            guard hasSystemModifier == false else { return event }
            if model.isMultiSelectActive {
                model.batchArchive()
            } else {
                model.toggleArchiveSelection()
            }
            return nil
        case "f":
            guard hasSystemModifier == false else { return event }
            model.openCompose(replyMode: .forward)
            return nil
        case "h":
            guard hasSystemModifier == false else { return event }
            model.showSnoozePicker()
            return nil
        case "#":
            guard hasSystemModifier == false else { return event }
            if model.isMultiSelectActive {
                model.batchTrash()
            } else {
                model.trashSelection()
            }
            return nil
        case "s":
            guard hasSystemModifier == false else { return event }
            model.toggleStarSelection()
            return nil
        case "u":
            guard hasSystemModifier == false else { return event }
            if event.modifierFlags.contains(.shift) {
                model.toggleReadSelection()
                return nil
            }
            return event
        case "r":
            guard hasSystemModifier == false else { return event }
            if event.modifierFlags.contains(.command) == false {
                model.openCompose(replyMode: .reply)
                return nil
            }
            return event
        case "a":
            guard hasSystemModifier == false else { return event }
            model.openCompose(replyMode: .replyAll)
            return nil
        case "c":
            guard hasSystemModifier == false else { return event }
            model.openCompose()
            return nil
        case "l":
            guard hasSystemModifier == false else { return event }
            model.showTagPicker()
            return nil
        case "v":
            guard hasSystemModifier == false else { return event }
            model.showFolderPicker()
            return nil
        case "z":
            guard hasSystemModifier == false else { return event }
            model.performUndo()
            return nil
        case "?", "/":
            guard hasSystemModifier == false else { return event }
            if event.modifierFlags.contains(.shift) || event.charactersIgnoringModifiers == "?" {
                showShortcuts.wrappedValue.toggle()
                return nil
            }
            // "/" without shift opens search
            if event.charactersIgnoringModifiers == "/" && !event.modifierFlags.contains(.shift) {
                model.beginSearch()
                return nil
            }
            return event
        default:
            switch event.keyCode {
            case 125: // Down arrow
                guard hasSystemModifier == false else { return event }
                if event.modifierFlags.contains(.shift) {
                    model.extendSelection(by: 1)
                } else {
                    model.moveHover(by: 1)
                }
                return nil
            case 126: // Up arrow
                guard hasSystemModifier == false else { return event }
                if event.modifierFlags.contains(.shift) {
                    model.extendSelection(by: -1)
                } else {
                    model.moveHover(by: -1)
                }
                return nil
            case 36: // Enter
                if let hoveredID = model.hoveredThreadID {
                    model.open(threadID: hoveredID)
                }
                return nil
            case 48: // Tab
                guard hasSystemModifier == false, model.isSplitInboxVisible else { return event }
                model.cycleSplitInbox(
                    in: AppPreferences.configuredSplitInboxItems(),
                    forward: event.modifierFlags.contains(.shift) == false
                )
                return nil
            case 53: // Escape
                if showShortcuts.wrappedValue {
                    showShortcuts.wrappedValue = false
                } else if model.isMultiSelectActive {
                    model.deselectAll()
                } else if model.isSearchFocused || !model.searchText.isEmpty {
                    model.cancelSearch()
                } else if model.isSidebarVisible {
                    model.isSidebarVisible = false
                } else {
                    model.closeThread()
                }
                return nil
            default:
                return event
            }
        }
    }
}
