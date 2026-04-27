import AppKit
import MailFeatures
import SwiftTerm
import SwiftUI

struct EmbeddedAssistantTerminal: NSViewRepresentable {
    let configuration: AssistantTerminalConfiguration

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = LocalProcessTerminalView(frame: .zero)
        terminal.processDelegate = context.coordinator
        terminal.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        terminal.nativeBackgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1)
        terminal.nativeForegroundColor = NSColor(calibratedWhite: 0.92, alpha: 1)
        terminal.autoresizingMask = [.width, .height]

        context.coordinator.start(configuration: configuration, in: terminal)

        DispatchQueue.main.async {
            terminal.window?.makeFirstResponder(terminal)
        }

        return terminal
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        context.coordinator.update(configuration: configuration, in: nsView)
    }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        coordinator.stop(terminal: nsView)
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        private var launchedConfiguration: AssistantTerminalConfiguration?

        func start(configuration: AssistantTerminalConfiguration, in terminal: LocalProcessTerminalView) {
            guard launchedConfiguration == nil else { return }
            launchedConfiguration = configuration

            terminal.startProcess(
                executable: configuration.executable,
                args: configuration.arguments,
                environment: configuration.environmentVariables,
                currentDirectory: configuration.currentDirectory
            )
        }

        func update(configuration: AssistantTerminalConfiguration, in terminal: LocalProcessTerminalView) {
            guard launchedConfiguration != nil else {
                start(configuration: configuration, in: terminal)
                return
            }
        }

        func stop(terminal: LocalProcessTerminalView) {
            guard terminal.process.running else { return }
            terminal.terminate()
        }

        nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
            print("[AssistantTerminal] process terminated with exit code: \(exitCode.map(String.init) ?? "unknown")")
        }
    }
}

private extension AssistantTerminalConfiguration {
    var environmentVariables: [String] {
        environment
            .map { key, value in "\(key)=\(value)" }
            .sorted()
    }
}
