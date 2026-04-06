import Foundation
import MailCore
import MailData
import Observation

public enum MailReloadReason: Sendable {
    case initial
    case manual
    case workspaceChange
}

public struct UndoableAction: Sendable {
    public let label: String
    public let reverseMutations: [MailMutation]
}

public enum LayoutMode: String, CaseIterable, Sendable {
    case focus      // Superhuman-style: list OR detail, never both
    case split      // Traditional 3-column: sidebar | list | detail
}

public enum ComposeMode: Sendable, Equatable {
    case inline     // Below last message in thread (Superhuman-style reply)
    case floating   // Bottom-right card (Gmail-style, for new compose or popped-out reply)
    case fullscreen // Takes over detail pane
}

private struct ThreadListStateSnapshot {
    let threads: [MailThread]
    let hoveredThreadID: MailThreadID?
    let selectedThreadID: MailThreadID?
    let selectedThreadDetail: MailThreadDetail?
    let isThreadOpen: Bool
    let multiSelectedIDs: Set<MailThreadID>
    let multiSelectionAnchorID: MailThreadID?
}

@MainActor
@Observable
public final class WindowModel {
    public let windowID = UUID().uuidString
    public let store: MailAppStore

    // MARK: - Per-Window Navigation State

    public var selectedTab: UnifiedTab = .all
    public var selectedSplitInboxItem: SplitInboxItem = .builtIn(.all)
    public var selectedAccountID: MailAccountID?
    public var selectedThreadID: MailThreadID?
    public private(set) var selectedThreadDetail: MailThreadDetail?
    public var isThreadOpen = false
    public var isSidebarVisible = false
    public var layoutMode: LayoutMode = .focus
    public var hoveredThreadID: MailThreadID?
    public var hoverScrollGeneration = 0
    public var multiSelectedIDs: Set<MailThreadID> = []
    private var multiSelectionAnchorID: MailThreadID?
    public var selectedMailboxID: MailboxID?
    public var mailboxScope: MailboxScope = .inboxOnly
    public var searchText = ""
    public var isSearchFocused = false
    public var composeMode: ComposeMode?
    public var composeDraft: OutgoingDraft?
    public var isCommandPalettePresented = false
    public var isTagPickerPresented = false
    public var isFolderPickerPresented = false
    public var isSnoozePickerPresented = false
    public var errorMessage: String?
    public private(set) var errorReconnectAccountID: MailAccountID?
    public var undoAction: UndoableAction?
    private var threadDetailCache: [MailThreadID: MailThreadDetail] = [:]
    private var prefetchingThreadIDs: Set<MailThreadID> = []

    // MARK: - Per-Window Thread List

    public private(set) var threads: [MailThread] = []
    public private(set) var splitInboxCounts: [String: Int] = [:]
    public private(set) var splitInboxItems: [SplitInboxItem] = SplitInboxItem.defaultItems

    // MARK: - Computed Forwarding Properties (shared data)

    public var accounts: [MailAccount] { store.accounts }
    public var mailboxes: [MailboxRef] { store.mailboxes }
    public var savedDrafts: [OutgoingDraft] { store.savedDrafts }
    public var isRefreshing: Bool { store.isRefreshing }
    public var isConnectingAccount: Bool { store.isConnectingAccount }
    public var availableAccountProviders: [ProviderKind] { store.availableAccountProviders }

    // MARK: - Compose Helpers

    public var isComposeActive: Bool { composeMode != nil }

    public var isComposePresented: Bool {
        get { composeMode != nil }
        set { if !newValue { composeMode = nil } }
    }

    public var isModalPresented: Bool {
        (composeMode == .floating || composeMode == .fullscreen)
            || isCommandPalettePresented
            || isTagPickerPresented
            || isFolderPickerPresented
            || isSnoozePickerPresented
            || errorMessage != nil
    }

    // MARK: - Private Tasks

    @ObservationIgnored
    private nonisolated(unsafe) var undoTimer: Task<Void, Never>?
    @ObservationIgnored
    private nonisolated(unsafe) var draftAutoSaveTask: Task<Void, Never>?

    // MARK: - Init / Deinit

    public init(store: MailAppStore) {
        self.store = store
    }

    deinit {
        undoTimer?.cancel()
        draftAutoSaveTask?.cancel()
    }

    // MARK: - Initial Load

    public func initialLoad() async {
        await reloadThreads(reason: .initial)
    }

    // MARK: - Thread Reload (called by store on workspace changes)

    public func reloadThreads(reason: MailReloadReason = .manual) async {
        do {
            threads = try await store.listThreads(query: activeQuery)
            splitInboxCounts = (try? await loadSplitInboxCounts()) ?? splitInboxCounts
            if let selectedThreadID {
                if let cached = threadDetailCache[selectedThreadID] {
                    selectedThreadDetail = cached
                }
                let detail = try await store.loadThreadDetail(for: selectedThreadID)
                guard self.selectedThreadID == selectedThreadID else { return }
                selectedThreadDetail = detail
                if let detail {
                    threadDetailCache[selectedThreadID] = detail
                    prefetchNextThreadDetail(after: selectedThreadID)
                }
            } else {
                selectedThreadDetail = nil
            }
        } catch {
            present(error)
        }
    }

    // MARK: - Navigation

    public func select(tab: UnifiedTab) {
        applyNavigationSelection(
            tab: tab,
            splitInboxItem: .builtIn(tab),
            accountID: nil,
            mailboxID: nil,
            mailboxScope: .inboxOnly
        )
    }

    public func selectSplitInbox(tab: UnifiedTab) {
        select(splitInboxItem: .builtIn(tab))
    }

    public func select(splitInboxItem item: SplitInboxItem) {
        applyNavigationSelection(
            tab: item.tab,
            splitInboxItem: item,
            accountID: selectedAccountID,
            mailboxID: nil,
            mailboxScope: .inboxOnly
        )
    }

