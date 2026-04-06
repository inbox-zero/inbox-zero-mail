import Foundation
import GRDB
import MailCore
import Testing
@testable import MailData
import ProviderCore

@Test
func demoSeederCreatesTwoAccounts() async throws {
    let (store, _) = try makeStore()

    try await store.seedDemoDataIfNeeded()
    let accounts = try await store.listAccounts()

    #expect(accounts.count == 2)
}

@Test
func demoSeederStillAddsThreadsWhenARealAccountAlreadyExists() async throws {
    let (store, _) = try makeStore()

    let realAccount = MailAccount(
        id: MailAccountID(rawValue: "gmail:real@example.com"),
        providerKind: .gmail,
        providerAccountID: "real@example.com",
        primaryEmail: "real@example.com",
        displayName: "Real",
        capabilities: .init(supportsArchive: true, supportsLabels: true, supportsCompose: true)
    )
    try await store.saveAccount(realAccount)

    try await store.seedDemoDataIfNeeded()

    let accounts = try await store.listAccounts()
    let threads = try await store.listThreads(query: ThreadListQuery(tab: .all))
    #expect(accounts.count == 3)
    #expect(threads.count == 2)
}

@Test
@MainActor
func failedInitialConnectRollsBackSavedAccount() async throws {
    let (store, _) = try makeStore()
    let credentials = TestCredentialsStore()
    let provider = FailingInitialSyncProvider()
    let workspace = MailWorkspaceController(
        store: store,
        credentialsStore: credentials,
        providers: [.gmail: provider]
    )

    try await workspace.connectAccount(kind: .gmail)

    let accounts = try await store.listAccounts()
    let account = try #require(accounts.first)
    #expect(account.primaryEmail == "real@example.com")
    #expect(account.syncState.phase == .error)
    #expect(account.syncState.lastErrorDescription?.contains("Sync failed") == true)
    #expect(credentials.savedAccountIDs == [account.id])
}

@Test
@MainActor
func reconnectAccountReauthorizesExistingAccount() async throws {
    let (store, _) = try makeStore()
    let account = makeAccount(syncState: .init(
        phase: .reauthRequired,
        lastSuccessfulSyncAt: .now.addingTimeInterval(-3600),
        lastErrorDescription: "Account authorization expired. Reconnect the account to resume sync."
    ))
    try await seedWorkspaceStore(store: store, account: account)

    let session = makeSession(
        for: account,
        accessToken: "fresh-token",
        displayName: "Alpha Reconnected"
    )
    let provider = TestMailProvider(
        authorizeSession: session,
        syncPages: [.initial: makeSyncPage(account: account, session: session, threads: [])]
    )
    let credentials = TestCredentialsStore()
    let workspace = MailWorkspaceController(
        store: store,
        credentialsStore: credentials,
        providers: [.gmail: provider]
    )

    try await workspace.reconnectAccount(accountID: account.id)

    let refreshedAccount = try #require(try await store.listAccounts().first(where: { $0.id == account.id }))
    #expect(refreshedAccount.primaryEmail == account.primaryEmail)
    #expect(refreshedAccount.displayName == "Alpha Reconnected")
    #expect(refreshedAccount.syncState.phase == .idle)
    #expect(refreshedAccount.syncState.lastErrorDescription == nil)
    #expect(credentials.savedAccountIDs == [account.id])
}

@Test
func unifiedInboxSortsAcrossAccountsByLatestActivity() async throws {
    let (store, _) = try makeStore()

    try await store.seedDemoDataIfNeeded()
    let threads = try await store.listThreads(query: ThreadListQuery(tab: .all))

    #expect(threads.map(\.accountID.rawValue) == [
        "gmail:alpha@example.com",
        "gmail:beta@example.com",
    ])
}

@Test
func optimisticArchiveRemovesThreadFromUnifiedInbox() async throws {
    let (store, _) = try makeStore()

    try await store.seedDemoDataIfNeeded()
    let thread = try #require(try await store.listThreads(query: ThreadListQuery(tab: .all)).first)

    try await store.applyOptimistic(.archive(threadID: thread.id))

    let refreshed = try await store.listThreads(query: ThreadListQuery(tab: .all))
    #expect(refreshed.contains(where: { $0.id == thread.id }) == false)
}

@Test
func allMailStillIncludesArchivedThreads() async throws {
    let (store, _) = try makeStore()

    try await store.seedDemoDataIfNeeded()
    let thread = try #require(try await store.listThreads(query: ThreadListQuery(tab: .all)).first)

    try await store.applyOptimistic(.archive(threadID: thread.id))

    let allMail = try await store.listThreads(query: ThreadListQuery(tab: .all, mailboxScope: .allMail))
    #expect(allMail.contains(where: { $0.id == thread.id }))
}

@Test
func queuedMutationsPersistUntilCompleted() async throws {
    let (store, path) = try makeStore()

    try await store.seedDemoDataIfNeeded()
    let thread = try #require(try await store.listThreads(query: ThreadListQuery(tab: .all)).first)
    let queueID = try await store.enqueue(.star(threadID: thread.id))

    let dbQueue = try DatabaseQueue(path: path)
    let pendingCount = try await dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM queuedMutations WHERE id = ?", arguments: [queueID.uuidString]) ?? 0
    }
    #expect(pendingCount == 1)

    try await store.completeQueuedMutation(id: queueID)

    let remainingCount = try await dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM queuedMutations WHERE id = ?", arguments: [queueID.uuidString]) ?? 0
    }
    #expect(remainingCount == 0)
}

@Test
func coldBodyEvictionKeepsOnlyHotThreadBodies() async throws {
    let (store, path) = try makeStore()

    try await store.seedDemoDataIfNeeded()
    let threads = try await store.listThreads(query: ThreadListQuery(tab: .all))
    let hotThread = try #require(threads.first)
    let coldThread = try #require(threads.last)

    _ = try await store.loadThread(id: hotThread.id)
    try await store.evictColdBodies(maxHotThreads: 1, maxAge: 0)

    let dbQueue = try DatabaseQueue(path: path)
    let bodies = try await dbQueue.read { db in
        let hotBody = try String.fetchOne(db, sql: "SELECT plainBody FROM messages WHERE threadID = ?", arguments: [hotThread.id.rawValue])
        let coldBody = try String.fetchOne(db, sql: "SELECT plainBody FROM messages WHERE threadID = ?", arguments: [coldThread.id.rawValue])
        let coldState = try String.fetchOne(db, sql: "SELECT bodyCacheState FROM messages WHERE threadID = ?", arguments: [coldThread.id.rawValue])
        return (hotBody, coldBody, coldState)
    }

    #expect(bodies.0 != nil)
    #expect(bodies.1 == nil)
    #expect(bodies.2 == MailBodyCacheState.cold.rawValue)
}

