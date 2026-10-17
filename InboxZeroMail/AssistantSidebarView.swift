import DesignSystem
import MailFeatures
import SwiftUI

struct AssistantSidebarView: View {
    @Bindable var model: WindowModel

    var body: some View {
        VStack(spacing: 0) {
            header
            modePicker
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            Divider()

            Group {
                switch model.assistantSidebarMode {
                case .agent:
                    AssistantAgentPanel()
                case .terminal:
                    AssistantTerminalPanel(configuration: model.assistantTerminal)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(MailDesignTokens.surface)
        .accessibilityIdentifier("assistant-sidebar")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.assistantSidebarMode.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MailDesignTokens.accent)

            VStack(alignment: .leading, spacing: 1) {
                Text("Assistant")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(MailDesignTokens.textPrimary)
                Text(model.assistantSidebarMode.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(MailDesignTokens.textSecondary)
            }

            Spacer()

            Button {
                model.closeAssistantSidebar()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MailDesignTokens.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close assistant sidebar")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var modePicker: some View {
        Picker("Assistant mode", selection: $model.assistantSidebarMode) {
            ForEach(AssistantSidebarMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("assistant-sidebar-mode-picker")
    }
}

private struct AssistantAgentPanel: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AssistantPanelCard(
                    icon: "sparkles",
                    title: "ACP agent UI",
                    body: "This is the native surface for protocol-driven agent sessions. It is ready for chat, plans, tool calls, permissions, model/mode controls, and slash-command discovery without hardcoding a single provider."
                )

                VStack(alignment: .leading, spacing: 10) {
                    AssistantCapabilityRow(icon: "text.bubble", title: "Chat transcript", subtitle: "Render prompt turns and streaming text updates.")
                    AssistantCapabilityRow(icon: "checklist", title: "Plans", subtitle: "Show ACP plan entries and statuses.")
                    AssistantCapabilityRow(icon: "wrench.and.screwdriver", title: "Tool calls", subtitle: "Display tool progress, results, and permission choices.")
                    AssistantCapabilityRow(icon: "slider.horizontal.3", title: "Config", subtitle: "Use ACP config options for models, reasoning, and provider modes.")
                }
            }
            .padding(16)
        }
    }
}

private struct AssistantTerminalPanel: View {
    let configuration: AssistantTerminalConfiguration

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Label("SwiftTerm terminal", systemImage: "terminal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MailDesignTokens.textPrimary)

                Text(commandDescription)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(MailDesignTokens.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MailDesignTokens.surfaceMuted)

            EmbeddedAssistantTerminal(configuration: configuration)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.94))
                .accessibilityIdentifier("assistant-terminal")
        }
    }

    private var commandDescription: String {
        ([configuration.executable] + configuration.arguments).joined(separator: " ")
            + "  ·  "
            + configuration.currentDirectory
    }
}

private struct AssistantPanelCard: View {
    let icon: String
    let title: String
    let detail: String

    init(icon: String, title: String, body: String) {
        self.icon = icon
        self.title = title
        self.detail = body
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(MailDesignTokens.accent)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MailDesignTokens.textPrimary)
            Text(detail)
                .font(.system(size: 12))
                .lineSpacing(2)
                .foregroundStyle(MailDesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MailDesignTokens.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct AssistantCapabilityRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MailDesignTokens.accent)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MailDesignTokens.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(MailDesignTokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private extension AssistantSidebarMode {
    var title: String {
        switch self {
        case .agent: "Agent"
        case .terminal: "Terminal"
        }
    }

    var subtitle: String {
        switch self {
        case .agent: "ACP + native UI"
        case .terminal: "Provider CLI escape hatch"
        }
    }

    var systemImage: String {
        switch self {
        case .agent: "sparkles"
        case .terminal: "terminal"
        }
    }
}