    public func cycleSplitInbox(in items: [SplitInboxItem], forward: Bool = true) {
        guard isSplitInboxVisible else { return }
        guard items.isEmpty == false else { return }
        guard let currentIndex = items.firstIndex(where: { $0.id == selectedSplitInboxItem.id }) else {
            select(splitInboxItem: items[0])
            return
        }

        let nextIndex: Int
        if forward {
            nextIndex = (currentIndex + 1) % items.count
        } else {
            nextIndex = (currentIndex - 1 + items.count) % items.count
        }
        select(splitInboxItem: items[nextIndex])
    }

    public func cycleSplitInbox(forward: Bool = true) {
        cycleSplitInbox(in: splitInboxItems, forward: forward)
    }

    public func select(accountID: MailAccountID?) {
        applyNavigationSelection(
            tab: .all,
            splitInboxItem: .builtIn(.all),
            accountID: accountID,
            mailboxID: nil,
            mailboxScope: .inboxOnly
        )
    }

    public func toggleAccountSelection(accountID: MailAccountID) {
        select(accountID: selectedAccountID == accountID ? nil : accountID)
    }

    public func select(mailboxID: MailboxID?) {
        applyNavigationSelection(
            tab: .all,
            splitInboxItem: .builtIn(.all),
            accountID: mailboxID?.accountID,
            mailboxID: mailboxID,
            mailboxScope: mailboxID.map(MailboxScope.specific) ?? .inboxOnly
        )
    }

    public func selectAllMail(accountID: MailAccountID? = nil) {
        applyNavigationSelection(
            tab: .all,
            splitInboxItem: .builtIn(.all),
            accountID: accountID,
            mailboxID: nil,
            mailboxScope: .allMail
        )
    }

    private func applyNavigationSelection(
        tab: UnifiedTab,
        splitInboxItem: SplitInboxItem,
        accountID: MailAccountID?,
        mailboxID: MailboxID?,
        mailboxScope: MailboxScope
    ) {
        selectedTab = tab
        selectedSplitInboxItem = splitInboxItem
        selectedAccountID = accountID
        selectedMailboxID = mailboxID
        self.mailboxScope = mailboxScope
        selectedThreadID = nil
        selectedThreadDetail = nil
        isThreadOpen = false
        clearMultiSelection()
        Task { await reloadThreads() }
    }

    public func open(threadID: MailThreadID) {
        if openDraftIfAvailable(for: threadID) {
            return
        }
        selectedThreadID = threadID
        selectedThreadDetail = threadDetailCache[threadID]
        isThreadOpen = true
        loadThreadDetail(for: threadID)
        markThreadReadIfNeeded(threadID: threadID)
    }

    public func openThreadForControl(_ threadID: MailThreadID) async throws {
        if openDraftIfAvailable(for: threadID) {
            return
        }
        selectedThreadID = threadID
        selectedThreadDetail = threadDetailCache[threadID]
        isThreadOpen = true

        if let detail = try await store.loadThreadDetail(for: threadID) {
            selectedThreadDetail = detail
            threadDetailCache[threadID] = detail
            prefetchNextThreadDetail(after: threadID)
        } else {
            selectedThreadDetail = nil
        }

        markThreadReadIfNeeded(threadID: threadID)
    }

    public func selectThread(threadID: MailThreadID) {
        if openDraftIfAvailable(for: threadID) {
            return
        }
        selectedThreadID = threadID
        selectedThreadDetail = threadDetailCache[threadID]
        loadThreadDetail(for: threadID)
    }

    public func closeThread() {
        isThreadOpen = false
        selectedThreadID = nil
        selectedThreadDetail = nil
    }

    public func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    public func setSplitInboxItems(_ items: [SplitInboxItem]) {
        let normalizedItems = items.isEmpty ? SplitInboxItem.defaultItems : items
        guard splitInboxItems != normalizedItems else { return }

        splitInboxItems = normalizedItems

        if let exactMatch = normalizedItems.first(where: { $0.id == selectedSplitInboxItem.id }) {
            selectedSplitInboxItem = exactMatch
            selectedTab = exactMatch.tab
        } else if let builtInMatch = normalizedItems.first(where: { $0.isBuiltIn && $0.tab == selectedTab }) {
            selectedSplitInboxItem = builtInMatch
        } else if let fallback = normalizedItems.first {
            selectedSplitInboxItem = fallback
            selectedTab = fallback.tab
        }

        Task { await reloadThreads() }
    }

    // MARK: - Search

    public func beginSearch() {
        isSearchFocused = true
    }

    public func cancelSearch() {
        searchText = ""
        isSearchFocused = false
        Task { await reloadThreads() }
    }

    public func submitSearch() {
        isSearchFocused = false
        Task { await reloadThreads() }
    }

    // MARK: - Command Palette

    public func openCommandPalette() {
        isCommandPalettePresented = true
    }

    public func closeCommandPalette() {
        isCommandPalettePresented = false
    }

    // MARK: - Refresh (delegates to store)

    public func refresh() {
        store.refreshAll()
    }

    // MARK: - Account Management (delegates to store)

    public func connectAccount(kind: ProviderKind) {
        store.connectAccount(kind: kind)
    }

    public func connectGmail() {
        connectAccount(kind: .gmail)
    }

    public func reconnect(accountID: MailAccountID) {
        dismissError()
        store.reconnectAccount(accountID: accountID)
    }

    public func remove(accountID: MailAccountID) {
        store.remove(accountID: accountID)
    }

    public func loadDemoInbox() {
        store.loadDemoInbox()
    }

    public func setMailboxHidden(_ mailboxID: MailboxID, hidden: Bool) {
        store.setMailboxHidden(mailboxID, hidden: hidden)
    }

    // MARK: - Thread Actions

    public func toggleArchiveSelection() {
        guard let thread = hoveredOrSelectedThread else { return }
        if thread.isInInbox {
            archive(thread)
        } else {
            unarchive(thread)
        }
    }

    public func archiveSelection() {
        toggleArchiveSelection()
    }

