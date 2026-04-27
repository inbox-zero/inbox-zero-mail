import Foundation
import MailCore
import MailData
import Observation
import ProviderCore
import Testing
@testable import MailFeatures

private actor StubWorkspace: MailWorkspace {
    private var storedThreads: [MailThread]
    let detail: MailThreadDetail?
    let threadDetails: [MailThreadID: MailThreadDetail]
    let mailboxes: [MailboxRef]
    let performError: Error?
    let attachmentData: [String: Data]
    let threadQueryResults: [ThreadListQuery: [MailThread]]
    let threadCounts: [ThreadListQuery: Int]
    let startDelayNanoseconds: UInt64
    private var storedAccounts: [MailAccount]
    private var performedMutations: [MailMutation] = []
    private var reconnectedAccountIDs: [MailAccountID] = []
    private var removedAccountIDs: [MailAccountID] = []
    private var storedDrafts: [OutgoingDraft]
    private var sentDrafts: [OutgoingDraft] = []
    private var savedDrafts: [OutgoingDraft] = []
    private var deletedDraftIDs: [UUID] = []
    private let appliesMutationsToThreads: Bool

    init(
        accounts: [MailAccount],
        threads: [MailThread],
        detail: MailThreadDetail?,
        threadDetails: [MailThreadID: MailThreadDetail] = [:],
        mailboxes: [MailboxRef] = [],
        drafts: [OutgoingDraft] = [],
        performError: Error? = nil,
        attachmentData: [String: Data] = [:],
        threadQueryResults: [ThreadListQuery: [MailThread]] = [:],
        threadCounts: [ThreadListQuery: Int] = [:],
        startDelayNanoseconds: UInt64 = 0,
        appliesMutationsToThreads: Bool = false
    ) {
        self.storedAccounts = accounts
        self.storedThreads = threads
        self.detail = detail
        self.threadDetails = threadDetails
        self.mailboxes = mailboxes
        self.storedDrafts = drafts
        self.performError = performError
        self.attachmentData = attachmentData
        self.threadQueryResults = threadQueryResults
        self.threadCounts = threadCounts
        self.startDelayNanoseconds = startDelayNanoseconds
        self.appliesMutationsToThreads = appliesMutationsToThreads
    }

    func changes() async -> AsyncStream<Int> { AsyncStream { $0.finish() } }
    func start() async {
        if startDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: startDelayNanoseconds)
        }
    }
    func setForegroundActive(_ isActive: Bool) async {}
    func connectAccount(kind: ProviderKind) async throws {}
    func reconnectAccount(accountID: MailAccountID) async throws {
        reconnectedAccountIDs.append(accountID)
    }
    func listAccounts() async throws -> [MailAccount] { storedAccounts }
    func listThreads(query: ThreadListQuery) async throws -> [MailThread] {
        if let result = threadQueryResults[query] {
            return result
        }
        return storedThreads.filter { thread in
            switch query.tab {
            case .all:
                return query.mailboxScope == .allMail || thread.isInInbox
            case .unread:
                return thread.isInInbox && thread.hasUnread
            case .starred:
                return thread.isStarred
            case .snoozed:
                return thread.isSnoozed
            }
        }
    }
    func countThreads(query: ThreadListQuery) async throws -> Int {
        if let count = threadCounts[query] {
            return count
        }
        return try await listThreads(query: query).count
    }
    func loadThread(id: MailThreadID) async throws -> MailThreadDetail? {
        if let detail = threadDetails[id] {
            return detail
        }
        return detail?.thread.id == id ? detail : nil
    }
    func listMailboxes(accountID: MailAccountID?) async throws -> [MailboxRef] {
        guard let accountID else { return mailboxes }
        return mailboxes.filter { $0.accountID == accountID }
    }
    func refreshAll() async {}
    func perform(_ mutation: MailMutation) async throws {
        performedMutations.append(mutation)
        if let performError {
            throw performError
        }
        guard appliesMutationsToThreads else { return }
        switch mutation {
        case let .archive(threadID), let .trash(threadID):
            updateThread(threadID) { $0.isInInbox = false }
        case let .unarchive(threadID), let .untrash(threadID):
            updateThread(threadID) { $0.isInInbox = true }
        case let .markRead(threadID):
            updateThread(threadID) { $0.hasUnread = false }
        case let .markUnread(threadID):
            updateThread(threadID) { $0.hasUnread = true }
        case let .star(threadID):
            updateThread(threadID) { $0.isStarred = true }
        case let .unstar(threadID):
            updateThread(threadID) { $0.isStarred = false }
        case let .snooze(threadID, until):
            updateThread(threadID) { $0.snoozedUntil = until }
        case let .unsnooze(threadID):
            updateThread(threadID) { $0.snoozedUntil = nil }
        case .applyMailbox, .removeMailbox, .send:
            break
        }
    }
    func send(_ draft: OutgoingDraft) async throws {
        sentDrafts.append(draft)
    }
    func seedDemoDataIfNeeded() async throws {}
    func removeAccount(accountID: MailAccountID) async throws {
        removedAccountIDs.append(accountID)
        storedAccounts.removeAll { $0.id == accountID }
        storedDrafts.removeAll { $0.accountID == accountID }
    }
    func saveDraft(_ draft: OutgoingDraft) async throws {
        savedDrafts.append(draft)
        storedDrafts.removeAll { $0.id == draft.id }
        storedDrafts.append(draft)
    }
    func listDrafts() async throws -> [OutgoingDraft] { storedDrafts }
    func deleteDraft(id: UUID) async throws {
        deletedDraftIDs.append(id)
        storedDrafts.removeAll { $0.id == id }
    }
    func handleRedirectURL(_ url: URL) async -> Bool { false }
    func updateMailboxVisibility(mailboxID: MailboxID, hidden: Bool) async throws {}
    func fetchAttachment(_ attachment: MailAttachment) async throws -> Data {
        attachmentData[attachment.id] ?? Data()
    }

    func recordedMutations() async -> [MailMutation] {
        performedMutations
    }

    func recordedReconnectAccountIDs() async -> [MailAccountID] {
        reconnectedAccountIDs
    }

    func recordedRemovedAccountIDs() async -> [MailAccountID] {
        removedAccountIDs
    }

    func recordedSentDrafts() async -> [OutgoingDraft] {
        sentDrafts
    }

    func recordedSavedDrafts() async -> [OutgoingDraft] {
        savedDrafts
    }

    func recordedDeletedDraftIDs() async -> [UUID] {
        deletedDraftIDs
    }

    func replaceThreads(_ threads: [MailThread]) {
        storedThreads = threads
    }

    private func updateThread(_ threadID: MailThreadID, mutate: (inout MailThread) -> Void) {
        guard let index = storedThreads.firstIndex(where: { $0.id == threadID }) else { return }
        mutate(&storedThreads[index])
    }
}

/// Creates a WindowModel backed by a MailAppStore with the given stub workspace.
@MainActor
private func makeWindowModel(workspace: StubWorkspace) -> WindowModel {
    let store = MailAppStore(workspace: workspace)
    return WindowModel(store: store)
}

@Test
@MainActor
func reloadHydratesAccountsAndThreads() async {
    let account = makeAccount()
    let thread = makeThread(accountID: account.id)
    let model = makeWindowModel(workspace: StubWorkspace(accounts: [account], threads: [thread], detail: nil))

    await model.store.reloadSharedData(reason: .initial)
    await model.reloadThreads()

    #expect(model.accounts == [account])
    #expect(model.threads == [thread])
}