@Test
func migratingLegacyTablesAddMissingColumns() async throws {
    let path = NSTemporaryDirectory().appending("mail-data-legacy-\(UUID().uuidString).sqlite")
    let legacyQueue = try DatabaseQueue(path: path)

    try await legacyQueue.write { db in
        try db.create(table: "grdb_migrations") { table in
            table.column("identifier", .text).notNull().primaryKey()
        }
        try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('mail-schema-v1')")

        try db.create(table: "accounts") { table in
            table.column("id", .text).primaryKey()
            table.column("providerKind", .text).notNull()
            table.column("providerAccountID", .text).notNull()
            table.column("primaryEmail", .text).notNull()
            table.column("displayName", .text).notNull()
            table.column("syncPhase", .text).notNull()
            table.column("lastSuccessfulSyncAt", .double)
            table.column("lastErrorDescription", .text)
            table.column("capabilitiesJSON", .text).notNull()
        }

        try db.create(table: "mailboxes") { table in
            table.column("id", .text).primaryKey()
            table.column("accountID", .text).notNull()
            table.column("providerMailboxID", .text).notNull()
            table.column("displayName", .text).notNull()
            table.column("kind", .text).notNull()
            table.column("systemRole", .text)
            table.column("colorHex", .text)
        }

        try db.create(table: "threads") { table in
            table.column("id", .text).primaryKey()
            table.column("accountID", .text).notNull()
            table.column("providerThreadID", .text).notNull()
            table.column("subject", .text).notNull()
            table.column("participantSummary", .text).notNull()
            table.column("snippet", .text).notNull()
            table.column("lastActivityAt", .double).notNull()
            table.column("hasUnread", .boolean).notNull()
            table.column("isStarred", .boolean).notNull()
            table.column("isInInbox", .boolean).notNull()
            table.column("latestMessageID", .text)
            table.column("syncRevision", .text).notNull()
            table.column("mailboxRefsJSON", .text).notNull()
        }

        try db.create(table: "messages") { table in
            table.column("id", .text).primaryKey()
            table.column("threadID", .text).notNull()
            table.column("accountID", .text).notNull()
            table.column("providerMessageID", .text).notNull()
            table.column("senderJSON", .text).notNull()
            table.column("toJSON", .text).notNull()
            table.column("ccJSON", .text).notNull()
            table.column("bccJSON", .text).notNull()
            table.column("sentAt", .double)
            table.column("receivedAt", .double)
            table.column("snippet", .text).notNull()
            table.column("plainBody", .text)
            table.column("htmlBody", .text)
            table.column("bodyCacheState", .text).notNull()
            table.column("headersJSON", .text).notNull()
            table.column("mailboxRefsJSON", .text).notNull()
            table.column("isRead", .boolean).notNull()
            table.column("isOutgoing", .boolean).notNull()
            table.column("touchedAt", .double)
        }

        try db.create(table: "syncCheckpoints") { table in
            table.column("accountID", .text).primaryKey()
            table.column("payload", .text).notNull()
            table.column("lastSuccessfulSyncAt", .double)
            table.column("lastBackfillAt", .double)
        }

        try db.create(table: "queuedMutations") { table in
            table.column("id", .text).primaryKey()
            table.column("accountID", .text).notNull()
            table.column("mutationJSON", .text).notNull()
            table.column("createdAt", .double).notNull()
            table.column("lastErrorDescription", .text)
        }

        try db.create(table: "localDrafts") { table in
            table.column("id", .text).primaryKey()
            table.column("draftJSON", .text).notNull()
            table.column("updatedAt", .double).notNull()
        }
    }

    _ = try SQLiteMailStore(path: path)

    let migratedQueue = try DatabaseQueue(path: path)
    let threadColumns = try await migratedQueue.read { db in
        try db.columns(in: "threads").map(\.name)
    }
    let messageColumns = try await migratedQueue.read { db in
        try db.columns(in: "messages").map(\.name)
    }
    let localDraftsExists = try await migratedQueue.read { db in
        try String.fetchOne(
            db,
            sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'localDrafts'"
        ) != nil
    }
    let queuedMutationColumns = try await migratedQueue.read { db in
        try db.columns(in: "queuedMutations").map(\.name)
    }

    #expect(threadColumns.contains("snoozedUntil"))
    #expect(threadColumns.contains("attachmentCount"))
    #expect(messageColumns.contains("attachmentsJSON"))
    #expect(localDraftsExists)
    #expect(queuedMutationColumns.contains("retryCount"))
    #expect(queuedMutationColumns.contains("nextAttemptAt"))
    #expect(queuedMutationColumns.contains("lastAttemptAt"))
    #expect(queuedMutationColumns.contains("status"))
}

@Test
func localSearchUsesParticipantSummaryColumn() async throws {
    let (store, _) = try makeStore()

    try await store.seedDemoDataIfNeeded()
    let threads = try await store.listThreads(query: ThreadListQuery(tab: .all, searchText: "Ops"))

    #expect(threads.isEmpty == false)
}

@Test
func scopedSearchKeepsMailboxAndSnoozeFilters() async throws {
    let (store, _) = try makeStore()
    let account = makeAccount()
    let inbox = MailboxRef(
        id: MailboxID(accountID: account.id, providerMailboxID: "INBOX"),
        accountID: account.id,
        providerMailboxID: "INBOX",
        displayName: "Inbox",
        kind: .system,
        systemRole: .inbox
    )
    let ops = MailboxRef(
        id: MailboxID(accountID: account.id, providerMailboxID: "Label_ops"),
        accountID: account.id,
        providerMailboxID: "Label_ops",
        displayName: "Ops",
        kind: .label
    )
    try await store.saveAccount(account)
    try await store.saveMailboxes([inbox, ops])

    try await store.upsertThreadDetails(
        [
            makeThreadDetail(
                account: account,
                providerThreadID: "ops-visible",
                subject: "Release note",
                mailboxRefs: [inbox, ops]
            ),
            makeThreadDetail(
                account: account,
                providerThreadID: "ops-snoozed",
                subject: "Release note",
                mailboxRefs: [inbox, ops],
                snoozedUntil: Date().addingTimeInterval(3600)
            ),
            makeThreadDetail(
                account: account,
                providerThreadID: "inbox-only",
                subject: "Release note",
                mailboxRefs: [inbox]
            ),
        ],
        checkpoint: nil
    )

    let threads = try await store.listThreads(
        query: ThreadListQuery(
            tab: .all,
            accountFilter: account.id,
            mailboxScope: .specific(ops.id),
            searchText: "Release"
        )
    )

    #expect(threads.map(\.providerThreadID) == ["ops-visible"])
}