    public func trashSelection() {
        guard let targetID = hoveredThreadID else { return }
        let nextThread = threadAfter(threadID: targetID)
        let mutation = MailMutation.trash(threadID: targetID)
        let reverse = MailMutation.untrash(threadID: targetID)
        showUndo(label: "Moved to Trash", reverseMutations: [reverse])
        perform(mutation)
        if let nextThread {
            hoveredThreadID = nextThread.id
        } else {
            hoveredThreadID = nil
        }
        if selectedThreadID == targetID {
            closeThread()
        }
    }

    public func toggleReadSelection() {
        guard let thread = hoveredOrSelectedThread else { return }
        let willMarkRead = thread.hasUnread
        let mutation: MailMutation = willMarkRead ? .markRead(threadID: thread.id) : .markUnread(threadID: thread.id)
        let reverse: MailMutation = willMarkRead ? .markUnread(threadID: thread.id) : .markRead(threadID: thread.id)
        showUndo(label: willMarkRead ? "Marked Read" : "Marked Unread", reverseMutations: [reverse])
        performWithOptimisticUpdate(
            mutation,
            threadID: thread.id,
            update: { $0.hasUnread = !willMarkRead },
            shouldRemoveFromCurrentList: willMarkRead && self.markReadRemovesThreadFromCurrentList
        )
    }

    public func toggleStarSelection() {
        guard let thread = hoveredOrSelectedThread else { return }
        let willStar = !thread.isStarred
        let mutation: MailMutation = willStar ? .star(threadID: thread.id) : .unstar(threadID: thread.id)
        let reverse: MailMutation = willStar ? .unstar(threadID: thread.id) : .star(threadID: thread.id)
        showUndo(label: willStar ? "Starred" : "Unstarred", reverseMutations: [reverse])
        performWithOptimisticUpdate(
            mutation,
            threadID: thread.id,
            update: { $0.isStarred = willStar },
            shouldRemoveFromCurrentList: !willStar && self.unstarRemovesThreadFromCurrentList
        )
    }

    // MARK: - Snooze

    public func toggleSnoozeSelection() {
        guard let thread = hoveredOrSelectedThread else { return }
        if thread.isSnoozed {
            unsnoozeSelection()
        } else {
            showSnoozePicker()
        }
    }

    public func showSnoozePicker() {
        guard let targetID = hoveredThreadID ?? selectedThreadID else { return }
        hoveredThreadID = targetID
        isSnoozePickerPresented = true
    }

    public func snoozeSelection(until date: Date) {
        guard let targetID = hoveredThreadID ?? selectedThreadID else { return }
        hoveredThreadID = targetID
        let mutation = MailMutation.snooze(threadID: targetID, until: date)
        let reverse = MailMutation.unsnooze(threadID: targetID)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let label = "Snoozed until \(formatter.localizedString(for: date, relativeTo: Date()))"
        showUndo(label: label, reverseMutations: [reverse])
        performWithOptimisticUpdate(
            mutation,
            threadID: targetID,
            shouldRemoveFromCurrentList: snoozeRemovesThreadFromCurrentList
        )
        isSnoozePickerPresented = false
    }

    public func unsnoozeSelection() {
        guard let thread = hoveredOrSelectedThread else { return }
        let targetID = thread.id
        hoveredThreadID = targetID
        let mutation = MailMutation.unsnooze(threadID: targetID)
        let reverseMutations = thread.snoozedUntil.map { [MailMutation.snooze(threadID: targetID, until: $0)] } ?? []
        showUndo(label: "Removed snooze", reverseMutations: reverseMutations)
        performWithOptimisticUpdate(
            mutation,
            threadID: targetID,
            shouldRemoveFromCurrentList: unsnoozeRemovesThreadFromCurrentList
        )
        isSnoozePickerPresented = false
    }

    public var snoozeActionTitle: String {
        hoveredOrSelectedThread?.isSnoozed == true ? "Unsnooze Thread" : "Snooze Thread"
    }

    public var snoozeActionLabel: String {
        hoveredOrSelectedThread?.isSnoozed == true ? "Unsnooze" : "Snooze"
    }

    public var snoozeActionSymbolName: String {
        hoveredOrSelectedThread?.isSnoozed == true ? "clock.arrow.circlepath" : "clock"
    }

    public var hasSnoozeTarget: Bool {
        hoveredOrSelectedThread != nil
    }

    public var isFocusedThreadSnoozed: Bool {
        hoveredOrSelectedThread?.isSnoozed == true
    }

    public var selectedThreadIsSnoozed: Bool {
        selectedThread?.isSnoozed == true
    }

    public var selectedThreadSnoozeActionTitle: String {
        selectedThreadIsSnoozed ? "Unsnooze Thread" : "Snooze Thread…"
    }

    public func performPrimarySnoozeAction() {
        if isFocusedThreadSnoozed {
            unsnoozeSelection()
        } else {
            showSnoozePicker()
        }
    }

    // MARK: - Multi-Select

    public var isMultiSelectActive: Bool { !multiSelectedIDs.isEmpty }

    public var actionableThreadIDs: [MailThreadID] {
        if isMultiSelectActive {
            let orderedVisibleIDs = threads.map(\.id).filter { multiSelectedIDs.contains($0) }
            if orderedVisibleIDs.count == multiSelectedIDs.count {
                return orderedVisibleIDs
            }
            let visibleIDSet = Set(orderedVisibleIDs)
            let remainingIDs = multiSelectedIDs
                .subtracting(visibleIDSet)
                .sorted { $0.rawValue < $1.rawValue }
            return orderedVisibleIDs + remainingIDs
        }
        if let hoveredThreadID { return [hoveredThreadID] }
        return []
    }

    public func toggleMultiSelect(threadID: MailThreadID) {
        if multiSelectedIDs.contains(threadID) {
            multiSelectedIDs.remove(threadID)
        } else {
            multiSelectedIDs.insert(threadID)
        }
        syncMultiSelectionAnchor(preferredID: threadID)
    }

