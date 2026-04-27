import MailCore
import SwiftUI

public struct AccountChip: View {
    private let text: String

    public init(text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(MailDesignTokens.accentStrong)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(MailDesignTokens.chipBackground)
            .clipShape(Capsule())
    }
}

// MARK: - Label Chip (compact, for thread rows)

public struct LabelChip: View {
    private let text: String
    private let bgHex: String?
    private let textHex: String?
    private let maxWidth: CGFloat?

    public init(text: String, bgHex: String? = nil, textHex: String? = nil, maxWidth: CGFloat? = nil) {
        self.text = text
        self.bgHex = bgHex
        self.textHex = textHex
        self.maxWidth = maxWidth
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(textHex.map { Color(hex: $0) } ?? MailDesignTokens.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .background(bgHex.map { Color(hex: $0) } ?? MailDesignTokens.chipBackground)
            .clipShape(Capsule())
    }
}

// MARK: - Dense Thread Row (Superhuman-style)

public struct AccountAvatar: Sendable, Equatable {
    public let initial: String
    public let colorHex: String
    public var color: Color {
        Color(hex: colorHex)
    }

    public init(initial: String, colorHex: String) {
        self.initial = initial
        self.colorHex = colorHex
    }
}

public enum ThreadRowDensity: String, CaseIterable, Identifiable, Sendable {
    case compact
    case comfortable

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .compact:
            "Compact"
        case .comfortable:
            "Comfortable"
        }
    }
}

public struct ThreadRowView: View, Equatable {
    private static let selectionAccessoryWidth: CGFloat = 22

    private let thread: MailThread
    private let accountText: String
    private let isSelected: Bool
    private let isHovered: Bool
    private let isMultiSelectActive: Bool
    private let isMultiSelected: Bool
    private let accountAvatar: AccountAvatar?
    private let density: ThreadRowDensity
    private let onToggleStar: (() -> Void)?

    public nonisolated static func == (lhs: ThreadRowView, rhs: ThreadRowView) -> Bool {
        lhs.thread == rhs.thread &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isHovered == rhs.isHovered &&
        lhs.isMultiSelectActive == rhs.isMultiSelectActive &&
        lhs.isMultiSelected == rhs.isMultiSelected &&
        lhs.accountText == rhs.accountText &&
        lhs.accountAvatar == rhs.accountAvatar &&
        lhs.density == rhs.density
    }

    public init(
        thread: MailThread,
        accountText: String,
        isSelected: Bool,
        isHovered: Bool = false,
        isMultiSelectActive: Bool = false,
        isMultiSelected: Bool = false,
        accountAvatar: AccountAvatar? = nil,
        density: ThreadRowDensity = .comfortable,
        onToggleStar: (() -> Void)? = nil
    ) {
        self.thread = thread
        self.accountText = accountText
        self.isSelected = isSelected
        self.isHovered = isHovered
        self.isMultiSelectActive = isMultiSelectActive
        self.isMultiSelected = isMultiSelected
        self.accountAvatar = accountAvatar
        self.density = density
        self.onToggleStar = onToggleStar
    }

