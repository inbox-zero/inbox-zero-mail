import AppKit
import CryptoKit
import DesignSystem
import MailCore
import MailFeatures
import ProviderCore
import SwiftUI
import UniformTypeIdentifiers

enum MessageDetailTimestampFormatter {
    static func string(
        for date: Date,
        relativeTo now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.dateFormat = "h:mm a"
            return formatter.string(from: date)
        }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone

        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            formatter.dateFormat = "d MMMM"
        } else {
            formatter.dateFormat = "d MMMM yyyy"
        }

        return formatter.string(from: date)
    }
}

private extension View {
    func plainButtonHitArea() -> some View {
        contentShape(Rectangle())
    }
}

private enum AttachmentInteractionCancelled: Error {
    case userCancelled
}

private enum AttachmentFileCoordinator {
    static func open(attachment: MailAttachment, model: WindowModel) async throws {
        let fileURL = try await materializeCachedFile(for: attachment, model: model)
        guard NSWorkspace.shared.open(fileURL) else {
            throw MailProviderError.transport("Could not open \(attachment.filename).")
        }
    }

    @MainActor
    static func download(attachment: MailAttachment, model: WindowModel) async throws {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = userFacingFilename(attachment.filename)
        if let contentType = preferredContentType(for: attachment) {
            panel.allowedContentTypes = [contentType]
        }

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            throw AttachmentInteractionCancelled.userCancelled
        }

        let sourceURL = try await materializeCachedFile(for: attachment, model: model)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    private static func materializeCachedFile(for attachment: MailAttachment, model: WindowModel) async throws -> URL {
        let destinationURL = try cachedFileURL(for: attachment)
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: destinationURL.path) {
            let values = try? destinationURL.resourceValues(forKeys: [.fileSizeKey])
            if (values?.fileSize ?? 0) > 0 {
                return destinationURL
            }
        }

        let data = try await model.fetchAttachmentData(attachment)
        try data.write(to: destinationURL, options: .atomic)
        return destinationURL
    }

    private static func cachedFileURL(for attachment: MailAttachment) throws -> URL {
        let fileManager = FileManager.default
        guard let baseURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw MailProviderError.transport("Could not locate the app cache directory for attachments.")
        }

        let directoryURL = baseURL
            .appendingPathComponent("InboxZeroMail", isDirectory: true)
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent(safePathComponent(attachment.messageID.accountID.rawValue), isDirectory: true)
            .appendingPathComponent(safePathComponent(attachment.messageID.providerMessageID), isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        return directoryURL.appendingPathComponent(cachedFilename(for: attachment), isDirectory: false)
    }

    private static func cachedFilename(for attachment: MailAttachment) -> String {
        let filename = userFacingFilename(attachment.filename)
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        let safeStem = truncatedFilenameComponent(stem.isEmpty ? "attachment" : stem, maxLength: 48)
        let prefix = shortHash("\(attachment.messageID.accountID.rawValue)|\(attachment.messageID.providerMessageID)|\(attachment.id)")
        if ext.isEmpty {
            return "\(safeStem)-\(prefix)"
        }
        return "\(safeStem)-\(prefix).\(ext)"
    }

    private static func userFacingFilename(_ filename: String) -> String {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "attachment" : trimmed
        let sanitized = fallback
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let ext = (sanitized as NSString).pathExtension
        let stem = (sanitized as NSString).deletingPathExtension
        let safeStem = truncatedFilenameComponent(stem.isEmpty ? "attachment" : stem, maxLength: 96)
        if ext.isEmpty {
            return safeStem
        }
        let safeExt = truncatedFilenameComponent(ext, maxLength: 16)
        return "\(safeStem).\(safeExt)"
    }

    private static func safePathComponent(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? UUID().uuidString : trimmed
        return fallback
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    private static func truncatedFilenameComponent(_ value: String, maxLength: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength))
    }

    private static func shortHash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func preferredContentType(for attachment: MailAttachment) -> UTType? {
        let pathExtension = (attachment.filename as NSString).pathExtension
        if pathExtension.isEmpty == false, let type = UTType(filenameExtension: pathExtension) {
            return type
        }
        return UTType(mimeType: attachment.mimeType)
    }
}

struct PlainTextQuotedContent: Equatable {
    let visibleText: String
    let quotedText: String?
}

enum MessagePresentationRules {
    static func startsExpanded(message: MailMessage, isLastMessage: Bool) -> Bool {
        isLastMessage || !message.isRead
    }

    static func splitPlainTextQuotedContent(_ text: String) -> PlainTextQuotedContent {
        guard let quoteStart = firstQuotedSectionStart(in: text) else {
            return PlainTextQuotedContent(visibleText: text, quotedText: nil)
        }

        let visibleText = String(text[..<quoteStart]).trimmingCharacters(in: .whitespacesAndNewlines)
        let quotedText = String(text[quoteStart...]).trimmingCharacters(in: .whitespacesAndNewlines)

        guard visibleText.isEmpty == false, quotedText.isEmpty == false else {
            return PlainTextQuotedContent(visibleText: text, quotedText: nil)
        }

        return PlainTextQuotedContent(visibleText: visibleText, quotedText: quotedText)
    }

    private static func firstQuotedSectionStart(in text: String) -> String.Index? {
        let patterns = [
            #"(?m)^On .+wrote:\s*$"#,
            #"(?m)^>.*$"#,
            #"(?m)^-{2,}\s*Original Message\s*-{2,}\s*$"#,
            #"(?m)^-{2,}\s*Forwarded message\s*-{2,}\s*$"#,
        ]

        return patterns
            .compactMap { pattern in
                text.range(of: pattern, options: .regularExpression)?.lowerBound
            }
            .min()
    }
}

struct ContentView: View {
    @Bindable var model: WindowModel
    @State private var showShortcuts = false
    @AppStorage(AppPreferences.splitInboxTabsVersionKey) private var splitInboxTabsVersion = 0

    var body: some View {
        Group {
            switch model.layoutMode {
            case .focus:
                focusLayout
            case .split:
                splitLayout
            }
        }
        .alert("Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.dismissError() } })) {
            if let reconnectAccountID = model.errorReconnectAccountID {
                Button("Sign In Again") {
                    model.reconnect(accountID: reconnectAccountID)
                }
            }
            Button("OK", role: .cancel) { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .overlay(alignment: .bottom) {
            if let undo = model.undoAction {
                UndoToast(
                    label: undo.label,
                    onUndo: { model.performUndo() },
                    onDismiss: { model.dismissUndo() }
                )
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(response: 0.3), value: model.undoAction != nil)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if model.composeMode == .floating, let draft = model.composeDraft {
                FloatingComposeView(model: model, draft: draft)
                    .padding(20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.spring(response: 0.3), value: model.composeMode != nil)
            }
        }
        .overlay(alignment: .center) {
            if showShortcuts {
                KeyboardShortcutOverlay()
                    .transition(.opacity)
                    .onTapGesture { showShortcuts = false }
            }
        }
        .overlay {
            if model.isCommandPalettePresented {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { model.closeCommandPalette() }
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            if model.isCommandPalettePresented {
                CommandPaletteOverlay(model: model)
                    .padding(.top, 56)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $model.isTagPickerPresented) {
            TagPickerSheet(model: model)
        }
        .sheet(isPresented: $model.isFolderPickerPresented) {
            FolderPickerSheet(model: model)
        }
        .sheet(isPresented: $model.isSnoozePickerPresented) {
            SnoozePickerSheet(model: model)
        }
        .modifier(KeyboardMonitor(model: model, showShortcuts: $showShortcuts))
        .focusedValue(\.windowModel, model)
        .task(id: splitInboxTabsVersion) {
            model.setSplitInboxItems(AppPreferences.configuredSplitInboxItems())
        }
    }

    // MARK: - Focus Layout (Superhuman-style)

    private var focusLayout: some View {
        HStack(spacing: 0) {
            if model.isSidebarVisible {
                SidebarView(model: model)
                    .frame(width: 260)
                    .background(MailDesignTokens.sidebar)
                    .transition(.move(edge: .leading).combined(with: .opacity))

                Divider()
            }

            VStack(spacing: 0) {
                // Minimal top bar
                FocusTopBar(model: model)

                // Content area transitions between list and detail
                ZStack {
                    if model.isThreadOpen {
                        ThreadDetailPane(model: model)
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .trailing).combined(with: .opacity)
                            ))
                    } else {
                        ThreadListPane(model: model)
                            .transition(.asymmetric(
                                insertion: .move(edge: .leading).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)
                            ))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: model.isThreadOpen)
            }
            .background(MailDesignTokens.background)
        }
        .animation(.easeInOut(duration: 0.2), value: model.isSidebarVisible)
        .background(MailDesignTokens.background)
    }

    // MARK: - Split Layout (traditional 3-column)

    private var splitLayout: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SidebarView(model: model)
                .frame(minWidth: 220, idealWidth: 240)
                .background(MailDesignTokens.sidebar)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } content: {
            ThreadListPane(model: model)
                .frame(minWidth: 360)
                .navigationSplitViewColumnWidth(min: 360, ideal: 420, max: 520)
        } detail: {
            ThreadDetailPane(model: model)
                .frame(minWidth: 400)
        }
        .navigationSplitViewStyle(.balanced)
        .background(MailDesignTokens.background)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                SplitLayoutToolbarContent(model: model)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.openCommandPalette()
                } label: {
                    Image(systemName: "command")
                        .font(.system(size: 13))
                }
                .help("Command Palette (Cmd+K)")

                Button {
                    model.openCompose()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13))
                }
                .accessibilityIdentifier("toolbar-compose")
                .help("Compose (C)")
            }
        }
    }
}