    public func toggleMultiSelectCurrent() {
        guard let hoveredThreadID else {
            enterMultiSelect()
            return
        }
        toggleMultiSelect(threadID: hoveredThreadID)
    }

    public func extendSelection(by delta: Int) {
        guard threads.isEmpty == false else { return }
        let startingID = hoveredThreadID ?? threads.first?.id
        guard let startingID else { return }
        hoveredThreadID = startingID

        let anchorID = resolvedMultiSelectionAnchor(fallback: startingID)
        moveHover(by: delta)
        if let newID = hoveredThreadID {
            setContiguousMultiSelection(from: anchorID, to: newID)
        }
    }

    public func enterMultiSelect() {
        guard threads.isEmpty == false else { return }
        let threadID = hoveredThreadID ?? threads.first?.id
        guard let threadID else { return }
        hoveredThreadID = threadID
        multiSelectedIDs = [threadID]
        multiSelectionAnchorID = threadID
    }

    public func selectAll() {
        if hoveredThreadID == nil, let first = threads.first?.id {
            hoveredThreadID = first
        }
        multiSelectionAnchorID = hoveredThreadID
        multiSelectedIDs = Set(threads.map(\.id))
    }

    public func deselectAll() {
        clearMultiSelection()
    }

    public func batchArchive() {
        let ids = actionableThreadIDs
        guard !ids.isEmpty else { return }
        performBatchWithOptimisticUpdate(
            ids,
            shouldRemoveFromCurrentList: archiveRemovesThreadFromCurrentList,
            mutation: { .archive(threadID: $0) }
        )
        showUndo(label: "Archived \(ids.count) conversations", reverseMutations: ids.map { .unarchive(threadID: $0) })
        clearMultiSelection()
        closeThread()
    }

    public func batchTrash() {
        let ids = actionableThreadIDs
        guard !ids.isEmpty else { return }
        for id in ids { perform(.trash(threadID: id)) }
        showUndo(label: "Trashed \(ids.count) conversations", reverseMutations: ids.map { .untrash(threadID: $0) })
        clearMultiSelection()
        closeThread()
    }

    public func batchMarkRead() {
        let ids = actionableThreadIDs
        guard !ids.isEmpty else { return }
        performBatchWithOptimisticUpdate(
            ids,
            update: { $0.hasUnread = false },
            shouldRemoveFromCurrentList: markReadRemovesThreadFromCurrentList,
            mutation: { .markRead(threadID: $0) }
        )
        clearMultiSelection()
    }

    public func batchStar() {
        let ids = actionableThreadIDs
        guard !ids.isEmpty else { return }
        performBatchWithOptimisticUpdate(
            ids,
            update: { $0.isStarred = true },
            mutation: { .star(threadID: $0) }
        )
        clearMultiSelection()
    }

    private func clearMultiSelection() {
        multiSelectedIDs.removeAll()
        multiSelectionAnchorID = nil
    }

    private func syncMultiSelectionAnchor(preferredID: MailThreadID) {
        if multiSelectedIDs.isEmpty {
            multiSelectionAnchorID = nil
        } else if multiSelectedIDs.count == 1 {
            multiSelectionAnchorID = multiSelectedIDs.first
        } else if let anchorID = multiSelectionAnchorID {
            if multiSelectedIDs.contains(anchorID) == false {
                multiSelectionAnchorID = preferredID
            }
        } else {
            multiSelectionAnchorID = preferredID
        }
    }

    private func resolvedMultiSelectionAnchor(fallback: MailThreadID) -> MailThreadID {
        if let anchorID = multiSelectionAnchorID,
           threads.contains(where: { $0.id == anchorID }) {
            return anchorID
        }

        multiSelectionAnchorID = fallback
        return fallback
    }

    private func setContiguousMultiSelection(from anchorID: MailThreadID, to currentID: MailThreadID) {
        guard let anchorIndex = threads.firstIndex(where: { $0.id == anchorID }),
              let currentIndex = threads.firstIndex(where: { $0.id == currentID }) else {
            multiSelectionAnchorID = currentID
            multiSelectedIDs = [currentID]
            return
        }

        let lowerBound = min(anchorIndex, currentIndex)
        let upperBound = max(anchorIndex, currentIndex)
        multiSelectedIDs = Set(threads[lowerBound...upperBound].map(\.id))
    }

    // MARK: - Hover / Keyboard Navigation

    public func moveHover(by delta: Int) {
        guard threads.isEmpty == false else { return }
        if let currentID = hoveredThreadID, let currentIndex = threads.firstIndex(where: { $0.id == currentID }) {
            let nextIndex = min(max(currentIndex + delta, 0), threads.count - 1)
            hoveredThreadID = threads[nextIndex].id
        } else if let first = threads.first {
            hoveredThreadID = first.id
        }
        hoverScrollGeneration += 1
    }

    // MARK: - Tags & Folders

    public func showTagPicker() {
        guard hoveredThreadID != nil else { return }
        guard taggableMailboxesForFocusedThread.isEmpty == false else {
            errorMessage = "\(mailboxTagPlural) are not available for this account."
            return
        }
        isTagPickerPresented = true
    }

    public func showFolderPicker() {
        guard hoveredThreadID != nil else { return }
        guard foldersForFocusedThread.isEmpty == false else {
            errorMessage = "Folders are not available for this account."
            return
        }
        isFolderPickerPresented = true
    }

    public func applyMailbox(_ mailboxID: MailboxID) {
        guard let targetID = hoveredThreadID else { return }
        guard let mailbox = mailboxes.first(where: { $0.id == mailboxID }) else {
            errorMessage = "That mailbox is no longer available."
            return
        }
        let mutation = MailMutation.applyMailbox(threadID: targetID, mailboxID: mailboxID)
        let reverse = MailMutation.removeMailbox(threadID: targetID, mailboxID: mailboxID)
        showUndo(label: undoLabelForMailboxApplication(mailbox), reverseMutations: [reverse])
        perform(mutation)
        if mailbox.kind == .folder {
            isFolderPickerPresented = false
        } else {
            isTagPickerPresented = false
        }
    }