@Test
func splitInboxQueryFiltersByLabel() async throws {
    let (store, _) = try makeStore()
    let account = makeAccount()
    let inbox = MailboxRef(
        id: MailboxID(accountID: account.id, providerMailboxID: "INBOX"),
        accountID: account.id,
        providerMailboxID: "INBOX",
        displayName: "Inbox",
        kind: .system,
        systemRole: .inbox
    )
    let receipts = MailboxRef(
        id: MailboxID(accountID: account.id, providerMailboxID: "Label_receipts"),
        accountID: account.id,
        providerMailboxID: "Label_receipts",
        displayName: "Receipts",
        kind: .label
    )
    try await store.saveAccount(account)
    try await store.saveMailboxes([inbox, receipts])

    try await store.upsertThreadDetails(
        [
            makeThreadDetail(
                account: account,
                providerThreadID: "receipt-thread",
                subject: "Stripe receipt",
                mailboxRefs: [inbox, receipts]
            ),
            makeThreadDetail(
                account: account,
                providerThreadID: "other-thread",
                subject: "Product update",
                mailboxRefs: [inbox]
            ),
        ],
        checkpoint: nil
    )

    let threads = try await store.listThreads(
        query: ThreadListQuery(
            tab: .all,
            accountFilter: account.id,
            splitInboxQueryText: "label:receipts"
        )
    )

    #expect(threads.map(\.providerThreadID) == ["receipt-thread"])
}

@Test
func splitInboxQueryFiltersByGmailCategory() async throws {
    let (store, _) = try makeStore()
    let account = makeAccount()
    let inbox = MailboxRef(
        id: MailboxID(accountID: account.id, providerMailboxID: "INBOX"),
        accountID: account.id,
        providerMailboxID: "INBOX",
        displayName: "Inbox",
        kind: .system,
        systemRole: .inbox
    )
    let promotions = MailboxRef(
        id: MailboxID(accountID: account.id, providerMailboxID: "CATEGORY_PROMOTIONS"),
        accountID: account.id,
        providerMailboxID: "CATEGORY_PROMOTIONS",
        displayName: "CATEGORY_PROMOTIONS",
        kind: .system
    )
    try await store.saveAccount(account)
    try await store.saveMailboxes([inbox, promotions])

    try await store.upsertThreadDetails(
        [
            makeThreadDetail(
                account: account,
                providerThreadID: "promo-thread",
                subject: "Limited time offer",
                mailboxRefs: [inbox, promotions]
            ),
            makeThreadDetail(
                account: account,
                providerThreadID: "other-thread",
                subject: "Engineering notes",
                mailboxRefs: [inbox]
            ),
        ],
        checkpoint: nil
    )

    let threads = try await store.listThreads(
        query: ThreadListQuery(
            tab: .all,
            accountFilter: account.id,
            splitInboxQueryText: "category:promotions"
        )
    )

    #expect(threads.map(\.providerThreadID) == ["promo-thread"])
}

@Test
func performWithoutCredentialsPreservesAccountStateAndMarksError() async throws {
    let (store, path) = try makeStore()
    let account = makeAccount()
    try await seedWorkspaceStore(store: store, account: account)

    let provider = TestMailProvider()
    let controller = MailWorkspaceController(
        store: store,
        credentialsStore: TestCredentialsStore(),
        providers: [.gmail: provider]
    )
    let thread = try #require(try await store.listThreads(query: ThreadListQuery(tab: .all)).first)

    do {
        try await controller.perform(.archive(threadID: thread.id))
        Issue.record("Expected unauthorized mutation to fail.")
    } catch {}

    let refreshedAccount = try #require(try await store.listAccounts().first(where: { $0.id == account.id }))
    let remainingThreads = try await store.listThreads(query: ThreadListQuery(tab: .all))
    #expect(refreshedAccount.syncState.phase == .reauthRequired)
    #expect(refreshedAccount.syncState.lastErrorDescription == "Account credentials are missing. Reconnect the account to resume sync.")
    #expect(remainingThreads.count == 1)

    let dbQueue = try DatabaseQueue(path: path)
    let pendingCount = try await dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM queuedMutations") ?? 0
    }
    #expect(pendingCount == 0)
}

@Test
func unauthorizedProviderMutationPreservesAccountStateAndClearsCredentials() async throws {
    let (store, path) = try makeStore()
    let account = makeAccount()
    try await seedWorkspaceStore(store: store, account: account)

    let provider = TestMailProvider(applyError: MailProviderError.unauthorized)
    let credentials = TestCredentialsStore()
    try credentials.save(session: makeSession(for: account), for: account.id)
    let controller = MailWorkspaceController(
        store: store,
        credentialsStore: credentials,
        providers: [.gmail: provider]
    )
    let thread = try #require(try await store.listThreads(query: ThreadListQuery(tab: .all)).first)

    do {
        try await controller.perform(.archive(threadID: thread.id))
        Issue.record("Expected unauthorized provider mutation to fail.")
    } catch {}

    let refreshedAccount = try #require(try await store.listAccounts().first(where: { $0.id == account.id }))
    let remainingThreads = try await store.listThreads(query: ThreadListQuery(tab: .all))
    #expect(refreshedAccount.syncState.phase == .reauthRequired)
    #expect(refreshedAccount.syncState.lastErrorDescription == "Account authorization expired. Reconnect the account to resume sync.")
    #expect(remainingThreads.map(\.id) == [thread.id])
    #expect(credentials.savedAccountIDs.isEmpty)

    let dbQueue = try DatabaseQueue(path: path)
    let pendingCount = try await dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM queuedMutations") ?? 0
    }
    #expect(pendingCount == 0)
}