private struct SplitLayoutToolbarContent: View {
    @Bindable var model: WindowModel
    @AppStorage(AppPreferences.splitInboxTabsVersionKey) private var splitInboxTabsVersion = 0

    private var visibleSplitInboxItems: [SplitInboxItem] {
        AppPreferences.configuredSplitInboxItems()
    }

    var body: some View {
        let _ = splitInboxTabsVersion
        Group {
            if model.isMultiSelectActive {
                MultiSelectHeaderContent(model: model)
            } else if model.isSplitInboxVisible {
                SplitInboxBar(model: model, items: visibleSplitInboxItems, placement: .topBar)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(listTitle)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(MailDesignTokens.textPrimary)
                        .accessibilityIdentifier("thread-list-title")
                    if let accountID = model.selectedAccountID,
                       let account = model.accounts.first(where: { $0.id == accountID }) {
                        Text(account.primaryEmail)
                            .font(.system(size: 11))
                            .foregroundStyle(MailDesignTokens.textSecondary)
                    }
                }
            }
        }
        .frame(width: 420, alignment: .leading)
    }

    private var listTitle: String {
        if model.isAllMailSelected {
            return "All Mail"
        }
        if let selectedMailboxID = model.selectedMailboxID,
           let mailbox = model.mailboxes.first(where: { $0.id == selectedMailboxID }) {
            return mailbox.displayName
        }
        return model.currentSplitInboxTitle
    }
}

// MARK: - Focus Mode Top Bar

private struct FocusTopBar: View {
    @Bindable var model: WindowModel
    @AppStorage(AppPreferences.splitInboxTabsVersionKey) private var splitInboxTabsVersion = 0

    private var visibleSplitInboxItems: [SplitInboxItem] {
        AppPreferences.configuredSplitInboxItems()
    }