    public var body: some View {
        let metrics = Metrics(density: density)
        HStack(spacing: 0) {
            // Unread indicator
            Circle()
                .fill(thread.hasUnread ? MailDesignTokens.unread : Color.clear)
                .frame(width: 6, height: 6)
                .padding(.trailing, metrics.unreadIndicatorTrailingPadding)

            // Star
            Group {
                if let onToggleStar {
                    Button(action: onToggleStar) {
                        Image(systemName: thread.isStarred ? "star.fill" : "star")
                            .font(.system(size: metrics.starFontSize))
                            .foregroundStyle(thread.isStarred ? Color.yellow : MailDesignTokens.textTertiary)
                            .frame(width: metrics.starFrame, height: metrics.starFrame)
                    }
                    .buttonStyle(.plain)
                    .help(thread.isStarred ? "Unstar" : "Star")
                    .accessibilityIdentifier("thread-row-star-\(thread.id.rawValue)")
                } else {
                    Image(systemName: thread.isStarred ? "star.fill" : "star")
                        .font(.system(size: metrics.starFontSize))
                        .foregroundStyle(thread.isStarred ? Color.yellow : MailDesignTokens.textTertiary)
                        .frame(width: metrics.starFrame, height: metrics.starFrame)
                }
            }
            .padding(.trailing, metrics.starTrailingPadding)

            // Sender / participant
            Text(thread.participantSummary)
                .font(.system(size: metrics.participantFontSize, weight: thread.hasUnread ? .semibold : .regular))
                .foregroundStyle(MailDesignTokens.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: metrics.participantWidth, alignment: .leading)

            // Labels (user-visible only)
            let visibleLabels = thread.mailboxRefs.filter { ref in
                ref.kind == .label && ref.systemRole == nil && !ref.isHiddenInLabelList
            }
            if !visibleLabels.isEmpty {
                HStack(spacing: 3) {
                    ForEach(visibleLabels.prefix(metrics.maxVisibleLabels), id: \.id) { label in
                        LabelChip(
                            text: label.displayName,
                            bgHex: label.colorHex,
                            textHex: label.textColorHex,
                            maxWidth: metrics.labelChipMaxWidth
                        )
                    }
                    if visibleLabels.count > metrics.maxVisibleLabels {
                        Text("+\(visibleLabels.count - metrics.maxVisibleLabels)")
                            .font(.system(size: metrics.labelOverflowFontSize, weight: .medium))
                            .foregroundStyle(MailDesignTokens.textTertiary)
                    }
                }
                .frame(width: metrics.labelsMaxWidth, alignment: .leading)
                .padding(.trailing, metrics.labelsTrailingPadding)
                .clipped()
            }

            // Subject + snippet
            HStack(spacing: metrics.subjectSnippetSpacing) {
                Text(thread.subject)
                    .font(.system(size: metrics.subjectFontSize, weight: thread.hasUnread ? .medium : .regular))
                    .foregroundStyle(MailDesignTokens.textPrimary)
                    .lineLimit(1)

                Text("—")
                    .font(.system(size: metrics.separatorFontSize))
                    .foregroundStyle(MailDesignTokens.textTertiary)

                Text(thread.snippet)
                    .font(.system(size: metrics.snippetFontSize))
                    .foregroundStyle(MailDesignTokens.textSecondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer(minLength: metrics.trailingSpacerMinimum)

            // Snooze indicator
            if thread.isSnoozed {
                Image(systemName: "clock")
                    .font(.system(size: metrics.statusIconFontSize))
                    .foregroundStyle(.orange)
                    .padding(.trailing, metrics.statusIconTrailingPadding)
                    .fixedSize()
            }

            // Attachment indicator
            if thread.attachmentCount > 0 {
                HStack(spacing: metrics.attachmentSpacing) {
                    Image(systemName: "paperclip")
                        .font(.system(size: metrics.statusIconFontSize))
                    if thread.attachmentCount > 1 {
                        Text("\(thread.attachmentCount)")
                            .font(.system(size: metrics.statusIconFontSize).monospacedDigit())
                    }
                }
                .foregroundStyle(MailDesignTokens.textTertiary)
                .padding(.trailing, metrics.attachmentTrailingPadding)
                .fixedSize()
            }

            // Time
            Text(relativeTime(thread.lastActivityAt))
                .font(.system(size: metrics.timeFontSize).monospacedDigit())
                .foregroundStyle(thread.hasUnread ? MailDesignTokens.textPrimary : MailDesignTokens.textSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            // Account avatar (All view only)
            if let avatar = accountAvatar {
                Text(avatar.initial)
                    .font(.system(size: metrics.avatarFontSize, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: metrics.avatarSize, height: metrics.avatarSize)
                    .background(avatar.color)
                    .clipShape(Circle())
                    .padding(.leading, metrics.avatarLeadingPadding)
            }

            ZStack(alignment: .trailing) {
                if isMultiSelectActive {
                    Image(systemName: isMultiSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: metrics.selectionAccessoryFontSize))
                        .foregroundStyle(isMultiSelected ? MailDesignTokens.accent : MailDesignTokens.textTertiary)
                }
            }
            .frame(width: Self.selectionAccessoryWidth)
            .padding(.leading, metrics.selectionAccessoryLeadingPadding)
        }
        .padding(.horizontal, metrics.rowHorizontalPadding)
        .padding(.vertical, metrics.rowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? MailDesignTokens.selected : isHovered ? MailDesignTokens.selected.opacity(0.4) : Color.clear)
        .contentShape(Rectangle())
    }

    private struct Metrics {
        let unreadIndicatorTrailingPadding: CGFloat
        let starFontSize: CGFloat
        let starFrame: CGFloat
        let starTrailingPadding: CGFloat
        let participantFontSize: CGFloat
        let participantWidth: CGFloat
        let labelsMaxWidth: CGFloat
        let labelsTrailingPadding: CGFloat
        let labelChipMaxWidth: CGFloat
        let labelOverflowFontSize: CGFloat
        let maxVisibleLabels: Int
        let subjectSnippetSpacing: CGFloat
        let subjectFontSize: CGFloat
        let separatorFontSize: CGFloat
        let snippetFontSize: CGFloat
        let trailingSpacerMinimum: CGFloat
        let statusIconFontSize: CGFloat
        let statusIconTrailingPadding: CGFloat
        let attachmentSpacing: CGFloat
        let attachmentTrailingPadding: CGFloat
        let timeFontSize: CGFloat
        let avatarFontSize: CGFloat
        let avatarSize: CGFloat
        let avatarLeadingPadding: CGFloat
        let selectionAccessoryFontSize: CGFloat
        let selectionAccessoryLeadingPadding: CGFloat
        let rowHorizontalPadding: CGFloat
        let rowVerticalPadding: CGFloat

        init(density: ThreadRowDensity) {
            switch density {
            case .compact:
                unreadIndicatorTrailingPadding = 8
                starFontSize = 11
                starFrame = 16
                starTrailingPadding = 10
                participantFontSize = 13
                participantWidth = 160
                labelsMaxWidth = 128
                labelsTrailingPadding = 8
                labelChipMaxWidth = 58
                labelOverflowFontSize = 9
                maxVisibleLabels = 2
                subjectSnippetSpacing = 6
                subjectFontSize = 13
                separatorFontSize = 12
                snippetFontSize = 12
                trailingSpacerMinimum = 8
                statusIconFontSize = 10
                statusIconTrailingPadding = 4
                attachmentSpacing = 2
                attachmentTrailingPadding = 6
                timeFontSize = 11
                avatarFontSize = 9
                avatarSize = 18
                avatarLeadingPadding = 8
                selectionAccessoryFontSize = 14
                selectionAccessoryLeadingPadding = 8
                rowHorizontalPadding = 16
                rowVerticalPadding = 8
            case .comfortable:
                unreadIndicatorTrailingPadding = 10
                starFontSize = 12
                starFrame = 18
                starTrailingPadding = 12
                participantFontSize = 14
                participantWidth = 174
                labelsMaxWidth = 154
                labelsTrailingPadding = 10
                labelChipMaxWidth = 68
                labelOverflowFontSize = 10
                maxVisibleLabels = 2
                subjectSnippetSpacing = 7
                subjectFontSize = 14
                separatorFontSize = 13
                snippetFontSize = 13
                trailingSpacerMinimum = 10
                statusIconFontSize = 11
                statusIconTrailingPadding = 5
                attachmentSpacing = 3
                attachmentTrailingPadding = 8
                timeFontSize = 12
                avatarFontSize = 10
                avatarSize = 20
                avatarLeadingPadding = 10
                selectionAccessoryFontSize = 15
                selectionAccessoryLeadingPadding = 10
                rowHorizontalPadding = 16
                rowVerticalPadding = 11
            }
        }
    }

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        if interval < 604800 { return "\(Int(interval / 86400))d" }
        return Self.shortDateFormatter.string(from: date)
    }
}

// MARK: - Sidebar Item

public struct SidebarItemView: View {
    private let title: String
    private let systemImage: String
    private let isSelected: Bool
    private let count: Int?

    public init(title: String, systemImage: String, isSelected: Bool, count: Int? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.count = count
    }

    public var body: some View {
        SidebarRow(isSelected: isSelected) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(isSelected ? MailDesignTokens.sidebarText.opacity(0.7) : MailDesignTokens.sidebarMuted)
                }
            }
            .foregroundStyle(isSelected ? MailDesignTokens.sidebarText : MailDesignTokens.sidebarMuted)
        }
    }
}