@Test
func failedProviderMutationRollsBackOptimisticChange() async throws {
    let (store, path) = try makeStore()
    let account = makeAccount()
    try await seedWorkspaceStore(store: store, account: account)

    let provider = TestMailProvider(applyError: MailProviderError.transport("provider down"))
    let credentials = TestCredentialsStore()
    try credentials.save(session: makeSession(for: account), for: account.id)
    let controller = MailWorkspaceController(
        store: store,
        credentialsStore: credentials,
        providers: [.gmail: provider]
    )
    let thread = try #require(try await store.listThreads(query: ThreadListQuery(tab: .all)).first)

    do {
        try await controller.perform(.archive(threadID: thread.id))
        Issue.record("Expected provider mutation to fail.")
    } catch {}

    let remainingThreads = try await store.listThreads(query: ThreadListQuery(tab: .all))
    #expect(remainingThreads.map(\.id) == [thread.id])

    let dbQueue = try DatabaseQueue(path: path)
    let queueRows: [Row] = try dbQueue.read { db in
        try Row.fetchAll(db, sql: "SELECT accountID, lastErrorDescription FROM queuedMutations")
    }
    #expect(queueRows.count == 1)
    #expect(queueRows.first?["accountID"] as String? == account.id.rawValue)
    #expect((queueRows.first?["lastErrorDescription"] as String?)?.contains("provider down") == true)
}

@Test
func rateLimitedProviderMutationStaysOptimisticAndQueuesRetry() async throws {
    let (store, path) = try makeStore()
    let account = makeAccount()
    try await seedWorkspaceStore(store: store, account: account)

    let provider = TestMailProvider(applyError: MailProviderError.rateLimited(message: "slow down", retryAfter: nil))
    let credentials = TestCredentialsStore()
    try credentials.save(session: makeSession(for: account), for: account.id)
    let controller = MailWorkspaceController(
        store: store,
        credentialsStore: credentials,
        providers: [.gmail: provider]
    )
    let thread = try #require(try await store.listThreads(query: ThreadListQuery(tab: .all)).first)

    try await controller.perform(.archive(threadID: thread.id))

    let inboxThreads = try await store.listThreads(query: ThreadListQuery(tab: .all))
    let allMailThreads = try await store.listThreads(query: ThreadListQuery(tab: .all, mailboxScope: .allMail))
    #expect(inboxThreads.isEmpty)
    #expect(allMailThreads.map(\.id) == [thread.id])
    #expect(allMailThreads.first?.isInInbox == false)

    let dbQueue = try DatabaseQueue(path: path)
    let queueRow = try await dbQueue.read { db in
        return try Row.fetchOne(db, sql: "SELECT retryCount, status, lastErrorDescription FROM queuedMutations")
    }
    #expect(queueRow?["retryCount"] as Int? == 1)
    #expect(queueRow?["status"] as String? == QueuedMailMutation.Status.pending.rawValue)
    #expect((queueRow?["lastErrorDescription"] as String?)?.contains("rateLimited") == true)
}

@Test
func successfulMutationIsNotRolledBackWhenFollowUpSyncIsRateLimited() async throws {
    let (store, path) = try makeStore()
    let account = makeAccount()
    try await seedWorkspaceStore(store: store, account: account)

    let provider = TestMailProvider(syncError: MailProviderError.rateLimited(message: "slow down", retryAfter: nil))
    let credentials = TestCredentialsStore()
    try credentials.save(session: makeSession(for: account), for: account.id)
    let controller = MailWorkspaceController(
        store: store,
        credentialsStore: credentials,
        providers: [.gmail: provider]
    )
    let thread = try #require(try await store.listThreads(query: ThreadListQuery(tab: .all)).first)

    try await controller.perform(.archive(threadID: thread.id))
    await controller.refreshAll()

    let inboxThreads = try await store.listThreads(query: ThreadListQuery(tab: .all))
    let allMailThreads = try await store.listThreads(query: ThreadListQuery(tab: .all, mailboxScope: .allMail))
    let refreshedAccount = try #require(try await store.listAccounts().first(where: { $0.id == account.id }))
    #expect(inboxThreads.isEmpty)
    #expect(allMailThreads.first?.isInInbox == false)
    #expect(refreshedAccount.syncState.phase == .idle)

    let dbQueue = try DatabaseQueue(path: path)
    let pendingCount = try await dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM queuedMutations") ?? 0
    }
    #expect(pendingCount == 0)
}

@Test
func queuedRateLimitedMutationRetriesOnNextRefresh() async throws {
    let (store, path) = try makeStore()
    let account = makeAccount()
    try await seedWorkspaceStore(store: store, account: account)

    let provider = TestMailProvider(
        applyResults: [
            MailProviderError.rateLimited(message: "slow down", retryAfter: nil),
            nil,
        ]
    )
    let credentials = TestCredentialsStore()
    try credentials.save(session: makeSession(for: account), for: account.id)
    let controller = MailWorkspaceController(
        store: store,
        credentialsStore: credentials,
        providers: [.gmail: provider]
    )
    let thread = try #require(try await store.listThreads(query: ThreadListQuery(tab: .all)).first)

    try await controller.perform(.archive(threadID: thread.id))

    let queued = try #require(try await store.loadReadyQueuedMutations(asOf: .distantFuture, limit: 1).first)
    try await store.markQueuedMutationForRetry(
        id: queued.id,
        errorDescription: queued.lastErrorDescription ?? "rate limited",
        retryCount: queued.retryCount,
        nextAttemptAt: Date()
    )

    await controller.refreshAll()

    let dbQueue = try DatabaseQueue(path: path)
    let remainingCount = try await dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM queuedMutations WHERE status = ?", arguments: [QueuedMailMutation.Status.pending.rawValue]) ?? 0
    }
    let appliedMutations = await provider.recordedAppliedMutations()
    let allMailThreads = try await store.listThreads(query: ThreadListQuery(tab: .all, mailboxScope: .allMail))

    #expect(remainingCount == 0)
    #expect(appliedMutations == [.archive(threadID: thread.id), .archive(threadID: thread.id)])
    #expect(allMailThreads.first?.isInInbox == false)
}