@Test
@MainActor
func mutationInOneWindowRefreshesOtherRegisteredWindows() async throws {
    let account = makeAccount()
    let thread = makeThread(accountID: account.id)
    let workspace = StubWorkspace(
        accounts: [account],
        threads: [thread],
        detail: nil,
        appliesMutationsToThreads: true
    )
    let store = MailAppStore(workspace: workspace)
    let firstWindow = WindowModel(store: store)
    let secondWindow = WindowModel(store: store)
    store.register(firstWindow)
    store.register(secondWindow)

    await store.reloadSharedData(reason: .initial)
    #expect(firstWindow.threads.map(\.id) == [thread.id])
    #expect(secondWindow.threads.map(\.id) == [thread.id])

    firstWindow.hoveredThreadID = thread.id
    firstWindow.archiveSelection()
    try await Task.sleep(for: .milliseconds(50))

    #expect(firstWindow.threads.isEmpty)
    #expect(secondWindow.threads.isEmpty)
}

@Test
@MainActor
func startLoadsCachedAccountsBeforeInitialRefreshCompletes() async throws {
    let account = makeAccount()
    let workspace = StubWorkspace(
        accounts: [account],
        threads: [],
        detail: nil,
        startDelayNanoseconds: 300_000_000
    )
    let store = MailAppStore(workspace: workspace)

    store.start()
    try await Task.sleep(for: .milliseconds(50))

    #expect(store.accounts == [account])
}

@Test
@MainActor
func newComposeDefaultsToNewReplyMode() {
    let model = makeWindowModel(workspace: StubWorkspace(accounts: [], threads: [], detail: nil))
    model.openCompose()
    #expect(model.composeDraft?.replyMode == .new)
    #expect(model.composeDraft?.threadID == nil)
}

@Test
@MainActor
func replyComposePrefillsSubjectAndRecipientFromFocusedThread() async throws {
    let account = makeAccount()
    let thread = makeThread(accountID: account.id)
    let detail = makeThreadDetail(accountID: account.id, thread: thread)
    let model = makeWindowModel(workspace: StubWorkspace(accounts: [account], threads: [thread], detail: detail))

    await model.store.reloadSharedData(reason: .initial)
    await model.reloadThreads()
    model.open(threadID: thread.id)
    try await Task.sleep(for: .milliseconds(50))
    model.openCompose(replyMode: .reply)

    #expect(model.composeDraft?.replyMode == .reply)
    #expect(model.composeDraft?.subject == "Re: \(thread.subject)")
    #expect(model.composeDraft?.toRecipients.first?.emailAddress == "sender@example.com")
    #expect(model.composeDraft?.threadID == thread.id)
}

@Test
@MainActor
func replyComposeStoresQuotedReplyOutsideEditableBody() async throws {
    let account = makeAccount()
    let thread = makeThread(accountID: account.id)
    let message = MailMessage(
        id: MailMessageID(accountID: account.id, providerMessageID: "message-quoted"),
        threadID: thread.id,
        accountID: account.id,
        providerMessageID: "message-quoted",
        sender: MailParticipant(name: "Sender", emailAddress: "sender@example.com"),
        toRecipients: [MailParticipant(name: "Alpha", emailAddress: "alpha@example.com")],
        sentAt: .now,
        receivedAt: .now,
        snippet: "Snippet fallback",
        plainBody: "Original reply body",
        htmlBody: "<p><strong>Original</strong> reply body</p>",
        bodyCacheState: .hot,
        headers: [MessageHeader(name: "Subject", value: thread.subject)],
        mailboxRefs: [],
        isRead: false,
        isOutgoing: false
    )
    let detail = MailThreadDetail(thread: thread, messages: [message])
    let model = makeWindowModel(workspace: StubWorkspace(accounts: [account], threads: [thread], detail: detail))

    await model.store.reloadSharedData(reason: .initial)
    await model.reloadThreads()
    model.open(threadID: thread.id)
    try await Task.sleep(for: .milliseconds(50))
    model.openCompose(replyMode: .reply)

    #expect(model.composeDraft?.plainBody.contains("Original reply body") == false)
    #expect(model.composeDraft?.quotedReply?.sender.emailAddress == "sender@example.com")
    #expect(model.composeDraft?.quotedReply?.plainBody == "Original reply body")
    #expect(model.composeDraft?.quotedReply?.htmlBody == "<p><strong>Original</strong> reply body</p>")
}

@Test
@MainActor
func openingUnreadThreadMarksItReadOptimistically() async throws {
    let account = makeAccount()
    let thread = makeThread(accountID: account.id)
    let workspace = StubWorkspace(accounts: [account], threads: [thread], detail: nil)
    let model = makeWindowModel(workspace: workspace)

    await model.store.reloadSharedData(reason: .initial)
    await model.reloadThreads()
    model.open(threadID: thread.id)
    try await Task.sleep(for: .milliseconds(50))

    let recorded = await workspace.recordedMutations()
    #expect(recorded == [.markRead(threadID: thread.id)])
}

@Test
@MainActor
func openingUnreadThreadSuppressesImplicitMarkReadErrors() async throws {
    let account = makeAccount()
    let thread = makeThread(accountID: account.id)
    let workspace = StubWorkspace(
        accounts: [account],
        threads: [thread],
        detail: nil,
        performError: MailProviderError.unauthorized
    )
    let model = makeWindowModel(workspace: workspace)

    await model.store.reloadSharedData(reason: .initial)
    await model.reloadThreads()
    model.open(threadID: thread.id)
    try await Task.sleep(for: .milliseconds(50))

    let recorded = await workspace.recordedMutations()
    #expect(recorded == [MailMutation.markRead(threadID: thread.id)])
    #expect(model.errorMessage == nil)
}

@Test
@MainActor
func unauthorizedErrorReconnectsFocusedAccount() async throws {
    let account = makeAccount()
    let thread = makeThread(accountID: account.id)
    let workspace = StubWorkspace(accounts: [account], threads: [thread], detail: nil)
    let model = makeWindowModel(workspace: workspace)

    await model.store.reloadSharedData(reason: .initial)
    await model.reloadThreads()
    model.select(accountID: account.id)
    model.open(threadID: thread.id)
    model.present(MailProviderError.unauthorized)

    #expect(model.errorReconnectAccountID == account.id)

    model.reconnect(accountID: account.id)
    try await Task.sleep(for: .milliseconds(50))

    let recordedReconnects = await workspace.recordedReconnectAccountIDs()
    #expect(recordedReconnects == [account.id])
    #expect(model.errorMessage == nil)
    #expect(model.errorReconnectAccountID == nil)
}

@Test
@MainActor
func disconnectSelectedAccountClearsWindowState() async throws {
    let account = makeAccount()
    let thread = makeThread(accountID: account.id)
    let workspace = StubWorkspace(accounts: [account], threads: [thread], detail: nil)
    let model = makeWindowModel(workspace: workspace)

    model.store.register(model)
    await model.store.reloadSharedData(reason: .initial)
    await model.reloadThreads()
    model.select(accountID: account.id)
    model.open(threadID: thread.id)

    model.disconnect(accountID: account.id)
    try await Task.sleep(for: .milliseconds(100))

    #expect(await workspace.recordedRemovedAccountIDs() == [account.id])
    #expect(model.accounts.isEmpty)
    #expect(model.selectedAccountID == nil)
    #expect(model.selectedThreadID == nil)
    #expect(model.selectedThreadDetail == nil)
    #expect(model.isThreadOpen == false)
}

