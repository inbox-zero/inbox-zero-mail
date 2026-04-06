import Foundation
import MailCore
import MailData
import Testing
@testable import MailFeatures

@Test
@MainActor
func controlServiceListsActiveWindow() async {
    let account = makeAccount()
    let thread = makeThread(accountID: account.id)
    let workspace = ControlStubWorkspace(accounts: [account], threads: [thread], detail: nil)
    let store = MailAppStore(workspace: workspace)
    let model = WindowModel(store: store)

    store.register(model)
    store.setActiveWindow(windowID: model.windowID)
    await store.reloadSharedData(reason: MailReloadReason.initial)
    await model.reloadThreads()

    let control = MailAppControlService(store: store)
    let windows = control.listWindows()

    #expect(windows.count == 1)
    #expect(windows.first?.windowID == model.windowID)
    #expect(windows.first?.isActive == true)
    #expect(windows.first?.threadCount == 1)
}

@Test
@MainActor
func controlServiceSearchesWithinWindow() async throws {
    let account = makeAccount()
    let matchingThread = makeThread(accountID: account.id, subject: "Ops follow-up", snippet: "Need reply")
    let matchingQuery = ThreadListQuery(tab: .all, mailboxScope: .inboxOnly, searchText: "Ops", limit: 100)
    let workspace = ControlStubWorkspace(
        accounts: [account],
        threads: [matchingThread],
        detail: nil,
        threadQueryResults: [matchingQuery: [matchingThread]]
    )
    let store = MailAppStore(workspace: workspace)
    let model = WindowModel(store: store)

    store.register(model)
    await store.reloadSharedData(reason: MailReloadReason.initial)

    let control = MailAppControlService(store: store)
    let snapshot = try await control.search(windowID: model.windowID, query: "Ops")

    #expect(snapshot.searchText == "Ops")
    #expect(snapshot.threadCount == 1)
}

@Test
@MainActor
func controlServiceReadsCurrentThread() async throws {
    let account = makeAccount()
    let thread = makeThread(accountID: account.id)
    let detail = makeThreadDetail(accountID: account.id, thread: thread)
    let workspace = ControlStubWorkspace(accounts: [account], threads: [thread], detail: detail)
    let store = MailAppStore(workspace: workspace)
    let model = WindowModel(store: store)

    store.register(model)
    await store.reloadSharedData(reason: MailReloadReason.initial)
    await model.reloadThreads()
    model.open(threadID: thread.id)
    try await Task.sleep(for: .milliseconds(50))

    let control = MailAppControlService(store: store)
    let current = try await control.currentThread(windowID: model.windowID)

    #expect(current.threadID == thread.id.rawValue)
    #expect(current.subject == thread.subject)
    #expect(current.messageCount == detail.messages.count)
}

@Test
@MainActor
func controlServiceListsRichThreadMetadata() async throws {
    let account = makeAccount()
    let selectedThread = makeThread(
        accountID: account.id,
        providerThreadID: "selected-thread",
        subject: "Selected thread",
        isStarred: true,
        attachmentCount: 2
    )
    let otherThread = makeThread(
        accountID: account.id,
        providerThreadID: "other-thread",
        subject: "Other thread",
        hasUnread: false
    )
    let workspace = ControlStubWorkspace(accounts: [account], threads: [selectedThread, otherThread], detail: nil)
    let store = MailAppStore(workspace: workspace)
    let model = WindowModel(store: store)

    store.register(model)
    await store.reloadSharedData(reason: MailReloadReason.initial)
    await model.reloadThreads()
    model.selectedThreadID = selectedThread.id

    let control = MailAppControlService(store: store)
    let threads = try control.listThreads(windowID: model.windowID)

    #expect(threads.count == 2)
    #expect(threads[0].threadID == selectedThread.id.rawValue)
    #expect(threads[0].isSelected == true)
    #expect(threads[0].isStarred == true)
    #expect(threads[0].attachmentCount == 2)
    #expect(threads[1].hasUnread == false)
}

@Test
@MainActor
func controlServiceReadsAndOpensVisibleThreadByIndex() async throws {
    let account = makeAccount()
    let firstThread = makeThread(accountID: account.id, providerThreadID: "thread-1", subject: "First")
    let secondThread = makeThread(accountID: account.id, providerThreadID: "thread-2", subject: "Second")
    let firstDetail = makeThreadDetail(accountID: account.id, thread: firstThread, body: "First body")
    let secondDetail = makeThreadDetail(accountID: account.id, thread: secondThread, body: "Second body")
    let workspace = ControlStubWorkspace(
        accounts: [account],
        threads: [firstThread, secondThread],
        detailsByID: [
            firstThread.id: firstDetail,
            secondThread.id: secondDetail,
        ]
    )
    let store = MailAppStore(workspace: workspace)
    let model = WindowModel(store: store)

    store.register(model)
    await store.reloadSharedData(reason: MailReloadReason.initial)
    await model.reloadThreads()
    model.selectedThreadID = firstThread.id

    let control = MailAppControlService(store: store)
    let readThread = try await control.readVisibleThread(windowID: model.windowID, index: 2)

    #expect(readThread.threadID == secondThread.id.rawValue)
    #expect(model.selectedThreadID == firstThread.id)

    let openedThread = try await control.openVisibleThread(windowID: model.windowID, index: 2)

    #expect(openedThread.threadID == secondThread.id.rawValue)
    #expect(model.selectedThreadID == secondThread.id)
}