    public func removeMailbox(_ mailboxID: MailboxID) {
        guard let targetID = hoveredThreadID else { return }
        guard let mailbox = mailboxes.first(where: { $0.id == mailboxID }) else {
            errorMessage = "That mailbox is no longer available."
            return
        }
        let mutation = MailMutation.removeMailbox(threadID: targetID, mailboxID: mailboxID)
        let reverse = MailMutation.applyMailbox(threadID: targetID, mailboxID: mailboxID)
        showUndo(label: undoLabelForMailboxRemoval(mailbox), reverseMutations: [reverse])
        perform(mutation)
    }

    // MARK: - Compose

    public func openCompose(replyMode: ReplyMode = .new) {
        let accountID: MailAccountID
        if replyMode != .new, let threadAccountID = selectedThreadDetail?.thread.accountID {
            accountID = threadAccountID
        } else {
            if accounts.isEmpty {
                accountID = selectedAccountID ?? MailAccountID(rawValue: "gmail:alpha@example.com")
            } else {
            let preferredAccount = selectedAccountID.flatMap { id in
                accounts.first(where: { $0.id == id && $0.capabilities.supportsCompose })
            }
            let fallbackAccount = accounts.first(where: { $0.capabilities.supportsCompose })
            guard let resolvedAccountID = preferredAccount?.id ?? fallbackAccount?.id else {
                errorMessage = "Compose is not available for the connected accounts yet."
                return
            }
            accountID = resolvedAccountID
            }
        }

        if let composeAccount = accounts.first(where: { $0.id == accountID }) {
            guard composeAccount.capabilities.supportsCompose else {
                errorMessage = "\(composeAccount.providerKind.displayName) compose is not available yet."
                return
            }
        }

        let toRecipients: [MailParticipant]
        if replyMode == .replyAll, let detail = selectedThreadDetail, let lastMessage = detail.messages.last {
            let selfEmails = Set(accounts.map { $0.primaryEmail.lowercased() })
            var seenEmails = Set<String>()
            let candidates = [lastMessage.sender] + lastMessage.toRecipients + lastMessage.ccRecipients
            toRecipients = candidates.filter { participant in
                let email = participant.emailAddress.lowercased()
                guard selfEmails.contains(email) == false else { return false }
                return seenEmails.insert(email).inserted
            }
        } else if replyMode == .reply {
            toRecipients = [selectedThreadDetail?.messages.last?.sender].compactMap { $0 }
        } else {
            toRecipients = []
        }

        var body = ""
        let sig = signature(for: accountID)
        if !sig.isEmpty {
            body += "\n\n--\n\(sig)"
        }
        let quotedReply: DraftQuotedReply?
        switch replyMode {
        case .reply, .replyAll:
            quotedReply = replyQuotedMessage()
        case .forward:
            body += forwardBody()
            quotedReply = nil
        case .new:
            quotedReply = nil
        }
        let threadID: MailThreadID?
        switch replyMode {
        case .reply, .replyAll:
            threadID = selectedThreadDetail?.thread.id
        case .new, .forward:
            threadID = nil
        }

        let draft = OutgoingDraft(
            accountID: accountID,
            replyMode: replyMode,
            threadID: threadID,
            toRecipients: toRecipients,
            subject: replySubject(for: replyMode),
            plainBody: body,
            quotedReply: quotedReply
        )
        composeDraft = draft

        // Choose compose mode based on context
        switch replyMode {
        case .reply, .replyAll:
            composeMode = isThreadOpen ? .inline : .floating
        case .new, .forward:
            composeMode = .floating
        }
    }

    public func updateCompose(_ draft: OutgoingDraft) {
        composeDraft = draft
        scheduleDraftAutoSave()
    }