@Test
@MainActor
func replyAllSkipsSelfAndDeduplicatesRecipients() async throws {
    let account = makeAccount()
    let thread = makeThread(accountID: account.id)
    let message = MailMessage(
        id: MailMessageID(accountID: account.id, providerMessageID: "message-2"),
        threadID: thread.id,
        accountID: account.id,
        providerMessageID: "message-2",
        sender: MailParticipant(name: "Alpha", emailAddress: "alpha@example.com"),
        toRecipients: [
            MailParticipant(name: "Customer", emailAddress: "customer@example.com"),
            MailParticipant(name: "Alpha", emailAddress: "alpha@example.com"),
        ],
        ccRecipients: [
            MailParticipant(name: "Ops", emailAddress: "ops@example.com"),
            MailParticipant(name: "Customer", emailAddress: "customer@example.com"),
        ],
        sentAt: .now,
        receivedAt: .now,
        snippet: thread.snippet,
        plainBody: "Body",
        bodyCacheState: .hot,
        headers: [MessageHeader(name: "Subject", value: thread.subject)],
        mailboxRefs: [],
        isRead: false,
        isOutgoing: true
    )
    let detail = MailThreadDetail(thread: thread, messages: [message])
    let model = makeWindowModel(workspace: StubWorkspace(accounts: [account], threads: [thread], detail: detail))

    await model.store.reloadSharedData(reason: .initial)
    await model.reloadThreads()
    model.open(threadID: thread.id)
    try await Task.sleep(for: .milliseconds(50))
    model.openCompose(replyMode: .replyAll)

    #expect(model.composeDraft?.toRecipients.map(\.emailAddress) == ["customer@example.com", "ops@example.com"])
}

@Test
@MainActor
func openingDraftThreadOpensComposeEditor() async {
    let account = makeAccount()
    let draftMailbox = MailboxRef(
        id: MailboxID(accountID: account.id, providerMailboxID: "DRAFT"),
        accountID: account.id,
        providerMailboxID: "DRAFT",
        displayName: "Drafts",
        kind: .system,
        systemRole: .draft
    )
    let thread = makeThread(accountID: account.id, mailboxRefs: [draftMailbox])
    let draft = OutgoingDraft(
        accountID: account.id,
        providerDraftID: "draft-1",
        replyMode: .reply,
        threadID: thread.id,
        toRecipients: [MailParticipant(name: "Sender", emailAddress: "sender@example.com")],
        subject: thread.subject,
        plainBody: "Saved draft body"
    )
    let workspace = StubWorkspace(
        accounts: [account],
        threads: [thread],
        detail: nil,
        mailboxes: [draftMailbox],
        drafts: [draft]
    )
    let model = makeWindowModel(workspace: workspace)

    await model.store.reloadSharedData(reason: .initial)
    await model.reloadThreads()
    model.open(threadID: thread.id)

    #expect(model.composeDraft == draft)
    #expect(model.composeMode == .floating)
    #expect(model.isThreadOpen == false)
}

@Test
@MainActor
func sendComposeSendsDraftDeletesPersistedCopyAndClearsComposeState() async throws {
    let account = makeAccount()
    let draft = OutgoingDraft(
        accountID: account.id,
        replyMode: .new,
        toRecipients: [MailParticipant(name: "Taylor", emailAddress: "taylor@example.com")],
        subject: "Quarterly update",
        plainBody: "Ship it."
    )
    let workspace = StubWorkspace(accounts: [account], threads: [], detail: nil, drafts: [draft])
    let model = makeWindowModel(workspace: workspace)

    await model.store.reloadSharedData(reason: .initial)
    model.openDraft(draft)
    model.sendCompose()
    try await Task.sleep(for: .milliseconds(50))

    let sentDrafts = await workspace.recordedSentDrafts()
    let deletedDraftIDs = await workspace.recordedDeletedDraftIDs()
    #expect(sentDrafts == [draft])
    #expect(deletedDraftIDs == [draft.id])
    #expect(model.composeDraft == nil)
    #expect(model.composeMode == nil)
}

@Test
@MainActor
func dismissComposeSavesNonEmptyDraftAndClearsComposeState() async throws {
    let account = makeAccount()
    let workspace = StubWorkspace(accounts: [account], threads: [], detail: nil)
    let model = makeWindowModel(workspace: workspace)

    await model.store.reloadSharedData(reason: .initial)
    model.openCompose()
    var draft = try #require(model.composeDraft)
    draft.subject = "Follow up"
    draft.plainBody = "Replying with details."
    draft.toRecipients = [MailParticipant(name: "Taylor", emailAddress: "taylor@example.com")]
    model.updateCompose(draft)
    model.dismissCompose()
    try await Task.sleep(for: .milliseconds(50))

    let savedDrafts = await workspace.recordedSavedDrafts()
    #expect(savedDrafts.count == 1)
    #expect(savedDrafts.first?.subject == "Follow up")
    #expect(savedDrafts.first?.toRecipients.map(\.emailAddress) == ["taylor@example.com"])
    #expect(model.composeDraft == nil)
    #expect(model.composeMode == nil)
}

@Test
@MainActor
func dismissComposeDoesNotSaveEmptyDraft() async throws {
    let account = makeAccount()
    let workspace = StubWorkspace(accounts: [account], threads: [], detail: nil)
    let model = makeWindowModel(workspace: workspace)

    await model.store.reloadSharedData(reason: .initial)
    model.openCompose()
    model.dismissCompose()
    try await Task.sleep(for: .milliseconds(50))

    #expect(await workspace.recordedSavedDrafts().isEmpty)
    #expect(model.composeDraft == nil)
    #expect(model.composeMode == nil)
}

@Test
@MainActor
func composeModeTransitionsCoverInlineFloatingAndFullscreen() async throws {
    let account = makeAccount()
    let thread = makeThread(accountID: account.id)
    let detail = makeThreadDetail(accountID: account.id, thread: thread)
    let model = makeWindowModel(workspace: StubWorkspace(accounts: [account], threads: [thread], detail: detail))

    await model.store.reloadSharedData(reason: .initial)
    await model.reloadThreads()
    model.open(threadID: thread.id)
    try await Task.sleep(for: .milliseconds(50))
    model.openCompose(replyMode: .reply)

    #expect(model.composeMode == .inline)
    model.popOutCompose()
    #expect(model.composeMode == .floating)
    model.expandCompose()
    #expect(model.composeMode == .fullscreen)
    model.minimizeCompose()
    #expect(model.composeMode == .floating)
}

@Test
@MainActor
func deleteDraftRemovesDraftFromWorkspace() async throws {
    let account = makeAccount()
    let draft = OutgoingDraft(
        accountID: account.id,
        providerDraftID: "draft-2",
        replyMode: .new,
        subject: "Draft to delete",
        plainBody: "Temporary"
    )
    let workspace = StubWorkspace(accounts: [account], threads: [], detail: nil, drafts: [draft])
    let model = makeWindowModel(workspace: workspace)

    await model.store.reloadSharedData(reason: .initial)
    model.deleteDraft(draft)
    try await Task.sleep(for: .milliseconds(50))

    #expect(await workspace.recordedDeletedDraftIDs() == [draft.id])
}