@Test
func refreshAllConsumesBackfillPagesAndCompletesCheckpoint() async throws {
    let (store, _) = try makeStore()
    let account = makeAccount()
    try await store.saveAccount(account)

    let inbox = MailboxRef(
        id: MailboxID(accountID: account.id, providerMailboxID: "INBOX"),
        accountID: account.id,
        providerMailboxID: "INBOX",
        displayName: "Inbox",
        kind: .system,
        systemRole: .inbox
    )
    let provider = TestMailProvider(
        mailboxes: [inbox],
        syncPages: [
            .initial: MailSyncPage(
                profile: .init(
                    providerAccountID: account.providerAccountID,
                    emailAddress: account.primaryEmail,
                    displayName: account.displayName
                ),
                mailboxes: [inbox],
                threadDetails: [makeThreadDetail(account: account, providerThreadID: "page-1", subject: "Newest mail", mailboxRefs: [inbox])],
                checkpointPayload: "1001",
                nextPageToken: "page-2-token",
                isBackfillComplete: false
            ),
            .backfill("page-2-token"): MailSyncPage(
                profile: .init(
                    providerAccountID: account.providerAccountID,
                    emailAddress: account.primaryEmail,
                    displayName: account.displayName
                ),
                mailboxes: [inbox],
                threadDetails: [makeThreadDetail(account: account, providerThreadID: "page-2", subject: "Older mail", mailboxRefs: [inbox])],
                checkpointPayload: "1002",
                nextPageToken: nil,
                isBackfillComplete: true
            ),
        ]
    )
    let credentials = TestCredentialsStore()
    try credentials.save(session: makeSession(for: account), for: account.id)
    let controller = MailWorkspaceController(
        store: store,
        credentialsStore: credentials,
        providers: [.gmail: provider]
    )

    await controller.refreshAll()

    let threads = try await store.listThreads(query: ThreadListQuery(tab: .all))
    #expect(Set(threads.map(\.providerThreadID)) == ["page-1", "page-2"])

    let checkpoint = try #require(try await store.loadCheckpoint(accountID: account.id))
    #expect(checkpoint.payload == "1002")
    #expect(checkpoint.lastBackfillAt != nil)

    let recordedRequests = await provider.recordedRequests()
    #expect(recordedRequests == [.initial, .backfill("page-2-token")])
}

@Test
func refreshAllPreservesAccountsWhoseProviderSessionIsUnauthorized() async throws {
    let (store, _) = try makeStore()
    let account = makeAccount()
    try await seedWorkspaceStore(store: store, account: account)

    let provider = TestMailProvider(syncError: MailProviderError.unauthorized)
    let credentials = TestCredentialsStore()
    try credentials.save(session: makeSession(for: account), for: account.id)
    let controller = MailWorkspaceController(
        store: store,
        credentialsStore: credentials,
        providers: [.gmail: provider]
    )

    await controller.refreshAll()

    let refreshedAccount = try #require(try await store.listAccounts().first(where: { $0.id == account.id }))
    let remainingThreads = try await store.listThreads(query: ThreadListQuery(tab: .all))
    #expect(refreshedAccount.syncState.phase == .reauthRequired)
    #expect(refreshedAccount.syncState.lastErrorDescription == "Account authorization expired. Reconnect the account to resume sync.")
    #expect(remainingThreads.count == 1)
    #expect(credentials.savedAccountIDs.isEmpty)
}

@Test
func refreshAllConsumesAllDeltaPages() async throws {
    let (store, _) = try makeStore()
    let account = makeAccount()
    let syncedAt = Date().addingTimeInterval(-3600)
    try await store.saveAccount(account)
    try await store.upsertThreadDetails(
        [makeThreadDetail(account: account, providerThreadID: "existing", subject: "Existing mail", mailboxRefs: [])],
        checkpoint: SyncCheckpoint(
            accountID: account.id,
            payload: "2001",
            lastSuccessfulSyncAt: syncedAt,
            lastBackfillAt: syncedAt
        )
    )

    let inbox = MailboxRef(
        id: MailboxID(accountID: account.id, providerMailboxID: "INBOX"),
        accountID: account.id,
        providerMailboxID: "INBOX",
        displayName: "Inbox",
        kind: .system,
        systemRole: .inbox
    )
    let provider = TestMailProvider(
        mailboxes: [inbox],
        syncPages: [
            .delta("2001", nil): MailSyncPage(
                profile: .init(
                    providerAccountID: account.providerAccountID,
                    emailAddress: account.primaryEmail,
                    displayName: account.displayName
                ),
                mailboxes: [inbox],
                threadDetails: [makeThreadDetail(account: account, providerThreadID: "delta-1", subject: "Delta one", mailboxRefs: [inbox])],
                checkpointPayload: "2002",
                nextPageToken: "delta-page-2",
                isBackfillComplete: true
            ),
            .delta("2001", "delta-page-2"): MailSyncPage(
                profile: .init(
                    providerAccountID: account.providerAccountID,
                    emailAddress: account.primaryEmail,
                    displayName: account.displayName
                ),
                mailboxes: [inbox],
                threadDetails: [makeThreadDetail(account: account, providerThreadID: "delta-2", subject: "Delta two", mailboxRefs: [inbox])],
                checkpointPayload: "2003",
                nextPageToken: nil,
                isBackfillComplete: true
            ),
        ]
    )
    let credentials = TestCredentialsStore()
    try credentials.save(session: makeSession(for: account), for: account.id)
    let controller = MailWorkspaceController(
        store: store,
        credentialsStore: credentials,
        providers: [.gmail: provider]
    )

    await controller.refreshAll()

    let threads = try await store.listThreads(query: ThreadListQuery(tab: .all))
    #expect(Set(threads.map(\.providerThreadID)).isSuperset(of: ["delta-1", "delta-2"]))

    let checkpoint = try #require(try await store.loadCheckpoint(accountID: account.id))
    #expect(checkpoint.payload == "2003")

    let recordedRequests = await provider.recordedRequests()
    #expect(recordedRequests == [.delta("2001", nil), .delta("2001", "delta-page-2")])
}