// MARK: - Mailbox Sidebar Item

public struct MailboxSidebarItem: View {
    private let mailbox: MailboxRef
    private let isSelected: Bool

    public init(mailbox: MailboxRef, isSelected: Bool) {
        self.mailbox = mailbox
        self.isSelected = isSelected
    }

    public var body: some View {
        SidebarRow(isSelected: isSelected, verticalPadding: 4, cornerRadius: 6) {
            HStack(spacing: 8) {
                if let colorHex = mailbox.colorHex {
                    Circle()
                        .fill(Color(hex: colorHex))
                        .frame(width: 8, height: 8)
                } else {
                    Image(systemName: iconForMailbox(mailbox))
                        .font(.system(size: 11))
                        .frame(width: 18)
                }
                Text(mailbox.displayName)
                    .font(.system(size: 12, weight: .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? MailDesignTokens.sidebarText : MailDesignTokens.sidebarMuted)
        }
    }

    private func iconForMailbox(_ mailbox: MailboxRef) -> String {
        switch mailbox.systemRole {
        case .inbox: return "tray"
        case .sent: return "paperplane"
        case .draft: return "doc.text"
        case .archive: return "archivebox"
        case .trash: return "trash"
        case .spam: return "exclamationmark.shield"
        case .starred: return "star"
        case .important: return "flag"
        case .unread: return "envelope.badge"
        case .custom, .none: return "tag"
        }
    }
}

public struct SidebarRow<Content: View>: View {
    private let isSelected: Bool
    private let horizontalPadding: CGFloat
    private let verticalPadding: CGFloat
    private let cornerRadius: CGFloat
    private let content: Content
    @State private var isHovered = false

    public init(
        isSelected: Bool = false,
        horizontalPadding: CGFloat = 10,
        verticalPadding: CGFloat = 6,
        cornerRadius: CGFloat = 8,
        @ViewBuilder content: () -> Content
    ) {
        self.isSelected = isSelected
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    public var body: some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backgroundColor)
            .overlay {
                if let borderColor {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { hovering in
                isHovered = hovering
            }
    }

    private var backgroundColor: Color {
        if isSelected {
            return MailDesignTokens.sidebarSelected
        }
        if isHovered {
            return MailDesignTokens.sidebarHover
        }
        return .clear
    }

    private var borderColor: Color? {
        if isSelected {
            return MailDesignTokens.accent.opacity(0.18)
        }
        if isHovered {
            return MailDesignTokens.accent.opacity(0.08)
        }
        return nil
    }
}

// MARK: - Keyboard Shortcut Overlay

public struct KeyboardShortcutOverlay: View {
    public init() {}

    private let shortcuts: [(key: String, action: String)] = [
        ("j / k", "Next / Previous"),
        ("Up / Down", "Next / Previous"),
        ("Enter", "Open thread"),
        ("Escape", "Back to list"),
        ("e", "Archive / Unarchive"),
        ("s", "Star / Unstar"),
        ("Shift+U", "Mark read / unread"),
        ("r", "Reply"),
        ("a", "Reply all"),
        ("f", "Forward"),
        ("c", "Compose"),
        ("#", "Trash"),
        ("h", "Snooze"),
        ("l", "Apply label"),
        ("v", "Move to folder"),
        ("z", "Undo"),
        ("x", "Toggle selected thread"),
        ("Shift+J/K", "Extend selection"),
        ("Shift+Up/Down", "Extend selection"),
        ("Cmd+A", "Select all"),
        ("/ or Cmd+K", "Search"),
        ("Cmd+B", "Toggle sidebar"),
        ("?", "Toggle shortcuts"),
        ("Cmd+R", "Refresh"),
    ]

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("KEYBOARD SHORTCUTS")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.bottom, 12)

            ForEach(shortcuts, id: \.key) { shortcut in
                HStack {
                    Text(shortcut.key)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(width: 80, alignment: .trailing)
                    Text(shortcut.action)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.vertical, 3)
            }
        }
        .padding(20)
        .background(.ultraThinMaterial.opacity(0.9))
        .background(Color.black.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Undo Toast

public struct UndoToast: View {
    let label: String
    let onUndo: () -> Void
    let onDismiss: () -> Void

    public init(label: String, onUndo: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.label = label
        self.onUndo = onUndo
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)

            Button {
                onUndo()
            } label: {
                Text("Undo")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MailDesignTokens.accent)
            }
            .buttonStyle(.plain)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(red: 0.15, green: 0.17, blue: 0.22))
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    }
}

// MARK: - Color Hex Extension

public extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255.0
        let g = Double((int >> 8) & 0xFF) / 255.0
        let b = Double(int & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