@Test
@MainActor
func fetchingAttachmentDataUsesWorkspaceResult() async throws {
    let account = makeAccount()
    let attachment = MailAttachment(
        id: "att-1",
        messageID: MailMessageID(accountID: account.id, providerMessageID: "message-1"),
        filename: "invoice.html",
        mimeType: "text/html",
        size: 12
    )
    let expected = Data("hello world".utf8)
    let model = makeWindowModel(
        workspace: StubWorkspace(
            accounts: [account],
            threads: [],
            detail: nil,
            attachmentData: [attachment.id: expected]
        )
    )

    let data = try await model.fetchAttachmentData(attachment)
    #expect(data == expected)
}

@Test
@MainActor
func selectingUnifiedTabClearsAccountAndMailboxFilters() {
    let accountID = MailAccountID(rawValue: "gmail:alpha@example.com")
    let model = makeWindowModel(workspace: StubWorkspace(accounts: [], threads: [], detail: nil))
    model.selectedAccountID = accountID
    model.selectedMailboxID = MailboxID(accountID: accountID, providerMailboxID: "Label_ops")

    model.select(tab: .starred)

    #expect(model.selectedTab == .starred)
    #expect(model.selectedAccountID == nil)
    #expect(model.selectedMailboxID == nil)
}

@Test
@MainActor
func sidebarNavigationKeepsSidebarVisible() {
    let account = makeAccount()
    let mailboxID = MailboxID(accountID: account.id, providerMailboxID: "INBOX")
    let model = makeWindowModel(workspace: StubWorkspace(accounts: [account], threads: [], detail: nil))
    model.isSidebarVisible = true

    model.select(tab: .starred)
    #expect(model.isSidebarVisible)

    model.selectSplitInbox(tab: .unread)
    #expect(model.isSidebarVisible)

    model.select(accountID: account.id)
    #expect(model.isSidebarVisible)

    model.select(mailboxID: mailboxID)
    #expect(model.isSidebarVisible)

    model.selectAllMail(accountID: account.id)
    #expect(model.isSidebarVisible)
}

@Test
@MainActor
func reloadThreadsRefreshesSplitInboxCounts() async {
    let account = makeAccount()
    let allQuery = ThreadListQuery(tab: .all, mailboxScope: .inboxOnly, limit: 100)
    let unreadQuery = ThreadListQuery(tab: .unread, mailboxScope: .inboxOnly, limit: 100)
    let starredQuery = ThreadListQuery(tab: .starred, mailboxScope: .inboxOnly, limit: 100)
    let snoozedQuery = ThreadListQuery(tab: .snoozed, mailboxScope: .inboxOnly, limit: 100)
    let visibleThread = makeThread(accountID: account.id)
    let model = makeWindowModel(
        workspace: StubWorkspace(
            accounts: [account],
            threads: [],
            detail: nil,
            threadQueryResults: [allQuery: [visibleThread]],
            threadCounts: [
                allQuery: 9,
                unreadQuery: 4,
                starredQuery: 2,
                snoozedQuery: 1,
            ]
        )
    )

    await model.reloadThreads()

    #expect(model.threads == [visibleThread])
    #expect(model.splitInboxCount(for: .all) == 9)
    #expect(model.splitInboxCount(for: .unread) == 4)
    #expect(model.splitInboxCount(for: .starred) == 2)
    #expect(model.splitInboxCount(for: .snoozed) == 1)
}

@Test
@MainActor
func cyclingSplitInboxWrapsForwardAndBackward() {
    let model = makeWindowModel(workspace: StubWorkspace(accounts: [], threads: [], detail: nil))

    model.select(tab: .all)
    model.cycleSplitInbox()
    #expect(model.selectedTab == .unread)

    model.select(tab: .all)
    model.cycleSplitInbox(forward: false)
    #expect(model.selectedTab == .snoozed)
}

@Test
@MainActor
func cyclingSplitInboxUsesProvidedTabOrderAndSubset() {
    let model = makeWindowModel(workspace: StubWorkspace(accounts: [], threads: [], detail: nil))

    model.select(tab: .all)
    model.cycleSplitInbox(in: [.builtIn(.all), .builtIn(.starred)], forward: true)
    #expect(model.selectedTab == .starred)

    model.cycleSplitInbox(in: [.builtIn(.all), .builtIn(.starred)], forward: true)
    #expect(model.selectedTab == .all)

    model.selectedTab = .unread
    model.selectedSplitInboxItem = .builtIn(.unread)
    model.cycleSplitInbox(in: [.builtIn(.starred), .builtIn(.snoozed)], forward: true)
    #expect(model.selectedTab == .starred)
}

@Test
@MainActor
func selectingCustomSplitInboxUsesItsStoredQuery() async {
    let account = makeAccount()
    let customItem = SplitInboxItem(title: "Receipts", tab: .all, queryText: "label:receipts")
    let matchingQuery = ThreadListQuery(
        tab: .all,
        accountFilter: account.id,
        mailboxScope: .inboxOnly,
        splitInboxQueryText: "label:receipts",
        limit: 100
    )
    let visibleThread = makeThread(accountID: account.id)
    let model = makeWindowModel(
        workspace: StubWorkspace(
            accounts: [account],
            threads: [],
            detail: nil,
            threadQueryResults: [matchingQuery: [visibleThread]],
            threadCounts: [matchingQuery: 3]
        )
    )
    model.selectedAccountID = account.id
    model.setSplitInboxItems([.builtIn(.all), customItem])

    model.select(splitInboxItem: customItem)
    await model.reloadThreads()

    #expect(model.selectedSplitInboxItem == customItem)
    #expect(model.threads == [visibleThread])
    #expect(model.splitInboxCount(for: customItem) == 3)
}

@Test
@MainActor
func selectingSplitInboxTabPreservesSelectedAccountScope() {
    let account = makeAccount()
    let model = makeWindowModel(workspace: StubWorkspace(accounts: [account], threads: [], detail: nil))
    model.selectedAccountID = account.id
    model.selectedTab = .all

    model.selectSplitInbox(tab: .starred)

    #expect(model.selectedTab == .starred)
    #expect(model.selectedAccountID == account.id)
    #expect(model.isSplitInboxVisible)
}

@Test
@MainActor
func commandPaletteCountsAsModalState() {
    let model = makeWindowModel(workspace: StubWorkspace(accounts: [], threads: [], detail: nil))

    model.openCommandPalette()

    #expect(model.isCommandPalettePresented)
    #expect(model.isModalPresented)

    model.closeCommandPalette()

    #expect(model.isCommandPalettePresented == false)
    #expect(model.isModalPresented == false)
}

@Test
@MainActor
func selectingAccountResetsToAccountInboxAndClearsMailbox() {
    let account = makeAccount()
    let model = makeWindowModel(workspace: StubWorkspace(accounts: [account], threads: [], detail: nil))
    model.selectedTab = .unread
    model.selectedMailboxID = MailboxID(accountID: account.id, providerMailboxID: "Label_ops")
    model.mailboxScope = .allMail

    model.select(accountID: account.id)

    #expect(model.selectedTab == .all)
    #expect(model.selectedAccountID == account.id)
    #expect(model.selectedMailboxID == nil)
    #expect(model.mailboxScope == .inboxOnly)
}