@Test
func refreshAllFallsBackToBackfillWhenStoredGmailCheckpointIsMalformed() async throws {
    let (store, _) = try makeStore()
    let syncedAt = Date().addingTimeInterval(-3600)
    let account = MailAccount(
        id: MailAccountID(rawValue: "gmail:broken@example.com"),
        providerKind: .gmail,
        providerAccountID: "broken@example.com",
        primaryEmail: "broken@example.com",
        displayName: "Broken",
        syncState: .init(
            phase: .error,
            lastSuccessfulSyncAt: syncedAt,
            lastErrorDescription: "Invalid value at 'start_history_id'"
        ),
        capabilities: .init(supportsArchive: true, supportsLabels: true, supportsCompose: true)
    )
    try await store.saveAccount(account)
    try await store.upsertThreadDetails(
        [],
        checkpoint: SyncCheckpoint(
            accountID: account.id,
            payload: "broken@example.com",
            lastSuccessfulSyncAt: syncedAt,
            lastBackfillAt: syncedAt
        )
    )

    let inbox = MailboxRef(
        id: MailboxID(accountID: account.id, providerMailboxID: "INBOX"),
        accountID: account.id,
        providerMailboxID: "INBOX",
        displayName: "Inbox",
        kind: .system,
        systemRole: .inbox
    )
    let provider = TestMailProvider(
        mailboxes: [inbox],
        syncPages: [
            .initial: MailSyncPage(
                profile: .init(
                    providerAccountID: account.providerAccountID,
                    emailAddress: account.primaryEmail,
                    displayName: account.displayName
                ),
                mailboxes: [inbox],
                threadDetails: [makeThreadDetail(account: account, providerThreadID: "recovered", subject: "Recovered mail", mailboxRefs: [inbox])],
                checkpointPayload: "123456789",
                nextPageToken: nil,
                isBackfillComplete: true
            ),
        ]
    )
    let credentials = TestCredentialsStore()
    try credentials.save(session: makeSession(for: account), for: account.id)
    let controller = MailWorkspaceController(
        store: store,
        credentialsStore: credentials,
        providers: [.gmail: provider]
    )

    await controller.refreshAll()

    let refreshedAccount = try #require(try await store.listAccounts().first(where: { $0.id == account.id }))
    #expect(refreshedAccount.syncState.phase == .idle)
    #expect(refreshedAccount.syncState.lastErrorDescription == nil)

    let checkpoint = try #require(try await store.loadCheckpoint(accountID: account.id))
    #expect(checkpoint.payload == "123456789")

    let recordedRequests = await provider.recordedRequests()
    #expect(recordedRequests == [.initial])
}

@Test
func foregroundActivationTriggersImmediateRefresh() async throws {
    let (store, _) = try makeStore()
    let account = makeAccount()
    let syncedAt = Date().addingTimeInterval(-3600)
    try await store.saveAccount(account)

    let inbox = MailboxRef(
        id: MailboxID(accountID: account.id, providerMailboxID: "INBOX"),
        accountID: account.id,
        providerMailboxID: "INBOX",
        displayName: "Inbox",
        kind: .system,
        systemRole: .inbox
    )

    try await store.upsertThreadDetails(
        [makeThreadDetail(account: account, providerThreadID: "existing", subject: "Existing mail", mailboxRefs: [inbox])],
        checkpoint: SyncCheckpoint(
            accountID: account.id,
            payload: "3001",
            lastSuccessfulSyncAt: syncedAt,
            lastBackfillAt: syncedAt
        )
    )

    let provider = TestMailProvider(
        mailboxes: [inbox],
        syncPages: [
            .delta("3001", nil): MailSyncPage(
                profile: .init(
                    providerAccountID: account.providerAccountID,
                    emailAddress: account.primaryEmail,
                    displayName: account.displayName
                ),
                mailboxes: [inbox],
                threadDetails: [makeThreadDetail(account: account, providerThreadID: "reactivated", subject: "Fresh from Gmail", mailboxRefs: [inbox])],
                checkpointPayload: "3002",
                nextPageToken: nil,
                isBackfillComplete: true
            ),
        ]
    )
    let credentials = TestCredentialsStore()
    try credentials.save(session: makeSession(for: account), for: account.id)
    let controller = MailWorkspaceController(
        store: store,
        credentialsStore: credentials,
        providers: [.gmail: provider]
    )

    await controller.setForegroundActive(false)
    await controller.setForegroundActive(true)

    let recordedRequests = await provider.recordedRequests()
    #expect(recordedRequests == [.delta("3001", nil)])

    let threads = try await store.listThreads(query: ThreadListQuery(tab: .all))
    #expect(threads.contains(where: { $0.providerThreadID == "reactivated" }))
}

@Test
func savingDraftUsesProviderDraftPersistenceWhenAvailable() async throws {
    let (store, _) = try makeStore()
    let account = makeAccount(email: "drafts@example.com")
    try await seedWorkspaceStore(store: store, account: account)

    let session = ProviderSession(
        providerKind: .gmail,
        providerAccountID: account.primaryEmail,
        emailAddress: account.primaryEmail,
        displayName: account.displayName,
        accessToken: "token"
    )
    let credentials = TestCredentialsStore(sessions: [account.id: session])
    let provider = TestMailProvider()
    let controller = MailWorkspaceController(
        store: store,
        credentialsStore: credentials,
        providers: [.gmail: provider]
    )

    let draft = OutgoingDraft(
        accountID: account.id,
        toRecipients: [MailParticipant(name: "Ops", emailAddress: "ops@example.com")],
        subject: "Persist remotely",
        plainBody: "Body"
    )

    try await controller.saveDraft(draft)

    let storedDrafts = try await controller.listDrafts()
    #expect(storedDrafts.count == 1)
    #expect(storedDrafts[0].providerDraftID != nil)
    #expect(storedDrafts[0].providerMessageID != nil)

    let savedDrafts = await provider.recordedSavedDrafts()
    #expect(savedDrafts.last?.subject == "Persist remotely")
}

@Test
func listingDraftsPreservesCachedIDsForRemoteDrafts() async throws {
    let (store, _) = try makeStore()
    let account = makeAccount(email: "drafts@example.com")
    try await seedWorkspaceStore(store: store, account: account)

    let cachedID = UUID()
    try await store.saveDraft(
        OutgoingDraft(
            id: cachedID,
            accountID: account.id,
            providerDraftID: "draft-1",
            providerMessageID: "message-1",
            subject: "Old subject",
            plainBody: "Old body"
        )
    )

    let remoteDraft = OutgoingDraft(
        id: UUID(),
        accountID: account.id,
        providerDraftID: "draft-1",
        providerMessageID: "message-2",
        subject: "New subject",
        plainBody: "New body"
    )
    let session = ProviderSession(
        providerKind: .gmail,
        providerAccountID: account.primaryEmail,
        emailAddress: account.primaryEmail,
        displayName: account.displayName,
        accessToken: "token"
    )
    let controller = MailWorkspaceController(
        store: store,
        credentialsStore: TestCredentialsStore(sessions: [account.id: session]),
        providers: [.gmail: TestMailProvider(remoteDrafts: [remoteDraft])]
    )

    let drafts = try await controller.listDrafts()
    let merged = try #require(drafts.first)

    #expect(merged.id == cachedID)
    #expect(merged.subject == "New subject")
    #expect(merged.plainBody == "New body")
}