    var body: some View {
        let _ = splitInboxTabsVersion
        Group {
            if isMultiSelectHeaderVisible {
                MultiSelectHeaderContent(model: model)
            } else {
                HStack(spacing: 12) {
                    // Sidebar toggle
                    Button {
                        model.toggleSidebar()
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(MailDesignTokens.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Toggle sidebar (Cmd+\\)")

                    if model.isSearchFocused || !model.searchText.isEmpty {
                        // Search bar
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 12))
                                .foregroundStyle(MailDesignTokens.textTertiary)
                            TextField("Search mail...", text: $model.searchText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .onSubmit { model.submitSearch() }
                            if !model.searchText.isEmpty {
                                Button {
                                    model.cancelSearch()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundStyle(MailDesignTokens.textTertiary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(MailDesignTokens.surfaceMuted)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                        Spacer()
                    } else if model.isThreadOpen {
                        // Back button when viewing a thread
                        Button {
                            model.closeThread()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(model.currentSplitInboxTitle)
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .foregroundStyle(MailDesignTokens.accent)
                            .plainButtonHitArea()
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("thread-detail-back")

                        Spacer()

                        // Thread position indicator
                        if let idx = model.threads.firstIndex(where: { $0.id == model.selectedThreadID }) {
                            Text("\(idx + 1) of \(model.threads.count)")
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(MailDesignTokens.textTertiary)
                        }
                    } else {
                        if model.isSplitInboxVisible {
                            SplitInboxBar(model: model, items: visibleSplitInboxItems, placement: .topBar)
                                .padding(.leading, 6)
                        } else {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(listTitle)
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(MailDesignTokens.textPrimary)
                                    .accessibilityIdentifier("thread-list-title")
                                if let accountID = model.selectedAccountID,
                                   let account = model.accounts.first(where: { $0.id == accountID }) {
                                    Text(account.primaryEmail)
                                        .font(.system(size: 11))
                                        .foregroundStyle(MailDesignTokens.textSecondary)
                                }
                            }

                            Spacer()
                        }
                    }

                    if model.isThreadOpen == false,
                       model.isSearchFocused == false,
                       model.searchText.isEmpty {
                        Button {
                            model.openCompose()
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 12))
                                .foregroundStyle(MailDesignTokens.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("toolbar-compose")
                        .help("Compose (C)")

                        Button {
                            model.beginSearch()
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 12))
                                .foregroundStyle(MailDesignTokens.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Search (/)")

                        Button {
                            model.openCommandPalette()
                        } label: {
                            Image(systemName: "command")
                                .font(.system(size: 12))
                                .foregroundStyle(MailDesignTokens.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Command Palette (Cmd+K)")
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(MailDesignTokens.surface)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var listTitle: String {
        if model.isAllMailSelected {
            return "All Mail"
        }
        if let selectedMailboxID = model.selectedMailboxID,
           let mailbox = model.mailboxes.first(where: { $0.id == selectedMailboxID }) {
            return mailbox.displayName
        }
        return model.currentSplitInboxTitle
    }

    private var isMultiSelectHeaderVisible: Bool {
        model.isThreadOpen == false
            && model.isSearchFocused == false
            && model.searchText.isEmpty
            && model.isMultiSelectActive
    }
}

private struct MultiSelectHeaderContent: View {
    @Bindable var model: WindowModel

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if allVisibleThreadsSelected {
                    model.deselectAll()
                } else {
                    model.selectAll()
                }
            } label: {
                Image(systemName: allVisibleThreadsSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(allVisibleThreadsSelected ? MailDesignTokens.accent : MailDesignTokens.textSecondary)
            }
            .buttonStyle(.plain)
            .help(allVisibleThreadsSelected ? "Deselect all visible threads" : "Select all visible threads")
            .accessibilityIdentifier("thread-select-all")

            VStack(alignment: .leading, spacing: 1) {
                Text("\(model.multiSelectedIDs.count) selected")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(MailDesignTokens.textPrimary)

                if model.multiSelectedIDs.count < model.threads.count {
                    Button("Select all") {
                        model.selectAll()
                    }
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(MailDesignTokens.textSecondary)
                }
            }

            Spacer()

            Button("Clear") {
                model.deselectAll()
            }
            .font(.system(size: 11, weight: .medium))
            .buttonStyle(.plain)
            .foregroundStyle(MailDesignTokens.textSecondary)
            .accessibilityIdentifier("thread-selection-done")
        }
    }

    private var allVisibleThreadsSelected: Bool {
        model.threads.isEmpty == false && model.multiSelectedIDs.count >= model.threads.count
    }
}

func commandPaletteBaseItems(model: WindowModel) -> [CommandPaletteItem] {
    var items: [CommandPaletteItem] = []

    // Accounts at the top for quick switching.
    if model.accounts.count > 1 {
        items.append(
            makeCommandPaletteItem(
                model: model,
                id: "account-all",
                title: "All Accounts",
                subtitle: "Show mail from every account",
                category: "Accounts",
                systemImage: "tray.2",
                searchText: "account all everyone every inbox"
            ) {
                model.select(accountID: nil)
            }
        )
        items.append(contentsOf: model.accounts.map { account in
            makeCommandPaletteItem(
                model: model,
                id: "account-\(account.id.rawValue)",
                title: account.displayName,
                subtitle: account.primaryEmail,
                category: "Accounts",
                systemImage: account.providerKind.systemImageName,
                searchText: "account mailbox \(account.displayName) \(account.primaryEmail)"
            ) {
                model.select(accountID: account.id)
            }
        })
    }

    items.append(contentsOf: [
        makeCommandPaletteItem(
            model: model,
            id: "action-compose",
            title: "New message",
            subtitle: "Start a new email",
            category: "Actions",
            systemImage: "square.and.pencil",
            searchText: "compose new email message draft",
            shortcut: .init("c", display: "C")
        ) {
            model.openCompose()
        },
        makeCommandPaletteItem(
            model: model,
            id: "action-search",
            title: "Search mail",
            subtitle: "Open the inline thread search",
            category: "Actions",
            systemImage: "magnifyingglass",
            searchText: "search find filter slash",
            shortcut: .init("/", display: "/")
        ) {
            model.beginSearch()
        },
        makeCommandPaletteItem(
            model: model,
            id: "action-refresh",
            title: "Refresh inbox",
            subtitle: "Sync the current mailbox",
            category: "Actions",
            systemImage: "arrow.clockwise",
            searchText: "refresh sync reload fetch",
            shortcut: .init("r", modifiers: [.command], display: "⌘R", requiresEmptyQuery: false)
        ) {
            model.refresh()
        },
        makeCommandPaletteItem(
            model: model,
            id: "action-sidebar",
            title: model.isSidebarVisible ? "Hide sidebar" : "Show sidebar",
            subtitle: "Toggle mailbox navigation",
            category: "Actions",
            systemImage: "sidebar.leading",
            searchText: "sidebar navigation toggle",
            shortcut: .init("\\", modifiers: [.command], display: "⌘\\", requiresEmptyQuery: false)
        ) {
            model.toggleSidebar()
        },
        makeCommandPaletteItem(
            model: model,
            id: "nav-all",
            title: "Inbox",
            subtitle: "View all inbox threads",
            category: "Navigation",
            systemImage: "tray",
            searchText: "inbox all tab"
        ) {
            model.select(tab: .all)
        },
        makeCommandPaletteItem(
            model: model,
            id: "nav-unread",
            title: "Unread",
            subtitle: "View unread threads",
            category: "Navigation",
            systemImage: "envelope.badge",
            searchText: "unread tab"
        ) {
            model.select(tab: .unread)
        },
        makeCommandPaletteItem(
            model: model,
            id: "nav-starred",
            title: "Starred",
            subtitle: "View starred threads",
            category: "Navigation",
            systemImage: "star",
            searchText: "starred favorites tab"
        ) {
            model.select(tab: .starred)
        },
        makeCommandPaletteItem(
            model: model,
            id: "nav-snoozed",
            title: "Snoozed",
            subtitle: "View snoozed threads",
            category: "Navigation",
            systemImage: "clock",
            searchText: "snoozed later tab"
        ) {
            model.select(tab: .snoozed)
        },
        makeCommandPaletteItem(
            model: model,
            id: "nav-all-mail",
            title: model.selectedAccountID == nil ? "All Mail" : "All Mail in selected account",
            subtitle: "Leave Inbox-only mode",
            category: "Navigation",
            systemImage: "archivebox",
            searchText: "all mail archive everything"
        ) {
            model.selectAllMail(accountID: model.selectedAccountID)
        },
    ])

    if let focusedThread = model.focusedThread {
        items.append(
            makeCommandPaletteItem(
                model: model,
                id: "thread-open-selected",
                title: "Open thread",
                subtitle: focusedThread.subject,
                category: "Selection",
                systemImage: "envelope.open",
                searchText: "open current selected thread"
            ) {
                model.open(threadID: focusedThread.id)
            }
        )
        items.append(
            makeCommandPaletteItem(
                model: model,
                id: "thread-archive",
                title: focusedThread.isInInbox ? "Archive thread" : "Unarchive thread",
                subtitle: focusedThread.subject,
                category: "Selection",
                systemImage: focusedThread.isInInbox ? "archivebox" : "tray.and.arrow.up",
                searchText: focusedThread.isInInbox ? "archive selected thread" : "unarchive selected thread move back to inbox",
                shortcut: .init("e", display: "E")
            ) {
                model.toggleArchiveSelection()
            }
        )
        items.append(
            makeCommandPaletteItem(
                model: model,
                id: "thread-read",
                title: focusedThread.hasUnread ? "Mark as read" : "Mark as unread",
                subtitle: focusedThread.subject,
                category: "Selection",
                systemImage: focusedThread.hasUnread ? "envelope.open" : "envelope.badge",
                searchText: "read unread selected thread",
                shortcut: .init("u", modifiers: [.shift], display: "⇧U")
            ) {
                model.toggleReadSelection()
            }
        )
        items.append(
            makeCommandPaletteItem(
                model: model,
                id: "thread-star",
                title: focusedThread.isStarred ? "Remove star" : "Star thread",
                subtitle: focusedThread.subject,
                category: "Selection",
                systemImage: focusedThread.isStarred ? "star.slash" : "star",
                searchText: "star unstar favorite selected thread",
                shortcut: .init("s", display: "S")
            ) {
                model.toggleStarSelection()
            }
        )
        items.append(
            makeCommandPaletteItem(
                model: model,
                id: "thread-trash",
                title: "Move thread to trash",
                subtitle: focusedThread.subject,
                category: "Selection",
                systemImage: "trash",
                searchText: "trash delete selected thread",
                shortcut: .init("#", display: "#")
            ) {
                model.trashSelection()
            }
        )
        items.append(
            makeCommandPaletteItem(
                model: model,
                id: "thread-reply",
                title: "Reply",
                subtitle: focusedThread.subject,
                category: "Selection",
                systemImage: "arrowshape.turn.up.left",
                searchText: "reply respond selected thread",
                shortcut: .init("r", display: "R")
            ) {
                model.openCompose(replyMode: .reply)
            }
        )
        items.append(
            makeCommandPaletteItem(
                model: model,
                id: "thread-reply-all",
                title: "Reply all",
                subtitle: focusedThread.subject,
                category: "Selection",
                systemImage: "arrowshape.turn.up.left.2",
                searchText: "reply all group respond selected thread",
                shortcut: .init("a", display: "A")
            ) {
                model.openCompose(replyMode: .replyAll)
            }
        )
        items.append(
            makeCommandPaletteItem(
                model: model,
                id: "thread-forward",
                title: "Forward",
                subtitle: focusedThread.subject,
                category: "Selection",
                systemImage: "arrowshape.turn.up.right",
                searchText: "forward send selected thread",
                shortcut: .init("f", display: "F")
            ) {
                model.openCompose(replyMode: .forward)
            }
        )

        if !model.taggableMailboxesForFocusedThread.isEmpty {
            items.append(
                makeCommandPaletteItem(
                    model: model,
                    id: "thread-label",
                    title: model.mailboxTagActionTitle,
                    subtitle: model.mailboxTagActionSubtitle,
                    category: "Selection",
                    systemImage: "tag",
                    searchText: "label tag category selected thread",
                    shortcut: .init("l", display: "L")
                ) {
                    model.showTagPicker()
                }
            )
        }

        if !model.foldersForFocusedThread.isEmpty {
            items.append(
                makeCommandPaletteItem(
                    model: model,
                    id: "thread-folder",
                    title: "Move to folder",
                    subtitle: "Open folder picker",
                    category: "Selection",
                    systemImage: "folder",
                    searchText: "move folder selected thread",
                    shortcut: .init("v", display: "V")
                ) {
                    model.showFolderPicker()
                }
            )
        }

        items.append(
            makeCommandPaletteItem(
                model: model,
                id: "thread-snooze",
                title: focusedThread.isSnoozed ? "Unsnooze thread" : "Snooze thread",
                subtitle: focusedThread.subject,
                category: "Selection",
                systemImage: focusedThread.isSnoozed ? "clock.arrow.circlepath" : "clock.badge",
                searchText: focusedThread.isSnoozed ? "unsnooze restore selected thread" : "snooze later selected thread",
                shortcut: .init("h", display: "H")
            ) {
                model.performPrimarySnoozeAction()
            }
        )
    }

    items.append(contentsOf: model.mailboxes.map { mailbox in
        makeCommandPaletteItem(
            model: model,
            id: "mailbox-\(mailbox.id.rawValue)",
            title: mailbox.displayName,
            subtitle: mailbox.accountID.rawValue.replacingOccurrences(of: "gmail:", with: ""),
            category: "Mailboxes",
            systemImage: commandPaletteSystemImage(for: mailbox),
            searchText: "mailbox folder label category \(mailbox.displayName) \(mailbox.accountID.rawValue)"
        ) {
            model.select(mailboxID: mailbox.id)
        }
    })

    return items
}

private func makeCommandPaletteItem(
    model: WindowModel,
    id: String,
    title: String,
    subtitle: String,
    category: String,
    systemImage: String,
    searchText: String,
    shortcut: CommandPaletteShortcut? = nil,
    action: @escaping () -> Void
) -> CommandPaletteItem {
    CommandPaletteItem(
        id: id,
        title: title,
        subtitle: subtitle,
        category: category,
        systemImage: systemImage,
        searchableText: searchText,
        shortcut: shortcut
    ) {
        model.closeCommandPalette()
        action()
    }
}

private func commandPaletteSystemImage(for mailbox: MailboxRef) -> String {
    switch mailbox.kind {
    case .folder:
        return "folder"
    case .category:
        return "circle.hexagongrid"
    case .label:
        return "tag"
    case .system:
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

private struct CommandPaletteOverlay: View {
    @Bindable var model: WindowModel
    @FocusState private var isQueryFocused: Bool
    @State private var query = ""
    @State private var selectedIndex = 0

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var shortcutEnabledItems: [CommandPaletteItem] {
        items.filter { $0.shortcut != nil }
    }

    private var items: [CommandPaletteItem] {
        let items = commandPaletteBaseItems(model: model)
        guard !trimmedQuery.isEmpty else { return items }
        return items.filter { $0.matches(trimmedQuery) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(MailDesignTokens.textSecondary)

                TextField("Type a command or mailbox", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MailDesignTokens.textPrimary)
                    .tint(MailDesignTokens.accent)
                    .focused($isQueryFocused)
                    .onSubmit { activateSelection() }

                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(MailDesignTokens.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18))
                        .foregroundStyle(MailDesignTokens.textTertiary)
                    Text("No matches")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(MailDesignTokens.textPrimary)
                    Text("Try a command name or mailbox.")
                        .font(.system(size: 12))
                        .foregroundStyle(MailDesignTokens.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                Button {
                                    selectedIndex = index
                                    activateSelection()
                                } label: {
                                    CommandPaletteRow(item: item, isSelected: selectedIndex == index)
                                }
                                .buttonStyle(.plain)
                                .id(item.id)
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 420)
                    .scrollIndicators(.hidden)
                    .onAppear {
                        scrollSelection(into: proxy, animated: false)
                    }
                    .onChange(of: selectedIndex) { _, _ in
                        scrollSelection(into: proxy)
                    }
                    .onChange(of: items.map(\.id)) { _, _ in
                        scrollSelection(into: proxy, animated: false)
                    }
                }
            }
        }
        .frame(maxWidth: 680)
        .background(MailDesignTokens.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(MailDesignTokens.divider.opacity(0.8), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: 12)
        .padding(.horizontal, 24)
        .environment(\.colorScheme, .light)
        .background(
            CommandPaletteEventMonitor(
                isQueryEmpty: trimmedQuery.isEmpty,
                shortcutItems: shortcutEnabledItems,
                onMove: moveSelection,
                onSubmit: activateSelection,
                onScroll: moveSelection,
                onClose: { model.closeCommandPalette() }
            )
        )
        .onAppear {
            query = ""
            selectedIndex = 0
            DispatchQueue.main.async {
                isQueryFocused = true
            }
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
        }
        .onChange(of: items.map(\.id)) { _, ids in
            guard !ids.isEmpty else {
                selectedIndex = 0
                return
            }
            selectedIndex = min(selectedIndex, ids.count - 1)
        }
    }

    private func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), items.count - 1)
    }

    private func activateSelection() {
        guard items.indices.contains(selectedIndex) else { return }
        items[selectedIndex].perform()
    }

    private func scrollSelection(into proxy: ScrollViewProxy, animated: Bool = true) {
        guard items.indices.contains(selectedIndex) else { return }
        let scroll = {
            proxy.scrollTo(items[selectedIndex].id, anchor: .center)
        }
        if animated {
            withAnimation(.easeInOut(duration: 0.12)) {
                scroll()
            }
        } else {
            scroll()
        }
    }

}

private struct CommandPaletteRow: View {
    let item: CommandPaletteItem
    let isSelected: Bool

    private var inlineDetail: String? {
        guard item.subtitle.isEmpty == false else { return nil }
        switch item.category {
        case "Accounts", "Mailboxes", "Drafts":
            return item.subtitle
        default:
            return nil
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? MailDesignTokens.accent : MailDesignTokens.textSecondary)
                .frame(width: 18)

            Text(item.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MailDesignTokens.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 12)

            if let inlineDetail {
                Text(inlineDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(MailDesignTokens.textSecondary)
                    .lineLimit(1)
            }

            if let shortcut = item.shortcut {
                Text(shortcut.display)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isSelected ? MailDesignTokens.textPrimary : MailDesignTokens.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(MailDesignTokens.surfaceMuted)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(.leading, 12)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? MailDesignTokens.selected : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }
}

struct CommandPaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let category: String
    let systemImage: String
    let searchableText: String
    let shortcut: CommandPaletteShortcut?
    let perform: () -> Void

    func matches(_ query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return true }
        let haystack = [title, subtitle, category, searchableText].joined(separator: " ")
        return haystack.localizedCaseInsensitiveContains(normalized)
    }
}

private struct CommandPaletteEventMonitor: NSViewRepresentable {
    let isQueryEmpty: Bool
    let shortcutItems: [CommandPaletteItem]
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onScroll: (Int) -> Void
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isQueryEmpty: isQueryEmpty,
            shortcutItems: shortcutItems,
            onMove: onMove,
            onSubmit: onSubmit,
            onScroll: onScroll,
            onClose: onClose
        )
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.start()
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isQueryEmpty = isQueryEmpty
        context.coordinator.shortcutItems = shortcutItems
        context.coordinator.onMove = onMove
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onScroll = onScroll
        context.coordinator.onClose = onClose
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var isQueryEmpty: Bool
        var shortcutItems: [CommandPaletteItem]
        var onMove: (Int) -> Void
        var onSubmit: () -> Void
        var onScroll: (Int) -> Void
        var onClose: () -> Void
        private var monitor: Any?
        private var scrollAccumulator: CGFloat = 0
        private static let scrollThreshold: CGFloat = 2.0

        init(
            isQueryEmpty: Bool,
            shortcutItems: [CommandPaletteItem],
            onMove: @escaping (Int) -> Void,
            onSubmit: @escaping () -> Void,
            onScroll: @escaping (Int) -> Void,
            onClose: @escaping () -> Void
        ) {
            self.isQueryEmpty = isQueryEmpty
            self.shortcutItems = shortcutItems
            self.onMove = onMove
            self.onSubmit = onSubmit
            self.onScroll = onScroll
            self.onClose = onClose
        }

        deinit {
            stop()
        }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
                guard let self else { return event }
                if event.type == .scrollWheel {
                    let delta = event.scrollingDeltaY
                    guard delta != 0 else { return event }
                    self.scrollAccumulator += delta
                    let threshold = Self.scrollThreshold
                    var steps = 0
                    while self.scrollAccumulator >= threshold {
                        self.scrollAccumulator -= threshold
                        steps -= 1
                    }
                    while self.scrollAccumulator <= -threshold {
                        self.scrollAccumulator += threshold
                        steps += 1
                    }
                    if steps != 0 {
                        self.onScroll(steps)
                    }
                    return nil
                }

                switch event.keyCode {
                case 125:
                    self.onMove(1)
                    return nil
                case 126:
                    self.onMove(-1)
                    return nil
                case 36, 76:
                    self.onSubmit()
                    return nil
                case 53:
                    self.onClose()
                    return nil
                default:
                    if let item = self.shortcutMatch(for: event) {
                        item.perform()
                        return nil
                    }
                    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    if modifiers.contains(.command), event.charactersIgnoringModifiers == "k" {
                        self.onClose()
                        return nil
                    }
                    return event
                }
            }
        }

        func stop() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        private func shortcutMatch(for event: NSEvent) -> CommandPaletteItem? {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            return shortcutItems.first { item in
                guard let shortcut = item.shortcut else { return false }
                guard shortcut.matches(event: event, modifiers: modifiers) else { return false }
                if shortcut.requiresEmptyQuery == false {
                    return true
                }
                return isQueryEmpty
            }
        }
    }
}

struct CommandPaletteShortcut {
    let key: String
    let modifiers: NSEvent.ModifierFlags
    let display: String
    let requiresEmptyQuery: Bool

    init(_ key: String, modifiers: NSEvent.ModifierFlags = [], display: String, requiresEmptyQuery: Bool = true) {
        self.key = key
        self.modifiers = modifiers
        self.display = display
        self.requiresEmptyQuery = requiresEmptyQuery
    }

    func matches(event: NSEvent, modifiers eventModifiers: NSEvent.ModifierFlags) -> Bool {
        let normalizedModifiers = eventModifiers.intersection(.deviceIndependentFlagsMask)
        return normalizedModifiers == modifiers && event.charactersIgnoringModifiers == key
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    @Bindable var model: WindowModel
    @State private var expandedLabelAccounts: Set<String> = []
    @AppStorage(AppPreferences.accountAvatarColorsVersionKey) private var avatarSettingsVersion = 0
    @AppStorage(AppPreferences.splitInboxTabsVersionKey) private var splitInboxTabsVersion = 0

    private var systemMailboxes: [MailboxRef] {
        model.mailboxes.filter { $0.systemRole != nil && $0.systemRole != .custom }
    }

    private var visibleSplitInboxItems: [SplitInboxItem] {
        AppPreferences.configuredSplitInboxItems()
    }

    var body: some View {
        let _ = avatarSettingsVersion
        let _ = splitInboxTabsVersion
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                // App title
                HStack(spacing: 8) {
                    Image(systemName: "envelope")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Inbox Zero")
                        .font(.system(size: 15, weight: .bold))
                }
                .foregroundStyle(MailDesignTokens.sidebarText)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

                // Split inbox tabs
                SidebarSection("INBOX") {
                    ForEach(visibleSplitInboxItems) { item in
                        Button {
                            model.select(splitInboxItem: item)
                        } label: {
                            SidebarItemView(
                                title: item.normalizedTitle,
                                systemImage: iconForTab(item.tab),
                                isSelected: model.selectedSplitInboxItem.id == item.id && model.selectedAccountID == nil && model.selectedMailboxID == nil,
                                count: model.splitInboxCount(for: item)
                            )
                        }
                        .accessibilityIdentifier("tab-\(item.id)")
                        .buttonStyle(.plain)
                        .focusable(false)
                    }

                    Button {
                        model.selectAllMail()
                    } label: {
                        SidebarItemView(
                            title: "All Mail",
                            systemImage: "archivebox",
                            isSelected: model.isAllMailSelected && model.selectedAccountID == nil
                        )
                    }
                    .accessibilityIdentifier("tab-all-mail")
                    .buttonStyle(.plain)
                    .focusable(false)
                }

                // Accounts section
                if model.accounts.isEmpty == false {
                    SidebarSection("ACCOUNTS") {
                        ForEach(model.accounts) { account in
                            Button {
                                model.toggleAccountSelection(accountID: account.id)
                            } label: {
                                SidebarRow(isSelected: model.selectedAccountID == account.id) {
                                    HStack(spacing: 8) {
                                        // Avatar circle with initial
                                        Text(String(account.displayName.prefix(1)).uppercased())
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.white)
                                            .frame(width: 22, height: 22)
                                            .background(Color(hex: avatarColorHex(for: account)))
                                            .clipShape(Circle())

                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(account.displayName)
                                                .font(.system(size: 12, weight: .medium))
                                                .lineLimit(1)
                                            Text(account.primaryEmail)
                                                .font(.system(size: 10))
                                                .lineLimit(1)
                                                .foregroundStyle(MailDesignTokens.sidebarMuted)
                                        }
                                        .foregroundStyle(model.selectedAccountID == account.id ? MailDesignTokens.sidebarText : MailDesignTokens.sidebarMuted)

                                        Spacer()

                                        HStack(spacing: 6) {
                                            // Sync status dot
                                            if account.syncState.phase == .syncing {
                                                ProgressView()
                                                    .controlSize(.mini)
                                            } else if account.syncState.isErrorState {
                                                Image(systemName: "exclamationmark.circle.fill")
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(.red.opacity(0.8))
                                                    .help(syncErrorMessage(for: account))
                                            }

                                            Image(systemName: model.selectedAccountID == account.id ? "chevron.down" : "chevron.right")
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundStyle(model.selectedAccountID == account.id ? MailDesignTokens.sidebarText.opacity(0.7) : MailDesignTokens.sidebarMuted.opacity(0.8))
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .focusable(false)

                            // Per-account mailbox tree when this account is selected
                            if model.selectedAccountID == account.id {
                                let accountMailboxes = model.mailboxes.filter { $0.accountID == account.id }

                                if account.syncState.requiresReconnect {
                                    SidebarRow(horizontalPadding: 12, verticalPadding: 8, cornerRadius: 8) {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Label("Session expired", systemImage: "person.crop.circle.badge.exclamationmark")
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundStyle(MailDesignTokens.sidebarText)
                                            Text("Cached mail stays visible. Sign in again to resume sync.")
                                                .font(.system(size: 10))
                                                .foregroundStyle(MailDesignTokens.sidebarMuted)
                                                .fixedSize(horizontal: false, vertical: true)
                                            Button {
                                                model.reconnect(accountID: account.id)
                                            } label: {
                                                Label(model.isConnectingAccount ? "Signing In..." : "Sign In Again", systemImage: "arrow.clockwise")
                                                    .font(.system(size: 11, weight: .semibold))
                                                    .foregroundStyle(MailDesignTokens.sidebarText)
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(model.isConnectingAccount)
                                        }
                                    }
                                    .padding(.leading, 22)
                                    .padding(.bottom, 4)
                                }

                                if account.providerKind == .gmail {
                                    Button {
                                        model.selectAllMail(accountID: account.id)
                                    } label: {
                                        SidebarItemView(
                                            title: "All Mail",
                                            systemImage: "archivebox",
                                            isSelected: model.isAllMailSelected && model.selectedAccountID == account.id
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .focusable(false)
                                    .padding(.leading, 22)
                                }

                                // System mailboxes (inbox, sent, drafts, etc.)
                                let system = accountMailboxes.filter { $0.kind == .system && $0.systemRole != nil && $0.systemRole != .custom && $0.systemRole != .inbox && $0.systemRole != .unread && $0.systemRole != .starred }
                                if system.isEmpty == false {
                                    ForEach(system) { mailbox in
                                        mailboxButton(mailbox)
                                    }
                                }

                                // Labels (Gmail)
                                let labels = accountMailboxes.filter { $0.kind == .label || ($0.systemRole == .custom || ($0.systemRole == nil && $0.kind != .folder && $0.kind != .category && $0.kind != .system)) }
                                let visibleLabels = labels.filter { !$0.isHiddenInLabelList }
                                let hiddenLabels = labels.filter { $0.isHiddenInLabelList }
                                if labels.isEmpty == false {
                                    Text("LABELS")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(MailDesignTokens.sidebarMuted.opacity(0.5))
                                        .padding(.leading, 32)
                                        .padding(.top, 6)
                                        .padding(.bottom, 2)
                                    ForEach(visibleLabels) { mailbox in
                                        mailboxButton(mailbox)
                                    }
                                    let isExpanded = expandedLabelAccounts.contains(account.id.rawValue)
                                    if isExpanded {
                                        ForEach(hiddenLabels) { mailbox in
                                            mailboxButton(mailbox)
                                        }
                                    }
                                    if hiddenLabels.isEmpty == false {
                                        Button {
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                if isExpanded {
                                                    expandedLabelAccounts.remove(account.id.rawValue)
                                                } else {
                                                    expandedLabelAccounts.insert(account.id.rawValue)
                                                }
                                            }
                                        } label: {
                                            SidebarRow(horizontalPadding: 10, verticalPadding: 2, cornerRadius: 6) {
                                                HStack(spacing: 4) {
                                                    Text(isExpanded ? "Less" : "More")
                                                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                                        .font(.system(size: 8))
                                                }
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundStyle(MailDesignTokens.sidebarMuted.opacity(0.6))
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .focusable(false)
                                        .padding(.leading, 22)
                                    }
                                }

                                // Folders (Outlook)
                                let folders = accountMailboxes.filter { $0.kind == .folder }
                                if folders.isEmpty == false {
                                    Text("FOLDERS")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(MailDesignTokens.sidebarMuted.opacity(0.5))
                                        .padding(.leading, 32)
                                        .padding(.top, 6)
                                        .padding(.bottom, 2)
                                    ForEach(folders) { mailbox in
                                        mailboxButton(mailbox)
                                    }
                                }

                                // Categories (Outlook)
                                let categories = accountMailboxes.filter { $0.kind == .category }
                                if categories.isEmpty == false {
                                    Text("CATEGORIES")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(MailDesignTokens.sidebarMuted.opacity(0.5))
                                        .padding(.leading, 32)
                                        .padding(.top, 6)
                                        .padding(.bottom, 2)
                                    ForEach(categories) { mailbox in
                                        mailboxButton(mailbox)
                                    }
                                }
                            }
                        }
                    }
                }

                Spacer(minLength: 20)

                // Add account button
                if model.availableAccountProviders.isEmpty == false {
                    if model.availableAccountProviders.count == 1, let provider = model.availableAccountProviders.first {
                        Button {
                            model.connectAccount(kind: provider)
                        } label: {
                            SidebarRow {
                                HStack(spacing: 6) {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 13))
                                    Text("Add \(provider.displayName)")
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .foregroundStyle(MailDesignTokens.sidebarMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .disabled(model.isConnectingAccount)
                    } else {
                        Menu {
                            ForEach(model.availableAccountProviders, id: \.self) { provider in
                                Button("Add \(provider.displayName)") {
                                    model.connectAccount(kind: provider)
                                }
                            }
                        } label: {
                            SidebarRow {
                                HStack(spacing: 6) {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 13))
                                    Text("Add Account")
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .foregroundStyle(MailDesignTokens.sidebarMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .focusable(false)
                        .disabled(model.isConnectingAccount)
                    }
                }

                // Keyboard hint
                HStack(spacing: 4) {
                    Text("?")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(MailDesignTokens.sidebarMuted)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(MailDesignTokens.sidebarSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    Text("Shortcuts")
                        .font(.system(size: 10))
                        .foregroundStyle(MailDesignTokens.sidebarMuted)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .padding(8)
        }
        .scrollIndicators(.hidden)
    }

    private func iconForTab(_ tab: UnifiedTab) -> String {
        switch tab {
        case .all: return "tray"
        case .unread: return "envelope.badge"
        case .starred: return "star"
        case .snoozed: return "clock"
        }
    }

    private func avatarColorHex(for account: MailAccount) -> String {
        AppPreferences.effectiveAccountAvatarColorHex(for: account, accounts: model.accounts)
    }

    private func syncErrorMessage(for account: MailAccount) -> String {
        if account.syncState.requiresReconnect {
            return "This account needs to sign in again. Cached mail stays visible until you reconnect or remove the account."
        }
        if let description = account.syncState.lastErrorDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           description.isEmpty == false {
            return description
        }
        return "Sync failed"
    }

    @ViewBuilder
    private func mailboxButton(_ mailbox: MailboxRef) -> some View {
        Button {
            model.select(mailboxID: mailbox.id)
        } label: {
            MailboxSidebarItem(mailbox: mailbox, isSelected: model.selectedMailboxID == mailbox.id)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .contextMenu {
            if mailbox.kind == .label && mailbox.systemRole == nil {
                if mailbox.isHiddenInLabelList {
                    Button {
                        model.setMailboxHidden(mailbox.id, hidden: false)
                    } label: {
                        Label("Show in label list", systemImage: "eye")
                    }
                } else {
                    Button {
                        model.setMailboxHidden(mailbox.id, hidden: true)
                    } label: {
                        Label("Hide from label list", systemImage: "eye.slash")
                    }
                }
            }
        }
        .padding(.leading, 22)
    }
}

private struct SidebarSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(MailDesignTokens.sidebarMuted.opacity(0.6))
                .padding(.horizontal, 12)
                .padding(.top, 16)
                .padding(.bottom, 4)

            content
        }
    }
}

// MARK: - Thread List Pane

private struct ThreadListPane: View {
    @Bindable var model: WindowModel
    @AppStorage(AppPreferences.accountAvatarColorsVersionKey) private var avatarSettingsVersion = 0
    @AppStorage(AppPreferences.splitInboxTabsVersionKey) private var splitInboxTabsVersion = 0
    @AppStorage(AppPreferences.threadRowDensityKey)
    private var threadRowDensityRawValue = AppPreferences.defaultThreadRowDensity.rawValue

    private var visibleSplitInboxItems: [SplitInboxItem] {
        AppPreferences.configuredSplitInboxItems()
    }

    private var threadRowDensity: ThreadRowDensity {
        ThreadRowDensity(rawValue: threadRowDensityRawValue) ?? AppPreferences.defaultThreadRowDensity
    }

    var body: some View {
        let _ = avatarSettingsVersion
        let _ = splitInboxTabsVersion
        VStack(spacing: 0) {
            if model.isSplitInboxVisible && model.layoutMode == .split {
                SplitInboxBar(model: model, items: visibleSplitInboxItems, placement: .listHeader)
            }

            // Thread list
            if model.threads.isEmpty {
                EmptyThreadListView(model: model)
            } else {
                let dateHeaders = Self.computeDateHeaders(model.threads)
                let accountMap = Dictionary(
                    model.accounts.map { ($0.id, $0) },
                    uniquingKeysWith: { a, _ in a }
                )
                let showAvatar = model.selectedAccountID == nil

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.threads) { thread in
                                // Date group header
                                if let header = dateHeaders[thread.id] {
                                    Text(header.label)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(MailDesignTokens.textTertiary)
                                        .padding(.horizontal, 16)
                                        .padding(.top, header.isFirst ? 4 : 12)
                                        .padding(.bottom, 4)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(MailDesignTokens.surface)
                                }

                                let isMultiSelected = model.multiSelectedIDs.contains(thread.id)
                                let isHovered = model.hoveredThreadID == thread.id
                                ThreadRowView(
                                    thread: thread,
                                    accountText: Self.accountLabel(for: thread.accountID, in: accountMap),
                                    isSelected: model.selectedThreadID == thread.id,
                                    isHovered: isHovered && !model.isMultiSelectActive,
                                    isMultiSelectActive: model.isMultiSelectActive,
                                    isMultiSelected: isMultiSelected,
                                    accountAvatar: Self.accountAvatar(
                                        for: thread.accountID,
                                        in: accountMap,
                                        allAccounts: model.accounts,
                                        showAvatar: showAvatar
                                    ),
                                    density: threadRowDensity,
                                    onToggleStar: model.isMultiSelectActive ? nil : {
                                        model.hoveredThreadID = thread.id
                                        model.toggleStarSelection()
                                    }
                                )
                                .equatable()
                                .contentShape(Rectangle())
                                .background(isMultiSelected ? MailDesignTokens.selected.opacity(0.6) : Color.clear)
                                .accessibilityElement(children: .contain)
                                .accessibilityLabel("\(thread.participantSummary), \(thread.subject)")
                                .accessibilityValue(thread.snippet)
                                .accessibilityIdentifier("thread-row-\(thread.id.rawValue)")
                                .onTapGesture {
                                    if model.isMultiSelectActive {
                                        model.toggleMultiSelect(threadID: thread.id)
                                    } else {
                                        model.open(threadID: thread.id)
                                    }
                                }
                                .onHover { hovering in
                                    if !model.isMultiSelectActive {
                                        model.hoveredThreadID = hovering ? thread.id : nil
                                    }
                                }
                                .contextMenu {
                                    threadContextMenu(thread: thread)
                                }
                                .id(thread.id)

                                Divider()
                                    .padding(.leading, 46)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: model.selectedThreadID) { _, newID in
                        if let newID, model.isThreadOpen == false {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                proxy.scrollTo(newID, anchor: .center)
                            }
                        }
                    }
                    .onChange(of: model.hoverScrollGeneration) {
                        if let id = model.hoveredThreadID {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .background(MailDesignTokens.surface)
    }

    private static func accountLabel(for accountID: MailAccountID, in accounts: [MailAccountID: MailAccount]) -> String {
        accounts[accountID]?.displayName
            ?? accountID.rawValue.replacingOccurrences(of: "gmail:", with: "")
    }

    private static func accountAvatar(
        for accountID: MailAccountID,
        in accounts: [MailAccountID: MailAccount],
        allAccounts: [MailAccount],
        showAvatar: Bool
    ) -> AccountAvatar? {
        guard showAvatar, let account = accounts[accountID] else { return nil }
        return AccountAvatar(
            initial: String(account.displayName.prefix(1)).uppercased(),
            colorHex: AppPreferences.effectiveAccountAvatarColorHex(for: account, accounts: allAccounts)
        )
    }

    // MARK: - Pre-computed Date Headers

    private struct DateHeader {
        let label: String
        let isFirst: Bool
    }

    private static func computeDateHeaders(_ threads: [MailThread]) -> [MailThreadID: DateHeader] {
        var result: [MailThreadID: DateHeader] = [:]
        var previousKey: String?
        for (index, thread) in threads.enumerated() {
            let key = dateGroupKey(for: thread.lastActivityAt)
            if key != previousKey {
                result[thread.id] = DateHeader(
                    label: dateGroupLabel(for: thread.lastActivityAt),
                    isFirst: index == 0
                )
            }
            previousKey = key
        }
        return result
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func threadContextMenu(thread: MailThread) -> some View {
        Button {
            model.hoveredThreadID = thread.id
            model.toggleReadSelection()
        } label: {
            Label(thread.hasUnread ? "Mark as Read" : "Mark as Unread",
                  systemImage: thread.hasUnread ? "envelope.open" : "envelope.badge")
        }

        Button {
            model.hoveredThreadID = thread.id
            model.toggleStarSelection()
        } label: {
            Label(thread.isStarred ? "Unstar" : "Star",
                  systemImage: thread.isStarred ? "star.slash" : "star")
        }

        Divider()

        Button {
            model.hoveredThreadID = thread.id
            model.toggleArchiveSelection()
        } label: {
            Label(
                thread.isInInbox ? "Archive" : "Unarchive",
                systemImage: thread.isInInbox ? "archivebox" : "tray.and.arrow.up"
            )
        }

        Button {
            model.hoveredThreadID = thread.id
            model.performPrimarySnoozeAction()
        } label: {
            Label(thread.isSnoozed ? "Unsnooze" : "Snooze", systemImage: thread.isSnoozed ? "clock.arrow.circlepath" : "clock")
        }

        Divider()

        Button {
            model.hoveredThreadID = thread.id
            model.showTagPicker()
        } label: {
            Label("\(model.mailboxTagSingular)…", systemImage: "tag")
        }

        Divider()

        Button(role: .destructive) {
            model.hoveredThreadID = thread.id
            model.trashSelection()
        } label: {
            Label("Move to Trash", systemImage: "trash")
        }
    }

    // MARK: - Date Grouping

    private static func dateGroupKey(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "today" }
        if cal.isDateInYesterday(date) { return "yesterday" }
        let startOfWeek = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        let weekStart = cal.date(from: startOfWeek) ?? Date()
        if date >= weekStart { return "this_week" }
        let lastWeekStart = cal.date(byAdding: .weekOfYear, value: -1, to: weekStart)!
        if date >= lastWeekStart { return "last_week" }
        let components = cal.dateComponents([.year, .month], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)"
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM"
        return f
    }()

    private static let monthYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    private static func dateGroupLabel(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let startOfWeek = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        let weekStart = cal.date(from: startOfWeek) ?? Date()
        if date >= weekStart { return "This Week" }
        let lastWeekStart = cal.date(byAdding: .weekOfYear, value: -1, to: weekStart)!
        if date >= lastWeekStart { return "Last Week" }
        let formatter = cal.component(.year, from: date) == cal.component(.year, from: Date()) ? monthFormatter : monthYearFormatter
        return formatter.string(from: date)
    }
}

private struct SplitInboxBar: View {
    @Bindable var model: WindowModel
    let items: [SplitInboxItem]
    let placement: Placement

    init(
        model: WindowModel,
        items: [SplitInboxItem] = AppPreferences.configuredSplitInboxItems(),
        placement: Placement = .listHeader
    ) {
        self.model = model
        self.items = items
        self.placement = placement
    }

    enum Placement {
        case topBar
        case listHeader
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 28) {
                ForEach(items) { item in
                    Button {
                        model.select(splitInboxItem: item)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.normalizedTitle)
                                .font(.system(size: isSelected(item) ? 15 : 14, weight: isSelected(item) ? .semibold : .medium))
                                .tracking(isSelected(item) ? 0 : 0.1)

                            Text("\(model.splitInboxCount(for: item))")
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(countColor(for: item))
                        }
                        .foregroundStyle(foreground(for: item))
                        .padding(.vertical, 6)
                        .plainButtonHitArea()
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("split-inbox-tab-\(item.id)")
                }
            }
            .padding(.horizontal, placement == .topBar ? 0 : 18)
            .padding(.top, placement == .topBar ? 0 : 14)
            .padding(.bottom, placement == .topBar ? 0 : 10)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(placement == .listHeader ? MailDesignTokens.surface : Color.clear)
        .overlay(alignment: .bottom) {
            if placement == .listHeader {
                Divider()
            }
        }
    }

    private func isSelected(_ item: SplitInboxItem) -> Bool {
        model.selectedSplitInboxItem.id == item.id
    }

    private func foreground(for item: SplitInboxItem) -> Color {
        isSelected(item) ? MailDesignTokens.textPrimary : MailDesignTokens.textSecondary.opacity(0.9)
    }

    private func countColor(for item: SplitInboxItem) -> Color {
        isSelected(item) ? MailDesignTokens.textSecondary : MailDesignTokens.textTertiary
    }
}

// MARK: - Thread Detail Pane

private struct ThreadDetailPane: View {
    @Bindable var model: WindowModel

    var body: some View {
        if model.composeMode == .fullscreen, let draft = model.composeDraft {
            FullscreenComposeView(model: model, draft: draft)
        } else if let selectedThreadID = model.selectedThreadID,
                  let detail = model.selectedThreadDetail,
                  detail.thread.id == selectedThreadID {
            VStack(spacing: 0) {
                // Action bar
                HStack(spacing: 2) {
                    ActionButton(
                        icon: detail.thread.isInInbox ? "archivebox" : "tray.and.arrow.up",
                        label: detail.thread.isInInbox ? "Archive" : "Unarchive",
                        shortcut: "E"
                    ) {
                        model.toggleArchiveSelection()
                    }
                    ActionButton(icon: detail.thread.hasUnread ? "envelope.open" : "envelope.badge", label: detail.thread.hasUnread ? "Read" : "Unread", shortcut: "Shift+U") {
                        model.toggleReadSelection()
                    }
                    ActionButton(icon: detail.thread.isStarred ? "star.fill" : "star", label: detail.thread.isStarred ? "Unstar" : "Star", shortcut: "S") {
                        model.toggleStarSelection()
                    }
                    ActionButton(icon: detail.thread.isSnoozed ? "clock.arrow.circlepath" : "clock", label: detail.thread.isSnoozed ? "Unsnooze" : "Snooze", shortcut: "H") {
                        model.performPrimarySnoozeAction()
                    }
                    ActionButton(icon: "trash", label: "Trash", shortcut: "#") {
                        model.trashSelection()
                    }

                    Spacer()

                    ActionButton(icon: "arrowshape.turn.up.left", label: "Reply", shortcut: "R") {
                        model.openCompose(replyMode: .reply)
                    }
                    ActionButton(icon: "arrowshape.turn.up.left.2", label: "Reply All", shortcut: "A") {
                        model.openCompose(replyMode: .replyAll)
                    }
                    ActionButton(icon: "arrowshape.turn.up.right", label: "Forward", shortcut: "F") {
                        model.openCompose(replyMode: .forward)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(MailDesignTokens.surface)

                Divider()

                // Thread content
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            // Subject header
                            VStack(alignment: .leading, spacing: 8) {
                                Text(detail.thread.subject)
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(MailDesignTokens.textPrimary)
                                    .textSelection(.enabled)

                                if detail.thread.mailboxRefs.isEmpty == false {
                                    HStack(spacing: 4) {
                                        ForEach(detail.thread.mailboxRefs, id: \.id) { mailbox in
                                            AccountChip(text: mailbox.displayName)
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.top, 20)
                            .padding(.bottom, 16)

                            // Messages
                            let lastMessageID = detail.messages.last?.id
                            ForEach(detail.messages) { message in
                                MessageView(
                                    model: model,
                                    message: message,
                                    startsExpanded: MessagePresentationRules.startsExpanded(
                                        message: message,
                                        isLastMessage: message.id == lastMessageID
                                    )
                                )
                            }

                            // Inline compose (below messages)
                            if model.composeMode == .inline, let draft = model.composeDraft {
                                InlineComposeView(model: model, draft: draft)
                                    .id("inline-compose")
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }
                        }
                        .padding(.bottom, 24)
                    }
                    .onChange(of: model.composeMode) { _, newValue in
                        if newValue == .inline {
                            withAnimation {
                                proxy.scrollTo("inline-compose", anchor: .bottom)
                            }
                        }
                    }
                }
            }
            .background(MailDesignTokens.background)
            .accessibilityIdentifier("thread-detail")
        } else if model.selectedThreadID != nil {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MailDesignTokens.background)
            .accessibilityIdentifier("thread-detail-loading")
        } else {
            // Empty state
            VStack(spacing: 8) {
                if model.threads.isEmpty {
                    Image(systemName: "tray")
                        .font(.system(size: 28))
                        .foregroundStyle(MailDesignTokens.textTertiary)
                    Text("No conversations")
                        .font(.system(size: 14))
                        .foregroundStyle(MailDesignTokens.textSecondary)
                } else {
                    Image(systemName: "envelope.open")
                        .font(.system(size: 28))
                        .foregroundStyle(MailDesignTokens.textTertiary)
                    Text("Select a conversation")
                        .font(.system(size: 14))
                        .foregroundStyle(MailDesignTokens.textSecondary)
                    Text("j/k or Up/Down to navigate, Return to open")
                        .font(.system(size: 12))
                        .foregroundStyle(MailDesignTokens.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MailDesignTokens.background)
        }
    }
}

private struct ActionButton: View {
    let icon: String
    let label: String
    let shortcut: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text(label)
                    .font(.system(size: 12))
            }
            .foregroundStyle(MailDesignTokens.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .plainButtonHitArea()
        }
        .accessibilityIdentifier(accessibilityIdentifier)
        .buttonStyle(.plain)
        .focusable(false)
        .help("\(label) (\(shortcut))")
    }

    private var accessibilityIdentifier: String {
        switch label {
        case "Archive", "Unarchive":
            "thread-archive"
        case "Reply":
            "thread-reply"
        case "Reply All":
            "thread-reply-all"
        case "Read", "Unread":
            "thread-read-toggle"
        case "Star", "Unstar":
            "thread-star-toggle"
        default:
            "action-\(label.lowercased().replacingOccurrences(of: " ", with: "-"))"
        }
    }
}

private struct MessageView: View {
    let model: WindowModel
    let message: MailMessage
    let startsExpanded: Bool
    @State private var isExpanded: Bool
    @State private var showsQuotedContent = false
    @State private var htmlContentHeight: CGFloat = 100
    @State private var openingAttachmentIDs: Set<String> = []
    @State private var downloadingAttachmentIDs: Set<String> = []
    @AppStorage(AppPreferences.loadRemoteImagesKey)
    private var loadRemoteImagesAutomatically = AppPreferences.loadRemoteImagesByDefault

    private var isDraft: Bool {
        message.mailboxRefs.contains { $0.systemRole == .draft }
    }

    private var plainTextContent: PlainTextQuotedContent? {
        guard let plainBody = message.plainBody, plainBody.isEmpty == false else { return nil }
        return MessagePresentationRules.splitPlainTextQuotedContent(plainBody)
    }

    private var hasQuotedContent: Bool {
        if let htmlBody = message.htmlBody, htmlBody.isEmpty == false {
            return HTMLQuotedContentDetector.containsQuotedContent(htmlBody)
        }
        return plainTextContent?.quotedText != nil
    }

    init(model: WindowModel, message: MailMessage, startsExpanded: Bool) {
        self.model = model
        self.message = message
        self.startsExpanded = startsExpanded
        _isExpanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .padding(.horizontal, 24)

            VStack(alignment: .leading, spacing: 12) {
                // Message header
                HStack(alignment: .top) {
                    // Sender avatar
                    Text(String(message.sender.displayName.prefix(1)).uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(isDraft ? Color.orange : Color(red: 0.35, green: 0.45, blue: 0.62))
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text(isDraft ? "Draft" : message.sender.displayName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(isDraft ? .orange : (message.isRead ? MailDesignTokens.textPrimary : MailDesignTokens.accent))
                            if isDraft {
                                Text("DRAFT")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange)
                                    .clipShape(Capsule())
                            }
                            Spacer()
                            HStack(spacing: 8) {
                                Text(MessageDetailTimestampFormatter.string(for: message.receivedAt ?? message.sentAt ?? .now))
                                    .font(.system(size: 11))
                                    .foregroundStyle(MailDesignTokens.textTertiary)

                                Button {
                                    withAnimation(.easeInOut(duration: 0.16)) {
                                        isExpanded.toggle()
                                    }
                                } label: {
                                    Image(systemName: isExpanded ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(MailDesignTokens.textTertiary)
                                }
                                .buttonStyle(.plain)
                                .plainButtonHitArea()
                            }
                        }
                        if !isDraft {
                            Text(message.sender.emailAddress)
                                .font(.system(size: 11))
                                .foregroundStyle(MailDesignTokens.textSecondary)
                        }

                        if message.toRecipients.isEmpty == false {
                            Text("to \(message.toRecipients.map(\.displayName).joined(separator: ", "))")
                                .font(.system(size: 11))
                                .foregroundStyle(MailDesignTokens.textTertiary)
                        }

                        if !isExpanded, message.snippet.isEmpty == false {
                            Text(message.snippet)
                                .font(.system(size: 13))
                                .foregroundStyle(MailDesignTokens.textSecondary)
                                .lineLimit(2)
                                .padding(.top, 6)
                        }
                    }
                }

                // Message body
                if isExpanded {
                    if let htmlBody = message.htmlBody, htmlBody.isEmpty == false {
                        HTMLMessageView(
                            htmlBody: htmlBody,
                            allowsRemoteContent: loadRemoteImagesAutomatically,
                            showsQuotedContent: showsQuotedContent,
                            contentHeight: $htmlContentHeight
                        )
                        .frame(height: htmlContentHeight)
                    } else if let plainTextContent {
                        PlainTextMessageView(text: showsQuotedContent ? message.plainBody ?? plainTextContent.visibleText : plainTextContent.visibleText)
                    } else {
                        Text(message.snippet)
                            .font(.system(size: 13))
                            .foregroundStyle(MailDesignTokens.textSecondary)
                    }

                    if hasQuotedContent {
                        Button(showsQuotedContent ? "Hide quoted text" : "Show quoted text") {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                showsQuotedContent.toggle()
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MailDesignTokens.accent)
                        .plainButtonHitArea()
                    }
                }

                // Attachments
                if isExpanded, !message.attachments.isEmpty {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 14, alignment: .top)],
                        alignment: .leading,
                        spacing: 14
                    ) {
                        ForEach(message.attachments) { attachment in
                            AttachmentCardView(
                                attachment: attachment,
                                isBusy: isBusy(attachment),
                                isOpening: openingAttachmentIDs.contains(attachment.id),
                                isDownloading: downloadingAttachmentIDs.contains(attachment.id),
                                openAction: { openAttachment(attachment) },
                                downloadAction: { downloadAttachment(attachment) }
                            )
                            .opacity(isBusy(attachment) ? 0.92 : 1)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    private func isBusy(_ attachment: MailAttachment) -> Bool {
        openingAttachmentIDs.contains(attachment.id) || downloadingAttachmentIDs.contains(attachment.id)
    }

    private func openAttachment(_ attachment: MailAttachment) {
        Task {
            await runAttachmentAction(id: attachment.id, operation: .open) {
                try await AttachmentFileCoordinator.open(attachment: attachment, model: model)
            }
        }
    }

    private func downloadAttachment(_ attachment: MailAttachment) {
        Task {
            await runAttachmentAction(id: attachment.id, operation: .download) {
                try await AttachmentFileCoordinator.download(attachment: attachment, model: model)
            }
        }
    }

    @MainActor
    private func runAttachmentAction(id: String, operation: AttachmentOperation, task: @escaping () async throws -> Void) async {
        switch operation {
        case .open:
            openingAttachmentIDs.insert(id)
        case .download:
            downloadingAttachmentIDs.insert(id)
        }

        defer {
            switch operation {
            case .open:
                openingAttachmentIDs.remove(id)
            case .download:
                downloadingAttachmentIDs.remove(id)
            }
        }

        do {
            try await task()
        } catch AttachmentInteractionCancelled.userCancelled {
            return
        } catch {
            model.presentError(error)
        }
    }
}

private extension MessageView {
    enum AttachmentOperation {
        case open
        case download
    }
}

private struct AttachmentCardView: View {
    let attachment: MailAttachment
    let isBusy: Bool
    let isOpening: Bool
    let isDownloading: Bool
    let openAction: () -> Void
    let downloadAction: () -> Void

    private var badgeTitle: String {
        let ext = (attachment.filename as NSString).pathExtension
        if ext.isEmpty == false {
            return ext.uppercased()
        }
        if let type = UTType(mimeType: attachment.mimeType), let preferred = type.preferredFilenameExtension {
            return preferred.uppercased()
        }
        return "FILE"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(attachment.filename)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(MailDesignTokens.textPrimary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                Text(attachment.formattedSize)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MailDesignTokens.textTertiary)
            }

            Spacer(minLength: 28)

            HStack(alignment: .bottom) {
                Text(badgeTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.43, green: 0.52, blue: 0.64))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.82))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Spacer()

                HStack(spacing: 8) {
                    AttachmentActionButton(
                        icon: "eye",
                        isBusy: isOpening,
                        help: "Open attachment",
                        action: openAction
                    )
                    AttachmentActionButton(
                        icon: "arrow.down",
                        isBusy: isDownloading,
                        help: "Download attachment",
                        action: downloadAction
                    )
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.28), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: openAction)
        .allowsHitTesting(!isBusy)
        .accessibilityAddTraits(.isButton)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.88, green: 0.90, blue: 0.94),
                        Color(red: 0.82, green: 0.85, blue: 0.90)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }
}

private struct AttachmentActionButton: View {
    let icon: String
    let isBusy: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .medium))
                }
            }
            .foregroundStyle(Color(red: 0.67, green: 0.72, blue: 0.79))
            .frame(width: 34, height: 34)
            .background(Color.white.opacity(0.28))
            .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct ComposeFieldRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MailDesignTokens.textTertiary)
                .frame(width: 48, alignment: .trailing)
            content
                .font(.system(size: 13))
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Empty States

private struct EmptyThreadListView: View {
    @Bindable var model: WindowModel

    private var hasAccounts: Bool { !model.accounts.isEmpty }
    private var singleAvailableProvider: ProviderKind? {
        model.availableAccountProviders.count == 1 ? model.availableAccountProviders.first : nil
    }
    private var connectAccountDescription: String {
        if let provider = singleAvailableProvider {
            return "Connect a \(provider.displayName) account to get started."
        }
        if model.availableAccountProviders.isEmpty {
            return "Configure an account provider to get started."
        }
        return "Connect an account to get started."
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            if hasAccounts {
                Image(systemName: "tray")
                    .font(.system(size: 32))
                    .foregroundStyle(MailDesignTokens.textTertiary)

                Text("You're all caught up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(MailDesignTokens.textPrimary)

                Text("Nothing here right now.")
                    .font(.system(size: 13))
                    .foregroundStyle(MailDesignTokens.textSecondary)
            } else {
                Image(systemName: "tray")
                    .font(.system(size: 32))
                    .foregroundStyle(MailDesignTokens.textTertiary)

                Text("No conversations")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(MailDesignTokens.textPrimary)

                Text(connectAccountDescription)
                    .font(.system(size: 13))
                    .foregroundStyle(MailDesignTokens.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)

                if let provider = singleAvailableProvider {
                    Button {
                        model.connectAccount(kind: provider)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                            Text(model.isConnectingAccount ? "Connecting..." : "Add \(provider.displayName)")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(MailDesignTokens.accentStrong)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .plainButtonHitArea()
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isConnectingAccount)
                } else if model.availableAccountProviders.isEmpty == false {
                    Menu {
                        ForEach(model.availableAccountProviders, id: \.self) { provider in
                            Button("Add \(provider.displayName)") {
                                model.connectAccount(kind: provider)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Add Account")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(MailDesignTokens.accentStrong)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .plainButtonHitArea()
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .disabled(model.isConnectingAccount)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(MailDesignTokens.surface)
    }
}

// MARK: - Tag Picker

private struct TagPickerSheet: View {
    @Bindable var model: WindowModel
    @State private var searchText = ""

    private var filteredMailboxes: [MailboxRef] {
        let mailboxes = model.taggableMailboxesForFocusedThread
        if searchText.isEmpty { return mailboxes }
        return mailboxes.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.mailboxTagPickerTitle)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Done") { model.isTagPickerPresented = false }
                    .font(.system(size: 13))
                    .buttonStyle(.plain)
                    .foregroundStyle(MailDesignTokens.accent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            TextField(model.mailboxTagSearchPrompt, text: $searchText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            Divider()

            if filteredMailboxes.isEmpty {
                VStack(spacing: 8) {
                    Text(model.mailboxTagEmptyStateTitle)
                        .font(.system(size: 13))
                        .foregroundStyle(MailDesignTokens.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredMailboxes) { mailbox in
                            let isApplied = model.selectedThreadDetail?.thread.mailboxRefs.contains(where: { $0.id == mailbox.id }) ?? false
                            Button {
                                if isApplied {
                                    model.removeMailbox(mailbox.id)
                                } else {
                                    model.applyMailbox(mailbox.id)
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: isApplied ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 14))
                                        .foregroundStyle(isApplied ? MailDesignTokens.accent : MailDesignTokens.textTertiary)
                                    if let colorHex = mailbox.colorHex {
                                        Circle()
                                            .fill(Color(hex: colorHex))
                                            .frame(width: 8, height: 8)
                                    }
                                    Text(mailbox.displayName)
                                        .font(.system(size: 13))
                                        .foregroundStyle(MailDesignTokens.textPrimary)
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(isApplied ? MailDesignTokens.selected : Color.clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Divider()
                                .padding(.leading, 40)
                        }
                    }
                }
            }
        }
        .frame(width: 320, height: 400)
    }
}

// MARK: - Folder Picker

private struct FolderPickerSheet: View {
    @Bindable var model: WindowModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Move to Folder")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Cancel") { model.isFolderPickerPresented = false }
                    .font(.system(size: 13))
                    .buttonStyle(.plain)
                    .foregroundStyle(MailDesignTokens.accent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            let folders = model.foldersForFocusedThread
            if folders.isEmpty {
                VStack(spacing: 8) {
                    Text("No folders available")
                        .font(.system(size: 13))
                        .foregroundStyle(MailDesignTokens.textSecondary)
                    Text("This account does not expose any folders.")
                        .font(.system(size: 11))
                        .foregroundStyle(MailDesignTokens.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(folders) { folder in
                            Button {
                                model.applyMailbox(folder.id)
                                model.isFolderPickerPresented = false
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "folder")
                                        .font(.system(size: 13))
                                        .foregroundStyle(MailDesignTokens.textSecondary)
                                    Text(folder.displayName)
                                        .font(.system(size: 13))
                                        .foregroundStyle(MailDesignTokens.textPrimary)
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Divider()
                                .padding(.leading, 40)
                        }
                    }
                }
            }
        }
        .frame(width: 300, height: 350)
    }
}

// MARK: - Snooze Picker

private struct SnoozePickerSheet: View {
    @Bindable var model: WindowModel

    private let options: [(label: String, icon: String, date: () -> Date)] = [
        ("Later Today", "sun.max", { Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: Date()) ?? Date().addingTimeInterval(3 * 3600) }),
        ("Tomorrow Morning", "sunrise", { Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!.addingTimeInterval(9 * 3600) }),
        ("Tomorrow Evening", "sunset", { Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!.addingTimeInterval(17 * 3600) }),
        ("This Weekend", "leaf", {
            let cal = Calendar.current
            let weekday = cal.component(.weekday, from: Date())
            let daysToSaturday = (7 - weekday) % 7
            let saturday = cal.date(byAdding: .day, value: daysToSaturday == 0 ? 7 : daysToSaturday, to: cal.startOfDay(for: Date()))!
            return saturday.addingTimeInterval(9 * 3600)
        }),
        ("Next Week", "calendar", {
            let cal = Calendar.current
            let weekday = cal.component(.weekday, from: Date())
            let daysToMonday = weekday == 2 ? 7 : ((9 - weekday) % 7)
            let monday = cal.date(byAdding: .day, value: daysToMonday, to: cal.startOfDay(for: Date()))!
            return monday.addingTimeInterval(9 * 3600)
        }),
    ]

    @State private var showCustomDate = false
    @State private var customDate = Date().addingTimeInterval(86400)

    var body: some View {
        ZStack {
            MailDesignTokens.surface
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Text("Snooze")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button("Cancel") { model.isSnoozePickerPresented = false }
                        .font(.system(size: 13))
                        .buttonStyle(.plain)
                        .foregroundStyle(MailDesignTokens.accent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()

                VStack(spacing: 0) {
                    ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                        Button {
                            model.snoozeSelection(until: option.date())
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: option.icon)
                                    .font(.system(size: 13))
                                    .foregroundStyle(MailDesignTokens.accent)
                                    .frame(width: 20)
                                Text(option.label)
                                    .font(.system(size: 13))
                                    .foregroundStyle(MailDesignTokens.textPrimary)
                                Spacer()
                                Text(option.date().formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                                    .font(.system(size: 11))
                                    .foregroundStyle(MailDesignTokens.textTertiary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Divider().padding(.leading, 46)
                    }

                    // Custom date
                    Button {
                        showCustomDate.toggle()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "calendar.badge.clock")
                                .font(.system(size: 13))
                                .foregroundStyle(MailDesignTokens.accent)
                                .frame(width: 20)
                            Text("Pick Date & Time")
                                .font(.system(size: 13))
                                .foregroundStyle(MailDesignTokens.textPrimary)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showCustomDate {
                        Divider()
                        DatePicker("", selection: $customDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                            .datePickerStyle(.graphical)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)

                        Button("Snooze Until Selected Time") {
                            model.snoozeSelection(until: customDate)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                    }
                }
            }
        }
        .frame(width: 380, height: showCustomDate ? 580 : 340)
        .preferredColorScheme(.light)
    }
}

#Preview {
    let bootstrap = AppBootstrap.make()
    bootstrap.store.start(seedDemoData: true)
    let windowModel = WindowModel(store: bootstrap.store)
    return ContentView(model: windowModel)
}