@Test
@MainActor
func togglingSelectedAccountReturnsToTopLevelInbox() {
    let account = makeAccount()
    let model = makeWindowModel(workspace: StubWorkspace(accounts: [account], threads: [], detail: nil))

    model.toggleAccountSelection(accountID: account.id)
    #expect(model.selectedAccountID == account.id)

    model.toggleAccountSelection(accountID: account.id)
    #expect(model.selectedAccountID == nil)
    #expect(model.selectedMailboxID == nil)
    #expect(model.mailboxScope == .inboxOnly)
    #expect(model.selectedTab == .all)
}

@Test
@MainActor
func labelPickerOnlyIncludesRealLabelMailboxes() async throws {
    let account = makeAccount()
    let thread = makeThread(accountID: account.id)
    let detail = makeThreadDetail(accountID: account.id, thread: thread)
    let mailboxes = [
        MailboxRef(
            id: MailboxID(accountID: account.id, providerMailboxID: "Label_ops"),
            accountID: account.id,
            providerMailboxID: "Label_ops",
            displayName: "Ops",
            kind: .label
        ),
        MailboxRef(
            id: MailboxID(accountID: account.id, providerMailboxID: "CATEGORY_green"),
            accountID: account.id,
            providerMailboxID: "CATEGORY_green",
            displayName: "Green",
            kind: .category
        ),
        MailboxRef(
            id: MailboxID(accountID: account.id, providerMailboxID: "FOLDER_archive"),
            accountID: account.id,
            providerMailboxID: "FOLDER_archive",
            displayName: "Archive Folder",
            kind: .folder
        ),
        MailboxRef(
            id: MailboxID(accountID: account.id, providerMailboxID: "IMPORTANT"),
            accountID: account.id,
            providerMailboxID: "IMPORTANT",
            displayName: "Important",
            kind: .system,
            systemRole: .important
        ),
    ]
    let model = makeWindowModel(
        workspace: StubWorkspace(accounts: [account], threads: [thread], detail: detail, mailboxes: mailboxes)
    )

    await model.store.reloadSharedData(reason: .initial)
    await model.reloadThreads()
    model.open(threadID: thread.id)
    try await Task.sleep(for: .milliseconds(50))

    #expect(model.taggableMailboxesForSelectedThread.map(\.providerMailboxID).sorted() == ["IMPORTANT", "Label_ops"])
}

@Test
@MainActor
func folderPickerOpensForOutlookFolders() async throws {
    let account = MailAccount(
        id: MailAccountID(rawValue: "microsoft:ops@example.com"),
        providerKind: .microsoft,
        providerAccountID: "ops@example.com",
        primaryEmail: "ops@example.com",
        displayName: "Ops",
        capabilities: .init(supportsArchive: true, supportsLabels: false, supportsFolders: true, supportsCategories: true, supportsCompose: false)
    )
    let thread = makeThread(accountID: account.id)
    let detail = makeThreadDetail(accountID: account.id, thread: thread)
    let mailboxes = [
        MailboxRef(
            id: MailboxID(accountID: account.id, providerMailboxID: "inbox"),
            accountID: account.id,
            providerMailboxID: "inbox",
            displayName: "Inbox",
            kind: .folder,
            systemRole: .inbox
        ),
    ]
    let model = makeWindowModel(
        workspace: StubWorkspace(accounts: [account], threads: [thread], detail: detail, mailboxes: mailboxes)
    )

    await model.store.reloadSharedData(reason: .initial)
    await model.reloadThreads()
    model.open(threadID: thread.id)
    model.hoveredThreadID = thread.id
    try await Task.sleep(for: .milliseconds(50))
    model.showFolderPicker()

    #expect(model.isFolderPickerPresented == true)
    #expect(model.errorMessage == nil)
}

@Test
@MainActor
func outlookCategoriesUseTheSharedTagMailboxAbstraction() async throws {
    let account = MailAccount(
        id: MailAccountID(rawValue: "microsoft:ops@example.com"),
        providerKind: .microsoft,
        providerAccountID: "ops@example.com",
        primaryEmail: "ops@example.com",
        displayName: "Ops",
        capabilities: .init(supportsArchive: true, supportsLabels: false, supportsFolders: true, supportsCategories: true, supportsCompose: false)
    )
    let thread = makeThread(accountID: account.id)
    let detail = makeThreadDetail(accountID: account.id, thread: thread)
    let category = MailboxRef(
        id: MailboxID(accountID: account.id, providerMailboxID: "follow-up"),
        accountID: account.id,
        providerMailboxID: "follow-up",
        displayName: "Follow Up",
        kind: .category
    )
    let model = makeWindowModel(
        workspace: StubWorkspace(accounts: [account], threads: [thread], detail: detail, mailboxes: [category])
    )

    await model.store.reloadSharedData(reason: .initial)
    await model.reloadThreads()
    model.open(threadID: thread.id)
    model.hoveredThreadID = thread.id
    try await Task.sleep(for: .milliseconds(50))

    #expect(model.mailboxTagSingular == "Category")
    #expect(model.taggableMailboxesForFocusedThread.map(\.providerMailboxID) == ["follow-up"])
}

@Test
@MainActor
func forwardComposeStartsNewConversationInsteadOfReusingThreadID() async throws {
    let account = makeAccount()
    let thread = makeThread(accountID: account.id)
    let detail = makeThreadDetail(accountID: account.id, thread: thread)
    let model = makeWindowModel(workspace: StubWorkspace(accounts: [account], threads: [thread], detail: detail))

    await model.store.reloadSharedData(reason: .initial)
    await model.reloadThreads()
    model.open(threadID: thread.id)
    try await Task.sleep(for: .milliseconds(50))
    model.openCompose(replyMode: .forward)

    #expect(model.composeDraft?.replyMode == .forward)
    #expect(model.composeDraft?.threadID == nil)
}

@Test
@MainActor
func batchArchiveUndoReplaysReverseMutationForEverySelectedThread() async throws {
    let account = makeAccount()
    let first = makeThread(accountID: account.id)
    let second = MailThread(
        id: MailThreadID(accountID: account.id, providerThreadID: "thread-2"),
        accountID: account.id,
        providerThreadID: "thread-2",
        subject: "Customer follow-up",
        participantSummary: "Customer",
        snippet: "Need an answer today.",
        lastActivityAt: .now.addingTimeInterval(-60),
        hasUnread: true,
        isStarred: false,
        isInInbox: true,
        syncRevision: "rev-2"
    )
    let workspace = StubWorkspace(accounts: [account], threads: [first, second], detail: nil)
    let model = makeWindowModel(workspace: workspace)

    await model.store.reloadSharedData(reason: .initial)
    await model.reloadThreads()
    model.selectThread(threadID: first.id)
    model.toggleMultiSelect(threadID: first.id)
    model.toggleMultiSelect(threadID: second.id)
    model.batchArchive()
    try await Task.sleep(for: .milliseconds(50))
    model.performUndo()
    try await Task.sleep(for: .milliseconds(50))

    let recorded = await workspace.recordedMutations()
    #expect(recorded == [
        .archive(threadID: first.id),
        .archive(threadID: second.id),
        .unarchive(threadID: first.id),
        .unarchive(threadID: second.id),
    ])
}