@Test
func deletingProviderBackedDraftDeletesRemoteDraftToo() async throws {
    let (store, _) = try makeStore()
    let account = makeAccount(email: "drafts@example.com")
    try await seedWorkspaceStore(store: store, account: account)

    let draft = OutgoingDraft(
        accountID: account.id,
        providerDraftID: "draft-1",
        providerMessageID: "message-1",
        subject: "Delete me",
        plainBody: "Body"
    )
    try await store.saveDraft(draft)

    let session = ProviderSession(
        providerKind: .gmail,
        providerAccountID: account.primaryEmail,
        emailAddress: account.primaryEmail,
        displayName: account.displayName,
        accessToken: "token"
    )
    let provider = TestMailProvider(remoteDrafts: [draft])
    let controller = MailWorkspaceController(
        store: store,
        credentialsStore: TestCredentialsStore(sessions: [account.id: session]),
        providers: [.gmail: provider]
    )

    try await controller.deleteDraft(id: draft.id)

    let deletedDraftIDs = await provider.recordedDeletedDraftIDs()
    #expect(deletedDraftIDs == ["draft-1"])
    #expect(try await store.listDrafts().isEmpty)
}

private func makeStore() throws -> (SQLiteMailStore, String) {
    let path = NSTemporaryDirectory().appending("mail-data-\(UUID().uuidString).sqlite")
    return (try SQLiteMailStore(path: path), path)
}

private func makeAccount(
    email: String = "test@example.com",
    displayName: String = "Test",
    syncState: MailAccountSyncState = .init()
) -> MailAccount {
    MailAccount(
        id: MailAccountID(rawValue: "gmail:\(email)"),
        providerKind: .gmail,
        providerAccountID: email,
        primaryEmail: email,
        displayName: displayName,
        syncState: syncState,
        capabilities: .init(supportsArchive: true, supportsLabels: true, supportsCompose: true)
    )
}

private func makeSession(
    for account: MailAccount,
    accessToken: String = "token",
    displayName: String? = nil
) -> ProviderSession {
    ProviderSession(
        providerKind: account.providerKind,
        providerAccountID: account.providerAccountID,
        emailAddress: account.primaryEmail,
        displayName: displayName ?? account.displayName,
        accessToken: accessToken
    )
}

private func makeSyncPage(
    account: MailAccount,
    session: ProviderSession,
    threads: [MailThreadDetail],
    checkpointPayload: String? = "next-checkpoint"
) -> MailSyncPage {
    MailSyncPage(
        profile: ProviderAccountProfile(
            providerAccountID: session.providerAccountID,
            emailAddress: session.emailAddress,
            displayName: session.displayName
        ),
        mailboxes: [],
        threadDetails: threads,
        checkpointPayload: checkpointPayload,
        nextPageToken: nil,
        isBackfillComplete: true
    )
}

private func makeThreadDetail(
    account: MailAccount,
    providerThreadID: String,
    subject: String,
    mailboxRefs: [MailboxRef],
    snoozedUntil: Date? = nil
) -> MailThreadDetail {
    let threadID = MailThreadID(accountID: account.id, providerThreadID: providerThreadID)
    let messageID = MailMessageID(accountID: account.id, providerMessageID: "message-\(providerThreadID)")
    let message = MailMessage(
        id: messageID,
        threadID: threadID,
        accountID: account.id,
        providerMessageID: "message-\(providerThreadID)",
        sender: MailParticipant(name: "Ops", emailAddress: "ops@example.com"),
        toRecipients: [MailParticipant(name: account.displayName, emailAddress: account.primaryEmail)],
        sentAt: .now,
        receivedAt: .now,
        snippet: subject,
        plainBody: subject,
        bodyCacheState: .hot,
        headers: [MessageHeader(name: "Subject", value: subject)],
        mailboxRefs: mailboxRefs,
        isRead: false,
        isOutgoing: false
    )
    let thread = MailThread(
        id: threadID,
        accountID: account.id,
        providerThreadID: providerThreadID,
        subject: subject,
        participantSummary: "Ops",
        snippet: subject,
        lastActivityAt: .now,
        hasUnread: true,
        isStarred: false,
        isInInbox: true,
        mailboxRefs: mailboxRefs,
        latestMessageID: messageID,
        snoozedUntil: snoozedUntil,
        syncRevision: "rev-\(providerThreadID)"
    )
    return MailThreadDetail(thread: thread, messages: [message])
}

private func seedWorkspaceStore(store: SQLiteMailStore, account: MailAccount) async throws {
    let inbox = MailboxRef(
        id: MailboxID(accountID: account.id, providerMailboxID: "INBOX"),
        accountID: account.id,
        providerMailboxID: "INBOX",
        displayName: "Inbox",
        kind: .system,
        systemRole: .inbox
    )
    try await store.saveAccount(account)
    try await store.saveMailboxes([inbox])
    try await store.upsertThreadDetails(
        [makeThreadDetail(account: account, providerThreadID: "thread-1", subject: "Release checklist", mailboxRefs: [inbox])],
        checkpoint: nil
    )
}

private final class TestCredentialsStore: @unchecked Sendable, CredentialsStore {
    private var sessions: [MailAccountID: ProviderSession]

    init(sessions: [MailAccountID: ProviderSession] = [:]) {
        self.sessions = sessions
    }

    func save(session: ProviderSession, for accountID: MailAccountID) throws {
        sessions[accountID] = session
    }

    func load(accountID: MailAccountID) throws -> ProviderSession? {
        sessions[accountID]
    }

    func delete(accountID: MailAccountID) throws {
        sessions[accountID] = nil
    }

    var savedAccountIDs: [MailAccountID] {
        Array(sessions.keys)
    }
}

private final class TestMailProvider: @unchecked Sendable, MailProvider {
    let kind: ProviderKind = .gmail
    let environment: ProviderEnvironment = .production(
        apiBaseURL: URL(string: "https://example.com")!,
        authBaseURL: URL(string: "https://example.com")!,
        userInfoURL: URL(string: "https://example.com/me")!
    )

    private let applyError: Error?
    private var applyResults: [Error?]
    private let authorizeSession: ProviderSession?
    private let syncError: Error?
    private let saveDraftError: Error?
    private let listDraftsError: Error?
    private let deleteDraftError: Error?
    private let syncPages: [SyncKey: MailSyncPage]
    private let mailboxes: [MailboxRef]
    private var requests: [SyncKey] = []
    private var remoteDrafts: [OutgoingDraft]
    private var savedDrafts: [OutgoingDraft] = []
    private var deletedProviderDraftIDs: [String] = []
    private var sentDrafts: [OutgoingDraft] = []
    private var appliedMutations: [MailMutation] = []