@Test
@MainActor
func controlServiceBuildsWindowSnapshotWithDraftAndSelectedThread() async throws {
    let account = makeAccount()
    let thread = makeThread(accountID: account.id)
    let detail = makeThreadDetail(accountID: account.id, thread: thread)
    let workspace = ControlStubWorkspace(accounts: [account], threads: [thread], detail: detail)
    let store = MailAppStore(workspace: workspace)
    let model = WindowModel(store: store)

    store.register(model)
    await store.reloadSharedData(reason: MailReloadReason.initial)
    await model.reloadThreads()

    let control = MailAppControlService(store: store)
    _ = try await control.openReplyDraft(windowID: model.windowID, replyMode: .reply, visibleIndex: 1)
    let snapshot = try await control.windowSnapshot(windowID: model.windowID)

    #expect(snapshot.window.windowID == model.windowID)
    #expect(snapshot.visibleThreads.count == 1)
    #expect(snapshot.visibleThreads.first?.isSelected == true)
    #expect(snapshot.selectedThread?.threadID == thread.id.rawValue)
    #expect(snapshot.draft?.replyMode == ReplyMode.reply.rawValue)
}

@Test
@MainActor
func controlServiceOpensReplyDraft() async throws {
    let account = makeAccount()
    let thread = makeThread(accountID: account.id)
    let detail = makeThreadDetail(accountID: account.id, thread: thread)
    let workspace = ControlStubWorkspace(accounts: [account], threads: [thread], detail: detail)
    let store = MailAppStore(workspace: workspace)
    let model = WindowModel(store: store)

    store.register(model)
    await store.reloadSharedData(reason: MailReloadReason.initial)
    await model.reloadThreads()
    model.open(threadID: thread.id)
    try await Task.sleep(for: .milliseconds(50))

    let control = MailAppControlService(store: store)
    let draft = try await control.openReplyDraft(windowID: model.windowID, replyMode: ReplyMode.reply)

    #expect(draft.replyMode == "reply")
    #expect(draft.subject == "Re: \(thread.subject)")
    #expect(draft.composeMode == "inline")
}

private actor ControlStubWorkspace: MailWorkspace {
    let accounts: [MailAccount]
    let threads: [MailThread]
    let detailsByID: [MailThreadID: MailThreadDetail]
    let threadQueryResults: [ThreadListQuery: [MailThread]]

    init(
        accounts: [MailAccount],
        threads: [MailThread],
        detail: MailThreadDetail? = nil,
        detailsByID: [MailThreadID: MailThreadDetail] = [:],
        threadQueryResults: [ThreadListQuery: [MailThread]] = [:]
    ) {
        self.accounts = accounts
        self.threads = threads
        if detailsByID.isEmpty, let detail {
            self.detailsByID = [detail.thread.id: detail]
        } else {
            self.detailsByID = detailsByID
        }
        self.threadQueryResults = threadQueryResults
    }

    func changes() async -> AsyncStream<Int> { AsyncStream { $0.finish() } }
    func start() async {}
    func setForegroundActive(_ isActive: Bool) async {}
    func connectAccount(kind: ProviderKind) async throws {}
    func reconnectAccount(accountID: MailAccountID) async throws {}
    func listAccounts() async throws -> [MailAccount] { accounts }
    func listThreads(query: ThreadListQuery) async throws -> [MailThread] {
        threadQueryResults[query] ?? threads
    }
    func countThreads(query: ThreadListQuery) async throws -> Int {
        threadQueryResults[query]?.count ?? threads.count
    }
    func loadThread(id: MailThreadID) async throws -> MailThreadDetail? {
        detailsByID[id]
    }
    func listMailboxes(accountID: MailAccountID?) async throws -> [MailboxRef] { [] }
    func refreshAll() async {}
    func perform(_ mutation: MailMutation) async throws {}
    func send(_ draft: OutgoingDraft) async throws {}
    func seedDemoDataIfNeeded() async throws {}
    func removeAccount(accountID: MailAccountID) async throws {}
    func saveDraft(_ draft: OutgoingDraft) async throws {}
    func listDrafts() async throws -> [OutgoingDraft] { [] }
    func deleteDraft(id: UUID) async throws {}
    func handleRedirectURL(_ url: URL) async -> Bool { false }
    func updateMailboxVisibility(mailboxID: MailboxID, hidden: Bool) async throws {}
    func fetchAttachment(_ attachment: MailAttachment) async throws -> Data { Data() }
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
    snippet: String = "Archive, star, and reply actions are wired up.",
    hasUnread: Bool = true,
    isStarred: Bool = false,
    attachmentCount: Int = 0
) -> MailThread {
    MailThread(
        id: MailThreadID(accountID: accountID, providerThreadID: providerThreadID),
        accountID: accountID,
        providerThreadID: providerThreadID,
        subject: subject,
        participantSummary: "Sender",
        snippet: snippet,
        lastActivityAt: .now,
        hasUnread: hasUnread,
        isStarred: isStarred,
        isInInbox: true,
        attachmentCount: attachmentCount,
        syncRevision: "rev-1"
    )
}

private func makeThreadDetail(
    accountID: MailAccountID,
    thread: MailThread,
    body: String = "Body"
) -> MailThreadDetail {
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
        plainBody: body,
        bodyCacheState: .hot,
        headers: [MessageHeader(name: "Subject", value: thread.subject)],
        mailboxRefs: [],
        isRead: false,
        isOutgoing: false
    )
    return MailThreadDetail(thread: thread, messages: [message])
}