    public func sendCompose() {
        guard let composeDraft else { return }
        let draftID = composeDraft.id
        draftAutoSaveTask?.cancel()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await store.send(composeDraft)
                try? await store.deleteDraft(id: draftID)
                composeMode = nil
                self.composeDraft = nil
                await store.reloadDrafts()
            } catch {
                present(error)
            }
        }
    }

    public func dismissCompose() {
        if let draft = composeDraft, !draft.subject.isEmpty || !draft.plainBody.isEmpty || !draft.toRecipients.isEmpty {
            Task { [weak self] in
                var updated = draft
                updated.updatedAt = Date()
                try? await self?.store.saveDraft(updated)
                await self?.store.reloadDrafts()
            }
        }
        draftAutoSaveTask?.cancel()
        composeMode = nil
        composeDraft = nil
    }

    public func popOutCompose() {
        guard composeMode == .inline else { return }
        composeMode = .floating
    }

    public func minimizeCompose() {
        composeMode = .floating
    }

    public func expandCompose() {
        composeMode = .fullscreen
    }

    public func openDraft(_ draft: OutgoingDraft) {
        composeDraft = draft
        composeMode = .floating
    }

    public func deleteDraft(_ draft: OutgoingDraft) {
        Task { [weak self] in
            try? await self?.store.deleteDraft(id: draft.id)
            await self?.store.reloadDrafts()
        }
    }

    public func fetchAttachmentData(_ attachment: MailAttachment) async throws -> Data {
        try await store.fetchAttachmentData(attachment)
    }

    public func presentError(_ error: Error) {
        present(error)
    }

    public func resolveThreadDetail(threadID: MailThreadID) async throws -> MailThreadDetail? {
        if let detail = threadDetailCache[threadID] {
            selectedThreadDetail = detail
            return detail
        }

        let detail = try await store.loadThreadDetail(for: threadID)
        if let detail {
            threadDetailCache[threadID] = detail
            if selectedThreadID == threadID {
                selectedThreadDetail = detail
            }
        }
        return detail
    }

    // MARK: - Undo

    public func performUndo() {
        guard let undo = undoAction else { return }
        undoTimer?.cancel()
        undoAction = nil
        for mutation in undo.reverseMutations {
            perform(mutation)
        }
    }

    public func dismissUndo() {
        undoTimer?.cancel()
        undoAction = nil
    }

    // MARK: - Error

    public func dismissError() {
        errorMessage = nil
        errorReconnectAccountID = nil
    }

    // MARK: - Computed Properties

    public var selectedThread: MailThread? {
        guard let selectedThreadID else { return nil }
        return threads.first(where: { $0.id == selectedThreadID }) ?? selectedThreadDetail?.thread
    }

    public var focusedThread: MailThread? {
        if isMultiSelectActive {
            return threads.first(where: { multiSelectedIDs.contains($0.id) })
        }
        return hoveredOrSelectedThread
    }

    public var focusedThreadID: MailThreadID? {
        if isMultiSelectActive { return nil }
        return hoveredThreadID ?? selectedThreadID
    }

    public var mailboxTagSingular: String {
        (focusedThreadAccount ?? selectedThreadAccount)?.providerKind.mailboxTagSingular ?? "Label"
    }

    public var mailboxTagPlural: String {
        (focusedThreadAccount ?? selectedThreadAccount)?.providerKind.mailboxTagPlural ?? "Labels"
    }

    public var mailboxTagActionTitle: String {
        let prefix = mailboxTagSingular == "Category" ? "Apply" : "Add"
        return "\(prefix) \(mailboxTagSingular.lowercased())"
    }

    public var mailboxTagActionSubtitle: String {
        "Open \(mailboxTagSingular.lowercased()) picker"
    }

    public var mailboxTagPickerTitle: String {
        "Apply \(mailboxTagSingular)"
    }

    public var mailboxTagSearchPrompt: String {
        "Search \(mailboxTagPlural.lowercased())..."
    }

    public var mailboxTagEmptyStateTitle: String {
        "No \(mailboxTagPlural.lowercased()) available"
    }

    public var taggableMailboxesForSelectedThread: [MailboxRef] {
        guard let thread = selectedThread, let account = selectedThreadAccount else { return [] }
        return taggableMailboxes(for: thread.accountID, account: account)
    }

    public var taggableMailboxesForFocusedThread: [MailboxRef] {
        guard let thread = hoveredOrSelectedThread, let account = focusedThreadAccount else { return [] }
        return taggableMailboxes(for: thread.accountID, account: account)
    }

    public var labelsForSelectedThread: [MailboxRef] {
        taggableMailboxesForSelectedThread
    }

    public var labelsForFocusedThread: [MailboxRef] {
        taggableMailboxesForFocusedThread
    }

    public var foldersForSelectedThread: [MailboxRef] {
        guard let thread = selectedThread,
              selectedThreadAccount?.capabilities.supportsFolders == true else { return [] }
        return mailboxes.filter {
            $0.accountID == thread.accountID && $0.kind == .folder
        }
    }

    public var foldersForFocusedThread: [MailboxRef] {
        guard let thread = hoveredOrSelectedThread,
              focusedThreadAccount?.capabilities.supportsFolders == true else { return [] }
        return mailboxes.filter {
            $0.accountID == thread.accountID && $0.kind == .folder
        }
    }

    public var isAllMailSelected: Bool {
        if case .allMail = mailboxScope {
            return selectedMailboxID == nil
        }
        return false
    }

    public var isSplitInboxVisible: Bool {
        selectedMailboxID == nil && mailboxScope == .inboxOnly
    }

    public func splitInboxCount(for tab: UnifiedTab) -> Int {
        splitInboxCount(for: .builtIn(tab))
    }

    public func splitInboxCount(for item: SplitInboxItem) -> Int {
        splitInboxCounts[item.id, default: 0]
    }

    public var currentSplitInboxTitle: String {
        selectedSplitInboxItem.normalizedTitle
    }

    // MARK: - Present Error (internal, called by store too)

    func present(_ error: Error) {
        let message = error.localizedDescription
        if message == "The provider session is unauthorized." || String(describing: error) == "unauthorized" {
            errorMessage = "Your account session expired. Reconnect the account and try again."
            errorReconnectAccountID = reconnectableAccountIDForCurrentContext()
            return
        }
        errorReconnectAccountID = nil
        errorMessage = message
    }
}

// MARK: - Private Helpers

private extension WindowModel {
    func reconnectableAccountIDForCurrentContext() -> MailAccountID? {
        selectedThreadAccount?.id
            ?? focusedThreadAccount?.id
            ?? selectedAccountID
            ?? accounts.first(where: { $0.syncState.requiresReconnect })?.id
    }

    func archive(_ thread: MailThread) {
        let mutation = MailMutation.archive(threadID: thread.id)
        let reverse = MailMutation.unarchive(threadID: thread.id)
        showUndo(label: "Archived", reverseMutations: [reverse])
        performWithOptimisticUpdate(
            mutation,
            threadID: thread.id,
            shouldRemoveFromCurrentList: archiveRemovesThreadFromCurrentList
        )
    }

    func unarchive(_ thread: MailThread) {
        let mutation = MailMutation.unarchive(threadID: thread.id)
        let reverse = MailMutation.archive(threadID: thread.id)
        showUndo(label: "Moved to Inbox", reverseMutations: [reverse])
        perform(mutation)
    }

    func openDraftIfAvailable(for threadID: MailThreadID) -> Bool {
        guard let thread = threads.first(where: { $0.id == threadID }) else { return false }
        guard thread.mailboxRefs.contains(where: { $0.systemRole == .draft }) else { return false }
        guard let draft = savedDrafts
            .filter({ $0.accountID == thread.accountID && $0.threadID == threadID })
            .sorted(by: { $0.updatedAt > $1.updatedAt })
            .first else {
            return false
        }

        openDraft(draft)
        return true
    }