@Test
@MainActor
func batchArchiveRemovesSelectedThreadsFromVisibleListImmediately() async throws {
    let account = makeAccount()
    let first = makeThread(accountID: account.id, providerThreadID: "thread-1", hasUnread: false)
    let second = makeThread(accountID: account.id, providerThreadID: "thread-2", subject: "Second", hasUnread: false)
    let third = makeThread(accountID: account.id, providerThreadID: "thread-3", subject: "Third", hasUnread: false)
    let workspace = StubWorkspace(accounts: [account], threads: [first, second, third], detail: nil)
    let model = makeWindowModel(workspace: workspace)

    await model.store.reloadSharedData(reason: .initial)
    await model.reloadThreads()
    model.hoveredThreadID = first.id
    model.toggleMultiSelect(threadID: first.id)
    model.toggleMultiSelect(threadID: second.id)

    model.batchArchive()

    #expect(model.threads.map(\.id) == [third.id])
    #expect(model.multiSelectedIDs.isEmpty)
    #expect(model.selectedThreadID == nil)
}

@Test
@MainActor
func archivingSelectedThreadWithoutHoverAdvancesToNextVisibleThread() async throws {
    let account = makeAccount()
    let first = makeThread(accountID: account.id, providerThreadID: "thread-1", hasUnread: false)
    let second = makeThread(accountID: account.id, providerThreadID: "thread-2", subject: "Second", hasUnread: false)
    let firstDetail = makeThreadDetail(accountID: account.id, thread: first)
    let secondDetail = makeThreadDetail(accountID: account.id, thread: second)
    let workspace = StubWorkspace(
        accounts: [account],
        threads: [first, second],
        detail: firstDetail,
        threadDetails: [
            first.id: firstDetail,
            second.id: secondDetail,
        ]
    )
    let model = makeWindowModel(workspace: workspace)

    await model.store.reloadSharedData(reason: .initial)
    await model.reloadThreads()
    model.open(threadID: first.id)
    model.hoveredThreadID = nil
    try await Task.sleep(for: .milliseconds(50))

    model.toggleArchiveSelection()

    #expect(model.selectedThreadDetail?.thread.id == second.id)
    try await Task.sleep(for: .milliseconds(50))
    let recorded = await workspace.recordedMutations()
    #expect(recorded == [.archive(threadID: first.id)])
    #expect(model.hoveredThreadID == second.id)
    #expect(model.selectedThreadID == second.id)
    #expect(model.isThreadOpen)
}

@Test
@MainActor
func archivingThreadRemovesItFromVisibleListImmediately() async throws {
    let account = makeAccount()
    let first = makeThread(accountID: account.id, providerThreadID: "thread-1", hasUnread: false)
    let second = makeThread(accountID: account.id, providerThreadID: "thread-2", subject: "Second", hasUnread: false)
    let firstDetail = makeThreadDetail(accountID: account.id, thread: first)
    let secondDetail = makeThreadDetail(accountID: account.id, thread: second)
    let workspace = StubWorkspace(
        accounts: [account],
        threads: [first, second],
        detail: firstDetail,
        threadDetails: [
            first.id: firstDetail,
            second.id: secondDetail,
        ]
    )
    let model = makeWindowModel(workspace: workspace)

    await model.store.reloadSharedData(reason: .initial)
    await model.reloadThreads()
    model.open(threadID: first.id)
    model.hoveredThreadID = nil
    try await Task.sleep(for: .milliseconds(50))

    model.toggleArchiveSelection()

    #expect(model.threads.map(\.id) == [second.id])
}

@Test
@MainActor
func archiveFailureRestoresVisibleList() async throws {
    let account = makeAccount()
    let first = makeThread(accountID: account.id, providerThreadID: "thread-1", hasUnread: false)
    let second = makeThread(accountID: account.id, providerThreadID: "thread-2", subject: "Second", hasUnread: false)
    let firstDetail = makeThreadDetail(accountID: account.id, thread: first)
    let workspace = StubWorkspace(
        accounts: [account],
        threads: [first, second],
        detail: firstDetail,
        threadDetails: [first.id: firstDetail],
        performError: MailProviderError.unauthorized
    )
    let model = makeWindowModel(workspace: workspace)

    await model.store.reloadSharedData(reason: .initial)
    await model.reloadThreads()
    model.open(threadID: first.id)
    model.hoveredThreadID = nil
    try await Task.sleep(for: .milliseconds(50))

    model.toggleArchiveSelection()
    #expect(model.threads.map(\.id) == [second.id])

    try await Task.sleep(for: .milliseconds(50))

    #expect(model.threads.map(\.id) == [first.id, second.id])
    #expect(model.selectedThreadID == first.id)
}

@Test
@MainActor
func archivingThreadInAllMailDoesNotRemoveItFromVisibleList() async throws {
    let account = makeAccount()
    let first = makeThread(accountID: account.id, providerThreadID: "thread-1", hasUnread: false)
    let second = makeThread(accountID: account.id, providerThreadID: "thread-2", subject: "Second", hasUnread: false)
    let workspace = StubWorkspace(
        accounts: [account],
        threads: [first, second],
        detail: makeThreadDetail(accountID: account.id, thread: first)
    )
    let model = makeWindowModel(workspace: workspace)

    await model.store.reloadSharedData(reason: .initial)
    await model.reloadThreads()
    model.mailboxScope = .allMail
    model.open(threadID: first.id)
    model.hoveredThreadID = nil
    try await Task.sleep(for: .milliseconds(50))

    model.toggleArchiveSelection()

    #expect(model.threads.map(\.id) == [first.id, second.id])
}

@Test
@MainActor
func showSnoozePickerUsesSelectedThreadWhenNothingIsHovered() async throws {
    let account = makeAccount()
    let thread = makeThread(accountID: account.id)
    let detail = makeThreadDetail(accountID: account.id, thread: thread)
    let model = makeWindowModel(workspace: StubWorkspace(accounts: [account], threads: [thread], detail: detail))

    await model.store.reloadSharedData(reason: .initial)
    await model.reloadThreads()
    model.open(threadID: thread.id)
    model.hoveredThreadID = nil
    try await Task.sleep(for: .milliseconds(50))

    model.showSnoozePicker()

    #expect(model.isSnoozePickerPresented)
    #expect(model.hoveredThreadID == thread.id)
}

@Test
@MainActor
func snoozingSelectedThreadWithoutHoverAdvancesToNextVisibleThread() async throws {
    let account = makeAccount()
    let first = makeThread(accountID: account.id, providerThreadID: "thread-1", hasUnread: false)
    let second = makeThread(accountID: account.id, providerThreadID: "thread-2", subject: "Second", hasUnread: false)
    let firstDetail = makeThreadDetail(accountID: account.id, thread: first)
    let secondDetail = makeThreadDetail(accountID: account.id, thread: second)
    let workspace = StubWorkspace(
        accounts: [account],
        threads: [first, second],
        detail: firstDetail,
        threadDetails: [
            first.id: firstDetail,
            second.id: secondDetail,
        ]
    )
    let model = makeWindowModel(workspace: workspace)

    await model.store.reloadSharedData(reason: .initial)
    await model.reloadThreads()
    model.open(threadID: first.id)
    model.hoveredThreadID = nil
    try await Task.sleep(for: .milliseconds(50))

    model.snoozeSelection(until: .now.addingTimeInterval(3600))

    #expect(model.selectedThreadDetail?.thread.id == second.id)
    try await Task.sleep(for: .milliseconds(50))
    let recorded = await workspace.recordedMutations()
    #expect(recorded.count == 1)
    #expect({
        guard case .snooze(threadID: first.id, until: _) = recorded[0] else { return false }
        return true
    }())
    #expect(model.hoveredThreadID == second.id)
    #expect(model.selectedThreadID == second.id)
    #expect(model.isThreadOpen)
}