    init(
        applyError: Error? = nil,
        applyResults: [Error?] = [],
        authorizeSession: ProviderSession? = nil,
        syncError: Error? = nil,
        mailboxes: [MailboxRef] = [],
        syncPages: [SyncKey: MailSyncPage] = [:],
        remoteDrafts: [OutgoingDraft] = [],
        saveDraftError: Error? = nil,
        listDraftsError: Error? = nil,
        deleteDraftError: Error? = nil
    ) {
        self.applyError = applyError
        self.applyResults = applyResults
        self.authorizeSession = authorizeSession
        self.syncError = syncError
        self.mailboxes = mailboxes
        self.syncPages = syncPages
        self.remoteDrafts = remoteDrafts
        self.saveDraftError = saveDraftError
        self.listDraftsError = listDraftsError
        self.deleteDraftError = deleteDraftError
    }

    @MainActor
    func authorize() async throws -> ProviderSession {
        guard let authorizeSession else {
            throw MailProviderError.unsupported("Not used in tests.")
        }
        return authorizeSession
    }

    @MainActor
    func handleRedirectURL(_ url: URL) -> Bool {
        false
    }

    func restoreSession(_ session: ProviderSession) async throws -> ProviderSession {
        session
    }

    func listMailboxes(session: ProviderSession, accountID: MailAccountID) async throws -> [MailboxRef] {
        mailboxes
    }

    func syncPage(session: ProviderSession, accountID: MailAccountID, request: MailSyncRequest) async throws -> MailSyncPage {
        let key = SyncKey(request.mode)
        requests.append(key)
        if let syncError {
            throw syncError
        }
        guard let page = syncPages[key] else {
            throw MailProviderError.transport("Missing test page for \(key)")
        }
        return page
    }

    func fetchThread(session: ProviderSession, accountID: MailAccountID, providerThreadID: String) async throws -> MailThreadDetail {
        throw MailProviderError.unsupported("Not used in tests.")
    }

    func fetchAttachment(session: ProviderSession, accountID: MailAccountID, attachment: MailAttachment) async throws -> Data {
        throw MailProviderError.unsupported("Not used in tests.")
    }

    func apply(session: ProviderSession, mutation: MailMutation) async throws {
        appliedMutations.append(mutation)
        if applyResults.isEmpty == false {
            let next = applyResults.removeFirst()
            if let next {
                throw next
            }
            return
        }
        if let applyError {
            throw applyError
        }
    }

    func send(session: ProviderSession, draft: OutgoingDraft) async throws -> SentDraftReceipt {
        sentDrafts.append(draft)
        return SentDraftReceipt(providerMessageID: "sent-\(draft.id.uuidString)", providerThreadID: draft.threadID?.providerThreadID)
    }

    func saveDraft(session: ProviderSession, draft: OutgoingDraft) async throws -> OutgoingDraft {
        if let saveDraftError {
            throw saveDraftError
        }

        var saved = draft
        if saved.providerDraftID == nil {
            saved.providerDraftID = "draft-\(draft.id.uuidString)"
        }
        if saved.providerMessageID == nil {
            saved.providerMessageID = "message-\(draft.id.uuidString)"
        }

        remoteDrafts.removeAll { $0.providerDraftID == saved.providerDraftID }
        remoteDrafts.insert(saved, at: 0)
        savedDrafts.append(saved)
        return saved
    }

    func listDrafts(session: ProviderSession, accountID: MailAccountID) async throws -> [OutgoingDraft] {
        if let listDraftsError {
            throw listDraftsError
        }
        return remoteDrafts.filter { $0.accountID == accountID }
    }

    func deleteDraft(session: ProviderSession, providerDraftID: String) async throws {
        if let deleteDraftError {
            throw deleteDraftError
        }
        deletedProviderDraftIDs.append(providerDraftID)
        remoteDrafts.removeAll { $0.providerDraftID == providerDraftID }
    }

    func recordedRequests() async -> [SyncKey] {
        requests
    }

    func recordedSavedDrafts() async -> [OutgoingDraft] {
        savedDrafts
    }

    func recordedDeletedDraftIDs() async -> [String] {
        deletedProviderDraftIDs
    }

    func recordedSentDrafts() async -> [OutgoingDraft] {
        sentDrafts
    }

    func recordedAppliedMutations() async -> [MailMutation] {
        appliedMutations
    }
}

private final class FailingInitialSyncProvider: MailProvider {
    let kind: ProviderKind = .gmail
    let environment = ProviderEnvironment.production(apiBaseURL: URL(string: "https://example.com")!)

    @MainActor
    func authorize() async throws -> ProviderSession {
        ProviderSession(
            providerKind: .gmail,
            providerAccountID: "real@example.com",
            emailAddress: "real@example.com",
            displayName: "Real",
            accessToken: "token"
        )
    }

    @MainActor
    func handleRedirectURL(_ url: URL) -> Bool { false }

    func restoreSession(_ session: ProviderSession) async throws -> ProviderSession { session }

    func listMailboxes(session: ProviderSession, accountID: MailAccountID) async throws -> [MailboxRef] { [] }

    func syncPage(session: ProviderSession, accountID: MailAccountID, request: MailSyncRequest) async throws -> MailSyncPage {
        throw MailProviderError.transport("Sync failed")
    }

    func fetchThread(session: ProviderSession, accountID: MailAccountID, providerThreadID: String) async throws -> MailThreadDetail {
        throw MailProviderError.unsupported("Not used in test")
    }

    func fetchAttachment(session: ProviderSession, accountID: MailAccountID, attachment: MailAttachment) async throws -> Data {
        throw MailProviderError.unsupported("Not used in test")
    }

    func apply(session: ProviderSession, mutation: MailMutation) async throws {
        throw MailProviderError.unsupported("Not used in test")
    }

    func send(session: ProviderSession, draft: OutgoingDraft) async throws -> SentDraftReceipt {
        throw MailProviderError.unsupported("Not used in test")
    }
}

private enum SyncKey: Hashable, CustomStringConvertible {
    case initial
    case backfill(String?)
    case delta(String, String?)

    init(_ mode: MailSyncMode) {
        switch mode {
        case .initial:
            self = .initial
        case let .backfill(pageToken):
            self = .backfill(pageToken)
        case let .delta(checkpointPayload, pageToken):
            self = .delta(checkpointPayload, pageToken)
        }
    }

    var description: String {
        switch self {
        case .initial:
            "initial"
        case let .backfill(pageToken):
            "backfill(\(pageToken ?? "nil"))"
        case let .delta(checkpointPayload, pageToken):
            "delta(\(checkpointPayload), \(pageToken ?? "nil"))"
        }
    }
}