    func loadThreadDetail(for threadID: MailThreadID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let detail = try await store.loadThreadDetail(for: threadID)
                guard selectedThreadID == threadID else { return }
                selectedThreadDetail = detail
                if let detail {
                    threadDetailCache[threadID] = detail
                    prefetchNextThreadDetail(after: threadID)
                }
            } catch {
                present(error)
            }
        }
    }

    func prefetchNextThreadDetail(after threadID: MailThreadID) {
        guard let nextThread = threadAfter(threadID: threadID) else { return }
        prefetchThreadDetail(for: nextThread.id)
    }

    func prefetchThreadDetail(for threadID: MailThreadID) {
        guard threadDetailCache[threadID] == nil else { return }
        guard prefetchingThreadIDs.insert(threadID).inserted else { return }

        Task { [weak self] in
            guard let self else { return }
            defer { prefetchingThreadIDs.remove(threadID) }
            do {
                if let detail = try await store.loadThreadDetail(for: threadID) {
                    threadDetailCache[threadID] = detail
                }
            } catch {
                // Keep prefetch failures invisible. Selection will fall back to the normal load path.
            }
        }
    }

    func markThreadReadIfNeeded(threadID: MailThreadID) {
        guard let thread = threads.first(where: { $0.id == threadID }), thread.hasUnread else { return }
        perform(.markRead(threadID: threadID), reportErrors: false)
    }

    func loadSplitInboxCounts() async throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for item in splitInboxItems {
            counts[item.id] = try await store.countThreads(query: splitInboxQuery(for: item))
        }
        return counts
    }

    var activeQuery: ThreadListQuery {
        ThreadListQuery(
            tab: selectedSplitInboxItem.tab,
            accountFilter: selectedAccountID,
            mailboxScope: mailboxScope,
            searchText: searchText.isEmpty ? nil : searchText,
            splitInboxQueryText: selectedSplitInboxItem.normalizedQueryText,
            limit: 100
        )
    }

    func splitInboxQuery(for tab: UnifiedTab) -> ThreadListQuery {
        splitInboxQuery(for: .builtIn(tab))
    }

    func splitInboxQuery(for item: SplitInboxItem) -> ThreadListQuery {
        ThreadListQuery(
            tab: item.tab,
            accountFilter: selectedAccountID,
            mailboxScope: .inboxOnly,
            searchText: searchText.isEmpty ? nil : searchText,
            splitInboxQueryText: item.normalizedQueryText,
            limit: 100
        )
    }

    var selectedThreadAccount: MailAccount? {
        guard let accountID = selectedThread?.accountID else { return nil }
        return accounts.first(where: { $0.id == accountID })
    }

    var focusedThreadAccount: MailAccount? {
        guard let accountID = hoveredOrSelectedThread?.accountID else { return nil }
        return accounts.first(where: { $0.id == accountID })
    }

    var hoveredOrSelectedThread: MailThread? {
        if let hoveredThreadID {
            return threads.first(where: { $0.id == hoveredThreadID })
        }
        return selectedThread
    }

    func threadAfter(threadID: MailThreadID) -> MailThread? {
        guard let currentIndex = threads.firstIndex(where: { $0.id == threadID }) else {
            return nil
        }
        let nextIndex = currentIndex + 1
        if nextIndex < threads.count {
            return threads[nextIndex]
        } else if currentIndex > 0 {
            return threads[currentIndex - 1]
        }
        return nil
    }

    func taggableMailboxes(for accountID: MailAccountID, account: MailAccount) -> [MailboxRef] {
        guard account.capabilities.supportsTagging else { return [] }
        return mailboxes.filter { mailbox in
            guard mailbox.accountID == accountID else { return false }
            switch mailbox.kind {
            case .label:
                return account.capabilities.supportsLabels
            case .category:
                return account.capabilities.supportsCategories
            case .folder:
                return false
            case .system:
                return account.capabilities.supportsLabels && mailbox.systemRole == .important
            }
        }
    }

    func undoLabelForMailboxApplication(_ mailbox: MailboxRef) -> String {
        switch mailbox.kind {
        case .folder:
            return "Moved to \(mailbox.displayName)"
        case .category:
            return "Category applied"
        case .label, .system:
            return "Label applied"
        }
    }

    func undoLabelForMailboxRemoval(_ mailbox: MailboxRef) -> String {
        switch mailbox.kind {
        case .folder:
            return "Folder removed"
        case .category:
            return "Category removed"
        case .label, .system:
            return "Label removed"
        }
    }

    var archiveRemovesThreadFromCurrentList: Bool {
        switch selectedTab {
        case .all:
            return mailboxScope != .allMail
        case .unread:
            return true
        case .starred, .snoozed:
            return false
        }
    }

    var snoozeRemovesThreadFromCurrentList: Bool {
        selectedTab != .snoozed
    }

    var unsnoozeRemovesThreadFromCurrentList: Bool {
        selectedTab == .snoozed
    }

    var unstarRemovesThreadFromCurrentList: Bool {
        selectedTab == .starred
    }

    var markReadRemovesThreadFromCurrentList: Bool {
        selectedTab == .unread
    }

    func advanceAfterRemovingThread(_ threadID: MailThreadID, nextThread: MailThread?) {
        if let nextThread {
            hoveredThreadID = nextThread.id
        } else {
            hoveredThreadID = nil
        }

        guard selectedThreadID == threadID else { return }
        guard let nextThread else {
            closeThread()
            return
        }

        if isThreadOpen {
            open(threadID: nextThread.id)
        } else {
            selectThread(threadID: nextThread.id)
        }
    }

    func captureThreadListState() -> ThreadListStateSnapshot {
        ThreadListStateSnapshot(
            threads: threads,
            hoveredThreadID: hoveredThreadID,
            selectedThreadID: selectedThreadID,
            selectedThreadDetail: selectedThreadDetail,
            isThreadOpen: isThreadOpen,
            multiSelectedIDs: multiSelectedIDs,
            multiSelectionAnchorID: multiSelectionAnchorID
        )
    }

    func restoreThreadListState(_ snapshot: ThreadListStateSnapshot) {
        threads = snapshot.threads
        hoveredThreadID = snapshot.hoveredThreadID
        selectedThreadID = snapshot.selectedThreadID
        selectedThreadDetail = snapshot.selectedThreadDetail
        isThreadOpen = snapshot.isThreadOpen
        multiSelectedIDs = snapshot.multiSelectedIDs
        multiSelectionAnchorID = snapshot.multiSelectionAnchorID
    }

    func performWithOptimisticUpdate(
        _ mutation: MailMutation,
        threadID: MailThreadID,
        update: ((inout MailThread) -> Void)? = nil,
        shouldRemoveFromCurrentList: Bool = false,
        reportErrors: Bool = true
    ) {
        let snapshot = captureThreadListState()

        if let update, let index = threads.firstIndex(where: { $0.id == threadID }) {
            update(&threads[index])
        }

        if shouldRemoveFromCurrentList {
            let nextThread = threadAfter(threadID: threadID)
            threads.removeAll { $0.id == threadID }
            if multiSelectedIDs.contains(threadID) {
                multiSelectedIDs.remove(threadID)
                syncMultiSelectionAnchor(preferredID: nextThread?.id ?? threadID)
            }
            advanceAfterRemovingThread(threadID, nextThread: nextThread)
        }

        perform(mutation, reportErrors: reportErrors) { [weak self] in
            self?.restoreThreadListState(snapshot)
        }
    }

    func performBatchWithOptimisticUpdate(
        _ threadIDs: [MailThreadID],
        update: ((inout MailThread) -> Void)? = nil,
        shouldRemoveFromCurrentList: Bool = false,
        mutation: (MailThreadID) -> MailMutation,
        reportErrors: Bool = true
    ) {
        let snapshot = captureThreadListState()

        if let update {
            let idSet = Set(threadIDs)
            for i in threads.indices where idSet.contains(threads[i].id) {
                update(&threads[i])
            }
        }

        if shouldRemoveFromCurrentList {
            let removedIDs = Set(threadIDs)
            let originalThreads = threads
            threads = originalThreads.filter { !removedIDs.contains($0.id) }
            let nextThread: MailThread? = {
                guard let firstRemovedIndex = originalThreads.firstIndex(where: { removedIDs.contains($0.id) }) else {
                    return threads.first
                }
                return firstRemovedIndex < threads.count ? threads[firstRemovedIndex] : threads.last
            }()
            if let hoveredThreadID, removedIDs.contains(hoveredThreadID) {
                self.hoveredThreadID = nextThread?.id
            }
            multiSelectedIDs.subtract(removedIDs)
            if let preferredID = nextThread?.id ?? threadIDs.first {
                syncMultiSelectionAnchor(preferredID: preferredID)
            }
        }

        let rollbackOnError: () -> Void = { [weak self] in
            self?.restoreThreadListState(snapshot)
        }
        for threadID in threadIDs {
            perform(mutation(threadID), reportErrors: reportErrors, rollbackOnError: rollbackOnError)
        }
    }

    func showUndo(label: String, reverseMutations: [MailMutation]) {
        undoTimer?.cancel()
        undoAction = UndoableAction(label: label, reverseMutations: reverseMutations)
        undoTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard Task.isCancelled == false else { return }
            self?.undoAction = nil
        }
    }

    func perform(_ mutation: MailMutation, reportErrors: Bool = true, rollbackOnError: (() -> Void)? = nil) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await store.perform(mutation)
            } catch {
                rollbackOnError?()
                guard reportErrors else { return }
                present(error)
            }
        }
    }

    func scheduleDraftAutoSave() {
        draftAutoSaveTask?.cancel()
        draftAutoSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard Task.isCancelled == false, let self, let draft = self.composeDraft else { return }
            var updated = draft
            updated.updatedAt = Date()
            try? await self.store.saveDraft(updated)
            await self.store.reloadDrafts()
        }
    }

    func replySubject(for replyMode: ReplyMode) -> String {
        switch replyMode {
        case .new:
            return ""
        case .forward:
            let subject = selectedThreadDetail?.thread.subject ?? ""
            return subject.lowercased().hasPrefix("fwd:") ? subject : "Fwd: \(subject)"
        case .reply, .replyAll:
            let subject = selectedThreadDetail?.thread.subject ?? ""
            return subject.lowercased().hasPrefix("re:") ? subject : "Re: \(subject)"
        }
    }

    func forwardBody() -> String {
        guard let detail = selectedThreadDetail, let lastMessage = detail.messages.last else { return "" }
        var body = "\n\n---------- Forwarded message ---------\n"
        body += "From: \(lastMessage.sender.displayName) <\(lastMessage.sender.emailAddress)>\n"
        if let date = lastMessage.sentAt {
            body += "Date: \(date.formatted(.dateTime.year().month().day().hour().minute()))\n"
        }
        body += "Subject: \(detail.thread.subject)\n"
        body += "To: \(lastMessage.toRecipients.map { "\($0.displayName) <\($0.emailAddress)>" }.joined(separator: ", "))\n\n"
        body += lastMessage.plainBody ?? lastMessage.snippet
        return body
    }

    func replyQuotedMessage() -> DraftQuotedReply? {
        guard let detail = selectedThreadDetail, let lastMessage = detail.messages.last else { return nil }
        return DraftQuotedReply(
            subject: detail.thread.subject,
            sender: lastMessage.sender,
            sentAt: lastMessage.sentAt,
            plainBody: lastMessage.plainBody ?? lastMessage.snippet,
            htmlBody: lastMessage.htmlBody
        )
    }

    func signature(for accountID: MailAccountID) -> String {
        let key = "signature:\(accountID.rawValue)"
        return UserDefaults.standard.string(forKey: key) ?? ""
    }
}