@Test
@MainActor
func snoozingThreadRemovesItFromVisibleListImmediately() async throws {
    let account = makeAccount()
    let first = makeThread(accountID: account.id, providerThreadID: "thread-1", hasUnread: false)
    let second = makeThread(accountID: account.id, providerThreadID: "thread-2", subject: "Second", hasUnread: false)
    let firstDetail = makeThreadDetail(accountID: account.id, thread: first)
    let secondDetail = makeThreadDetail(accountID: account.id, thread: second)
    let workspace = StubWorkspace(
        accounts: [account],
        threads: [first, second],
        detail: firstDetail,
        threadDetails: [
            first.id: firstDetail,
            second.id: secondDetail,
        ]
    )
    let model = makeWindowModel(workspace: workspace)

    await model.store.reloadSharedData(reason: .initial)
    await model.reloadThreads()
    model.open(threadID: first.id)
    model.hoveredThreadID = nil
    try await Task.sleep(for: .milliseconds(50))

    model.snoozeSelection(until: .now.addingTimeInterval(3600))

    #expect(model.threads.map(\.id) == [second.id])
}

@Test
@MainActor
func unsnoozingSelectedThreadWithoutHoverAdvancesToNextSnoozedThread() async throws {
    let account = makeAccount()
    let snoozedUntil = Date().addingTimeInterval(3600)
    let first = makeThread(accountID: account.id, providerThreadID: "thread-1", hasUnread: false, snoozedUntil: snoozedUntil)
    let second = makeThread(accountID: account.id, providerThreadID: "thread-2", subject: "Second", hasUnread: false, snoozedUntil: snoozedUntil)
    let firstDetail = makeThreadDetail(accountID: account.id, thread: first)
    let secondDetail = makeThreadDetail(accountID: account.id, thread: second)
    let workspace = StubWorkspace(
        accounts: [account],
        threads: [first, second],
        detail: firstDetail,
        threadDetails: [
            first.id: firstDetail,
            second.id: secondDetail,
        ]
    )
    let model = makeWindowModel(workspace: workspace)

    await model.store.reloadSharedData(reason: .initial)
    await model.reloadThreads()
    model.selectedTab = .snoozed
    model.open(threadID: first.id)
    model.hoveredThreadID = nil
    try await Task.sleep(for: .milliseconds(50))

    model.unsnoozeSelection()

    #expect(model.selectedThreadDetail?.thread.id == second.id)
    try await Task.sleep(for: .milliseconds(50))
    let recorded = await workspace.recordedMutations()
    #expect(recorded == [.unsnooze(threadID: first.id)])
    #expect(model.hoveredThreadID == second.id)
    #expect(model.selectedThreadID == second.id)
    #expect(model.isThreadOpen)
}

@Test
@MainActor
func unsnoozingThreadInSnoozedTabRemovesItFromVisibleListImmediately() async throws {
    let account = makeAccount()
    let snoozedUntil = Date().addingTimeInterval(3600)
    let first = makeThread(accountID: account.id, providerThreadID: "thread-1", hasUnread: false, snoozedUntil: snoozedUntil)
    let second = makeThread(accountID: account.id, providerThreadID: "thread-2", subject: "Second", hasUnread: false, snoozedUntil: snoozedUntil)
    let firstDetail = makeThreadDetail(accountID: account.id, thread: first)
    let secondDetail = makeThreadDetail(accountID: account.id, thread: second)
    let workspace = StubWorkspace(
        accounts: [account],
        threads: [first, second],
        detail: firstDetail,
        threadDetails: [
            first.id: firstDetail,
            second.id: secondDetail,
        ]
    )
    let model = makeWindowModel(workspace: workspace)

    await model.store.reloadSharedData(reason: .initial)
    await model.reloadThreads()
    model.selectedTab = .snoozed
    model.open(threadID: first.id)
    model.hoveredThreadID = nil
    try await Task.sleep(for: .milliseconds(50))

    model.unsnoozeSelection()

    #expect(model.threads.map(\.id) == [second.id])
}

@Test
@MainActor
func toggleArchiveSelectionUsesUnarchiveForArchivedThread() async throws {
    let account = makeAccount()
    let archived = makeThread(accountID: account.id, hasUnread: false, isInInbox: false)
    let detail = makeThreadDetail(accountID: account.id, thread: archived)
    let workspace = StubWorkspace(accounts: [account], threads: [archived], detail: detail)
    let model = makeWindowModel(workspace: workspace)

    await model.store.reloadSharedData(reason: MailReloadReason.initial)
    await model.reloadThreads()
    model.open(threadID: archived.id)
    model.hoveredThreadID = nil
    try await Task.sleep(for: .milliseconds(50))

    model.toggleArchiveSelection()
    try await Task.sleep(for: .milliseconds(50))

    let recorded = await workspace.recordedMutations()
    #expect(recorded == [MailMutation.unarchive(threadID: archived.id)])
    #expect(model.selectedThreadID == archived.id)
}

@Test
@MainActor
func actionableThreadIDsFollowVisibleThreadOrder() async {
    let account = makeAccount()
    let first = makeThread(accountID: account.id)
    let second = MailThread(
        id: MailThreadID(accountID: account.id, providerThreadID: "thread-2"),
        accountID: account.id,
        providerThreadID: "thread-2",
        subject: "Second",
        participantSummary: "Customer",
        snippet: "Second thread",
        lastActivityAt: .now.addingTimeInterval(-60),
        hasUnread: true,
        isStarred: false,
        isInInbox: true,
        syncRevision: "rev-2"
    )
    let third = MailThread(
        id: MailThreadID(accountID: account.id, providerThreadID: "thread-3"),
        accountID: account.id,
        providerThreadID: "thread-3",
        subject: "Third",
        participantSummary: "Customer",
        snippet: "Third thread",
        lastActivityAt: .now.addingTimeInterval(-120),
        hasUnread: true,
        isStarred: false,
        isInInbox: true,
        syncRevision: "rev-3"
    )
    let model = makeWindowModel(workspace: StubWorkspace(accounts: [account], threads: [first, second, third], detail: nil))

    await model.store.reloadSharedData(reason: .initial)
    await model.reloadThreads()
    model.toggleMultiSelect(threadID: third.id)
    model.toggleMultiSelect(threadID: first.id)
    model.toggleMultiSelect(threadID: second.id)

    #expect(model.actionableThreadIDs == [first.id, second.id, third.id])
}

@Test
@MainActor
func enterMultiSelectUsesCurrentThreadOrFallsBackToFirstThread() async throws {
    let account = makeAccount()
    let first = makeThread(accountID: account.id)
    let second = MailThread(
        id: MailThreadID(accountID: account.id, providerThreadID: "thread-2"),
        accountID: account.id,
        providerThreadID: "thread-2",
        subject: "Customer follow-up",
        participantSummary: "Customer",
        snippet: "Need an answer today.",
        lastActivityAt: .now.addingTimeInterval(-60),
        hasUnread: true,
        isStarred: false,
        isInInbox: true,
        syncRevision: "rev-2"
    )
    let model = makeWindowModel(workspace: StubWorkspace(accounts: [account], threads: [first, second], detail: nil))

    await model.store.reloadSharedData(reason: .initial)
    await model.reloadThreads()
    model.enterMultiSelect()

    #expect(model.hoveredThreadID == first.id)
    #expect(model.multiSelectedIDs == [first.id])

    model.deselectAll()
    model.hoveredThreadID = second.id
    model.enterMultiSelect()

    #expect(model.hoveredThreadID == second.id)
    #expect(model.multiSelectedIDs == [second.id])
}

@Test
@MainActor
func selectAllKeepsACurrentSelectionForKeyboardActions() async {
    let account = makeAccount()
    let first = makeThread(accountID: account.id)
    let second = MailThread(
        id: MailThreadID(accountID: account.id, providerThreadID: "thread-2"),
        accountID: account.id,
        providerThreadID: "thread-2",
        subject: "Customer follow-up",
        participantSummary: "Customer",
        snippet: "Need an answer today.",
        lastActivityAt: .now.addingTimeInterval(-60),
        hasUnread: true,
        isStarred: false,
        isInInbox: true,
        syncRevision: "rev-2"
    )
    let model = makeWindowModel(workspace: StubWorkspace(accounts: [account], threads: [first, second], detail: nil))

    await model.store.reloadSharedData(reason: .initial)
    await model.reloadThreads()
    model.selectAll()

    #expect(model.hoveredThreadID == first.id)
    #expect(model.multiSelectedIDs == [first.id, second.id])
}

@Test
@MainActor
func reloadPreservesMultiSelectionWhenNewThreadArrives() async {
    let account = makeAccount()
    let first = makeThread(accountID: account.id, providerThreadID: "thread-1", subject: "First")
    let second = makeThread(accountID: account.id, providerThreadID: "thread-2", subject: "Second")
    let incoming = makeThread(accountID: account.id, providerThreadID: "thread-3", subject: "Incoming")
    let workspace = StubWorkspace(accounts: [account], threads: [first, second], detail: nil)
    let model = makeWindowModel(workspace: workspace)

    await model.store.reloadSharedData(reason: .initial)
    await model.reloadThreads()
    model.toggleMultiSelect(threadID: first.id)
    model.toggleMultiSelect(threadID: second.id)
    model.hoveredThreadID = second.id

    await workspace.replaceThreads([incoming, first, second])
    await model.reloadThreads(reason: .workspaceChange)

    #expect(model.threads.map(\.id) == [incoming.id, first.id, second.id])
    #expect(model.multiSelectedIDs == [first.id, second.id])
    #expect(model.hoveredThreadID == second.id)
}

@Test
@MainActor
func reloadDropsOnlyMultiSelectedThreadsThatLeaveCurrentView() async {
    let account = makeAccount()
    let first = makeThread(accountID: account.id, providerThreadID: "thread-1", subject: "First")
    let second = makeThread(accountID: account.id, providerThreadID: "thread-2", subject: "Second")
    let workspace = StubWorkspace(accounts: [account], threads: [first, second], detail: nil)
    let model = makeWindowModel(workspace: workspace)

    await model.store.reloadSharedData(reason: .initial)
    await model.reloadThreads()
    model.toggleMultiSelect(threadID: first.id)
    model.toggleMultiSelect(threadID: second.id)
    model.hoveredThreadID = first.id

    await workspace.replaceThreads([second])
    await model.reloadThreads(reason: .workspaceChange)

    #expect(model.multiSelectedIDs == [second.id])
    #expect(model.hoveredThreadID == second.id)
}

@Test
@MainActor
func extendSelectionShrinksAndThenExpandsAcrossTheAnchorWhenDirectionReverses() async {
    let account = makeAccount()
    let first = makeThread(accountID: account.id, providerThreadID: "thread-1", subject: "First")
    let second = makeThread(accountID: account.id, providerThreadID: "thread-2", subject: "Second")
    let third = makeThread(accountID: account.id, providerThreadID: "thread-3", subject: "Third")
    let fourth = makeThread(accountID: account.id, providerThreadID: "thread-4", subject: "Fourth")
    let model = makeWindowModel(workspace: StubWorkspace(accounts: [account], threads: [first, second, third, fourth], detail: nil))

    await model.store.reloadSharedData(reason: .initial)
    await model.reloadThreads()
    model.hoveredThreadID = second.id

    model.extendSelection(by: 1)
    #expect(model.hoveredThreadID == third.id)
    #expect(model.multiSelectedIDs == [second.id, third.id])

    model.extendSelection(by: 1)
    #expect(model.hoveredThreadID == fourth.id)
    #expect(model.multiSelectedIDs == [second.id, third.id, fourth.id])

    model.extendSelection(by: -1)
    #expect(model.hoveredThreadID == third.id)
    #expect(model.multiSelectedIDs == [second.id, third.id])

    model.extendSelection(by: -1)
    #expect(model.hoveredThreadID == second.id)
    #expect(model.multiSelectedIDs == [second.id])

    model.extendSelection(by: -1)
    #expect(model.hoveredThreadID == first.id)
    #expect(model.multiSelectedIDs == [first.id, second.id])
}

@Test
@MainActor
func selectAllMailSwitchesOutOfInboxOnlyMode() {
    let account = makeAccount()
    let model = makeWindowModel(workspace: StubWorkspace(accounts: [account], threads: [], detail: nil))

    model.selectAllMail(accountID: account.id)

    #expect(model.selectedTab == .all)
    #expect(model.selectedAccountID == account.id)
    #expect(model.selectedMailboxID == nil)
    #expect(model.mailboxScope == .allMail)
    #expect(model.isAllMailSelected)
}

private func makeAccount() -> MailAccount {
    MailAccount(
        id: MailAccountID(rawValue: "gmail:alpha@example.com"),
        providerKind: .gmail,
        providerAccountID: "alpha@example.com",
        primaryEmail: "alpha@example.com",
        displayName: "Alpha",
        capabilities: .init(supportsArchive: true, supportsLabels: true, supportsCompose: true)
    )
}

private func makeThread(
    accountID: MailAccountID,
    providerThreadID: String = "thread-1",
    subject: String = "Release checklist",
    hasUnread: Bool = true,
    isStarred: Bool = false,
    isInInbox: Bool = true,
    mailboxRefs: [MailboxRef] = [],
    snoozedUntil: Date? = nil
) -> MailThread {
    MailThread(
        id: MailThreadID(accountID: accountID, providerThreadID: providerThreadID),
        accountID: accountID,
        providerThreadID: providerThreadID,
        subject: subject,
        participantSummary: "Sender",
        snippet: "Archive, star, and reply actions are wired up.",
        lastActivityAt: .now,
        hasUnread: hasUnread,
        isStarred: isStarred,
        isInInbox: isInInbox,
        mailboxRefs: mailboxRefs,
        snoozedUntil: snoozedUntil,
        syncRevision: "rev-1"
    )
}

private func makeThreadDetail(accountID: MailAccountID, thread: MailThread) -> MailThreadDetail {
    let message = MailMessage(
        id: MailMessageID(accountID: accountID, providerMessageID: "message-1"),
        threadID: thread.id,
        accountID: accountID,
        providerMessageID: "message-1",
        sender: MailParticipant(name: "Sender", emailAddress: "sender@example.com"),
        toRecipients: [MailParticipant(name: "Alpha", emailAddress: "alpha@example.com")],
        sentAt: .now,
        receivedAt: .now,
        snippet: thread.snippet,
        plainBody: "Body",
        bodyCacheState: .hot,
        headers: [MessageHeader(name: "Subject", value: thread.subject)],
        mailboxRefs: [],
        isRead: false,
        isOutgoing: false
    )

    return MailThreadDetail(thread: thread, messages: [message])
}
