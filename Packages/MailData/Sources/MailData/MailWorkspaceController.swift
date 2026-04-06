import Foundation
import MailCore
import OSLog
import ProviderCore

public actor MailWorkspaceController: MailWorkspace {
    private let store: MailStore
    private let credentialsStore: CredentialsStore
    private let providers: [ProviderKind: any MailProvider]
    private let previewMode: Bool
    private var foregroundRefreshTask: Task<Void, Never>?
    private var isForegroundActive = true
    private var changeVersion = 0
    private var continuations: [UUID: AsyncStream<Int>.Continuation] = [:]
    private var refreshBackoff: [MailAccountID: Int] = [:]
    private var nextEligibleRefresh: [MailAccountID: Date] = [:]
    private var labelVisibilityRefreshed: Set<MailAccountID> = []
    private let syncLogger = Logger(subsystem: "InboxZeroMail", category: "MailSync")
    private let mutationLogger = Logger(subsystem: "InboxZeroMail", category: "MailMutations")
    private var queuedMutationWakeupTask: Task<Void, Never>?
    private var isProcessingQueuedMutations = false
    private var scheduledRefreshTasks: [MailAccountID: Task<Void, Never>] = [:]

    public init(
        store: MailStore,
        credentialsStore: CredentialsStore,
        providers: [ProviderKind: any MailProvider],
        previewMode: Bool = false
    ) {
        self.store = store
        self.credentialsStore = credentialsStore
        self.providers = providers
        self.previewMode = previewMode
    }

    public func changes() async -> AsyncStream<Int> {
        let streamID = UUID()
        return AsyncStream { continuation in
            continuation.yield(changeVersion)
            continuations[streamID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeContinuation(streamID)
                }
            }
        }
    }

    public func start() async {
        if previewMode == false {
            startForegroundRefreshLoop()
            await processQueuedMutationsIfNeeded()
            await refreshAll()
        }
    }

    public func setForegroundActive(_ isActive: Bool) async {
        let becameActive = isActive && isForegroundActive == false
        isForegroundActive = isActive
        if previewMode == false {
            startForegroundRefreshLoop()
            if becameActive {
                await refreshAll()
            }
        }
    }

    public func connectAccount(kind: ProviderKind) async throws {
        guard let provider = providers[kind] else {
            throw MailProviderError.missingConfiguration("No provider is registered for \(kind.rawValue).")
        }

        let session = try await provider.authorize()
        let accountID = MailAccountID(rawValue: "\(kind.rawValue):\(session.emailAddress.lowercased())")
        let account = MailAccount(
            id: accountID,
            providerKind: kind,
            providerAccountID: session.providerAccountID,
            primaryEmail: session.emailAddress,
            displayName: session.displayName,
            syncState: .init(phase: .syncing),
            capabilities: capabilities(for: kind)
        )
        try await saveAuthorizedAccount(account, session: session)
    }

    public func reconnectAccount(accountID: MailAccountID) async throws {
        guard let existingAccount = try await store.listAccounts().first(where: { $0.id == accountID }) else {
            throw MailProviderError.transport("Unknown account \(accountID.rawValue).")
        }
        guard let provider = providers[existingAccount.providerKind] else {
            throw MailProviderError.missingConfiguration("No provider is registered for \(existingAccount.providerKind.rawValue).")
        }

        let session = try await provider.authorize()
        let resolvedAccountID = MailAccountID(rawValue: "\(existingAccount.providerKind.rawValue):\(session.emailAddress.lowercased())")
        guard resolvedAccountID == accountID else {
            throw MailProviderError.transport(
                "Signed in as \(session.emailAddress). Reconnect \(existingAccount.primaryEmail) with the same account, or add \(session.emailAddress) separately."
            )
        }

        let updatedAccount = MailAccount(
            id: accountID,
            providerKind: existingAccount.providerKind,
            providerAccountID: session.providerAccountID,
            primaryEmail: session.emailAddress,
            displayName: session.displayName,
            syncState: .init(
                phase: .syncing,
                lastSuccessfulSyncAt: existingAccount.syncState.lastSuccessfulSyncAt
            ),
            capabilities: capabilities(for: existingAccount.providerKind)
        )
        try await saveAuthorizedAccount(updatedAccount, session: session)
    }

    public func listAccounts() async throws -> [MailAccount] {
        try await store.listAccounts()
    }

    public func listMailboxes(accountID: MailAccountID?) async throws -> [MailboxRef] {
        try await store.listMailboxes(accountID: accountID)
    }

    public func listThreads(query: ThreadListQuery) async throws -> [MailThread] {
        try await store.listThreads(query: query)
    }

    public func countThreads(query: ThreadListQuery) async throws -> Int {
        try await store.countThreads(query: query)
    }

    public func loadThread(id: MailThreadID) async throws -> MailThreadDetail? {
        guard let detail = try await store.loadThread(id: id) else { return nil }

        // Re-fetch from the provider if any message body was evicted
        let needsRehydration = detail.messages.contains { $0.bodyCacheState == .cold || $0.bodyCacheState == .missing }
        guard needsRehydration else { return detail }

        let accountID = id.accountID
        guard let account = try await store.listAccounts().first(where: { $0.id == accountID }),
              let provider = providers[account.providerKind],
              var session = try credentialsStore.load(accountID: accountID) else {
            return detail
        }

        do {
            let restored = try await provider.restoreSession(session)
            if restored.accessToken != session.accessToken {
                session = restored
                try credentialsStore.save(session: session, for: accountID)
            }

            let fresh = try await provider.fetchThread(session: session, accountID: accountID, providerThreadID: id.providerThreadID)
            try await store.upsertThreadDetails([fresh], checkpoint: nil)
            return try await store.loadThread(id: id) ?? fresh
        } catch {
            return detail
        }
    }

    public func refreshAll() async {
        await processQueuedMutationsIfNeeded()
        let accounts = (try? await store.listAccounts()) ?? []
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask { [weak self] in
                    try? await self?.refreshAccount(account.id)
                }
            }
        }
        publishChange()
    }

    public func perform(_ mutation: MailMutation) async throws {
        let accountID = mutation.accountID
        guard let account = try await store.listAccounts().first(where: { $0.id == accountID }) else {
            throw MailProviderError.transport("Unknown account \(accountID.rawValue) for mutation.")
        }

        if previewMode {
            let queueID = try await store.enqueue(mutation)
            try await store.applyOptimistic(mutation)
            publishChange()
            try await store.completeQueuedMutation(id: queueID)
            return
        }

        guard let provider = providers[account.providerKind] else {
            throw MailProviderError.missingConfiguration("No provider is registered for \(account.providerKind.rawValue).")
        }

        guard let session = try credentialsStore.load(accountID: accountID) else {
            await markAuthorizationFailure(accountID, missingCredentials: true)
            throw MailProviderError.unauthorized
        }

        let queueID = try await store.enqueue(mutation)
        try await store.applyOptimistic(mutation)
        publishChange()
        do {
            try await applyQueuedMutation(
                QueuedMailMutation(
                    id: queueID,
                    accountID: accountID,
                    mutation: mutation,
                    createdAt: Date()
                ),
                provider: provider,
                session: session,
                source: .userInitiated
            )
        } catch {
            throw error
        }
    }

    public func send(_ draft: OutgoingDraft) async throws {
        guard previewMode == false else {
            publishChange()
            return
        }

        let resolvedDraft = try await hydrateDraftMetadata(for: draft)
        guard let account = try await store.listAccounts().first(where: { $0.id == resolvedDraft.accountID }) else {
            throw MailProviderError.transport("Unknown account \(resolvedDraft.accountID.rawValue) for compose.")
        }
        guard let provider = providers[account.providerKind] else {
            throw MailProviderError.missingConfiguration("No provider is registered for \(account.providerKind.rawValue).")
        }
        guard let session = try credentialsStore.load(accountID: resolvedDraft.accountID) else {
            await markAuthorizationFailure(resolvedDraft.accountID, missingCredentials: true)
            throw MailProviderError.unauthorized
        }

        do {
            _ = try await provider.send(session: session, draft: resolvedDraft)
            try await refreshAccount(resolvedDraft.accountID)
        } catch {
            if isUnauthorized(error) {
                await markAuthorizationFailure(resolvedDraft.accountID)
            }
            throw error
        }
    }

    public func seedDemoDataIfNeeded() async throws {
        try await store.seedDemoDataIfNeeded()
        publishChange()
    }

    public func removeAccount(accountID: MailAccountID) async throws {
        try credentialsStore.delete(accountID: accountID)
        try await store.removeAccount(accountID: accountID)
        publishChange()
    }

    public func saveDraft(_ draft: OutgoingDraft) async throws {
        let resolvedDraft = try await hydrateDraftMetadata(for: draft)

        guard previewMode == false else {
            try await store.saveDraft(resolvedDraft)
            return
        }

        guard let account = try await store.listAccounts().first(where: { $0.id == resolvedDraft.accountID }) else {
            try await store.saveDraft(resolvedDraft)
            throw MailProviderError.transport("Unknown account \(resolvedDraft.accountID.rawValue) for compose.")
        }
        guard let provider = providers[account.providerKind] else {
            try await store.saveDraft(resolvedDraft)
            throw MailProviderError.missingConfiguration("No provider is registered for \(account.providerKind.rawValue).")
        }
        guard let session = try credentialsStore.load(accountID: resolvedDraft.accountID) else {
            try await store.saveDraft(resolvedDraft)
            await markAuthorizationFailure(resolvedDraft.accountID, missingCredentials: true)
            throw MailProviderError.unauthorized
        }

        do {
            let providerDraft = try await provider.saveDraft(session: session, draft: resolvedDraft)
            try await store.saveDraft(preservingLocalDraftFields(from: resolvedDraft, into: providerDraft))
        } catch let error as MailProviderError {
            if case .unsupported = error {
                try await store.saveDraft(resolvedDraft)
                return
            }
            try await store.saveDraft(resolvedDraft)
            if isUnauthorized(error) {
                await markAuthorizationFailure(resolvedDraft.accountID)
            }
            throw error
        } catch {
            try await store.saveDraft(resolvedDraft)
            throw error
        }
    }

    public func listDrafts() async throws -> [OutgoingDraft] {
        let cachedDrafts = try await store.listDrafts()
        guard previewMode == false else { return cachedDrafts }

        let accounts = try await store.listAccounts()
        for account in accounts {
            guard let provider = providers[account.providerKind] else { continue }
            guard let session = try? credentialsStore.load(accountID: account.id) else { continue }

            do {
                let remoteDrafts = try await provider.listDrafts(session: session, accountID: account.id)
                let cachedAccountDrafts = cachedDrafts.filter { $0.accountID == account.id }
                let normalizedRemoteDrafts = remoteDrafts.map { remoteDraft -> OutgoingDraft in
                    guard let providerDraftID = remoteDraft.providerDraftID,
                          let cached = cachedAccountDrafts.first(where: { $0.providerDraftID == providerDraftID }) else {
                        return remoteDraft
                    }

                    return preservingLocalDraftFields(from: cached, into: remoteDraft)
                }

                let remoteProviderDraftIDs = Set(normalizedRemoteDrafts.compactMap(\.providerDraftID))
                for cached in cachedAccountDrafts
                where cached.providerDraftID.map({ remoteProviderDraftIDs.contains($0) }) == false {
                    try await store.deleteDraft(id: cached.id)
                }
                for remoteDraft in normalizedRemoteDrafts {
                    try await store.saveDraft(remoteDraft)
                }
            } catch {
                continue
            }
        }

        return try await store.listDrafts()
    }

    public func deleteDraft(id: UUID) async throws {
        let drafts = try await store.listDrafts()
        guard let draft = drafts.first(where: { $0.id == id }) else {
            try await store.deleteDraft(id: id)
            return
        }

        guard previewMode == false else {
            try await store.deleteDraft(id: id)
            return
        }

        if let providerDraftID = draft.providerDraftID,
           let account = try await store.listAccounts().first(where: { $0.id == draft.accountID }),
           let provider = providers[account.providerKind],
           let session = try credentialsStore.load(accountID: draft.accountID) {
            do {
                try await provider.deleteDraft(session: session, providerDraftID: providerDraftID)
            } catch {
                if isUnauthorized(error) {
                    await markAuthorizationFailure(draft.accountID)
                }
                throw error
            }
        }

        try await store.deleteDraft(id: id)
    }

    public func updateMailboxVisibility(mailboxID: MailboxID, hidden: Bool) async throws {
        let accountID = mailboxID.accountID
        guard let account = try await store.listAccounts().first(where: { $0.id == accountID }) else {
            throw MailProviderError.transport("Unknown account \(accountID.rawValue).")
        }
        guard let provider = providers[account.providerKind] else {
            throw MailProviderError.missingConfiguration("No provider for \(account.providerKind.rawValue).")
        }
        guard let session = try credentialsStore.load(accountID: accountID) else {
            await markAuthorizationFailure(accountID, missingCredentials: true)
            throw MailProviderError.unauthorized
        }
        try await provider.updateMailboxVisibility(session: session, providerMailboxID: mailboxID.providerMailboxID, hidden: hidden)
        // Update local store
        var mailboxes = try await store.listMailboxes(accountID: accountID)
        if let idx = mailboxes.firstIndex(where: { $0.id == mailboxID }) {
            mailboxes[idx].isHiddenInLabelList = hidden
            try await store.saveMailboxes(mailboxes)
        }
        publishChange()
    }

    public func fetchAttachment(_ attachment: MailAttachment) async throws -> Data {
        let accountID = attachment.messageID.accountID
        guard previewMode == false else {
            throw MailProviderError.unsupported("Attachment download is not available in preview mode.")
        }
        guard let account = try await store.listAccounts().first(where: { $0.id == accountID }) else {
            throw MailProviderError.transport("Unknown account \(accountID.rawValue).")
        }
        guard let provider = providers[account.providerKind] else {
            throw MailProviderError.missingConfiguration("No provider is registered for \(account.providerKind.rawValue).")
        }
        guard var session = try credentialsStore.load(accountID: accountID) else {
            await markAuthorizationFailure(accountID, missingCredentials: true)
            throw MailProviderError.unauthorized
        }

        do {
            let restored = try await provider.restoreSession(session)
            if restored.accessToken != session.accessToken {
                session = restored
                try credentialsStore.save(session: session, for: accountID)
            }
            return try await provider.fetchAttachment(session: session, accountID: accountID, attachment: attachment)
        } catch {
            if isUnauthorized(error) {
                await markAuthorizationFailure(accountID)
            }
            throw error
        }
    }

    public func handleRedirectURL(_ url: URL) async -> Bool {
        for provider in providers.values {
            if await MainActor.run(body: { provider.handleRedirectURL(url) }) {
                return true
            }
        }
        return false
    }
}

private extension MailWorkspaceController {
    func preservingLocalDraftFields(from localDraft: OutgoingDraft, into remoteDraft: OutgoingDraft) -> OutgoingDraft {
        var preserved = remoteDraft
        preserved.id = localDraft.id
        preserved.htmlBody = localDraft.htmlBody ?? remoteDraft.htmlBody
        preserved.quotedReply = localDraft.quotedReply
        return preserved
    }
}

private enum MutationApplicationSource: String {
    case userInitiated
    case backgroundRetry
}

private extension MailWorkspaceController {
    func hydrateDraftMetadata(for draft: OutgoingDraft) async throws -> OutgoingDraft {
        guard draft.providerDraftID == nil else { return draft }
        let cachedDrafts = try await store.listDrafts()
        guard let cached = cachedDrafts.first(where: { $0.id == draft.id }) else { return draft }

        var mergedDraft = draft
        mergedDraft.providerDraftID = cached.providerDraftID
        mergedDraft.providerMessageID = cached.providerMessageID
        mergedDraft.threadID = draft.threadID ?? cached.threadID
        return mergedDraft
    }

    func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    func publishChange() {
        changeVersion += 1
        continuations.values.forEach { $0.yield(changeVersion) }
    }

    func processQueuedMutationsIfNeeded() async {
        guard previewMode == false else { return }
        guard isProcessingQueuedMutations == false else { return }
        isProcessingQueuedMutations = true
        defer {
            isProcessingQueuedMutations = false
        }

        let ready = (try? await store.loadReadyQueuedMutations(asOf: Date(), limit: 50)) ?? []
        guard ready.isEmpty == false else {
            scheduleQueuedMutationWakeup()
            return
        }

        for queued in ready {
            guard let account = try? await store.listAccounts().first(where: { $0.id == queued.accountID }),
                  let provider = providers[account.providerKind] else {
                continue
            }

            guard let session = try? credentialsStore.load(accountID: queued.accountID) else {
                await handleFailedQueuedMutation(queued, error: MailProviderError.unauthorized)
                continue
            }

            do {
                try await applyQueuedMutation(queued, provider: provider, session: session, source: .backgroundRetry)
            } catch {
                continue
            }
        }

        scheduleQueuedMutationWakeup()
    }

    func scheduleQueuedMutationWakeup() {
        queuedMutationWakeupTask?.cancel()
        queuedMutationWakeupTask = Task { [weak self] in
            guard let self else { return }
            guard let nextAttemptAt = try? await self.store.nextQueuedMutationAttemptDate() else { return }

            let delay = max(0, nextAttemptAt.timeIntervalSinceNow)
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard Task.isCancelled == false else { return }
            await self.processQueuedMutationsIfNeeded()
        }
    }

    func scheduleRefreshAfterMutation(for accountID: MailAccountID) {
        scheduledRefreshTasks[accountID]?.cancel()
        scheduledRefreshTasks[accountID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard Task.isCancelled == false else { return }
            await self?.runScheduledRefresh(for: accountID)
        }
    }

    func runScheduledRefresh(for accountID: MailAccountID) async {
        scheduledRefreshTasks[accountID] = nil
        try? await refreshAccount(accountID)
        publishChange()
    }

    func applyQueuedMutation(
        _ queued: QueuedMailMutation,
        provider: any MailProvider,
        session: ProviderSession,
        source: MutationApplicationSource
    ) async throws {
        do {
            try await provider.apply(session: session, mutation: queued.mutation)
            try await store.completeQueuedMutation(id: queued.id)
            mutationLogger.notice(
                "Applied queued mutation \(queued.id.uuidString, privacy: .public) for \(queued.accountID.rawValue, privacy: .public) via \(source.rawValue, privacy: .public)"
            )
            scheduleRefreshAfterMutation(for: queued.accountID)
        } catch {
            let shouldThrow = try await handleMutationFailure(queued, error: error, source: source)
            if shouldThrow {
                throw error
            }
        }
    }

    func handleMutationFailure(_ queued: QueuedMailMutation, error: Error, source: MutationApplicationSource) async throws -> Bool {
        if isRetryableMutationError(error) {
            let nextRetryAt = Date().addingTimeInterval(retryDelay(for: error, retryCount: queued.retryCount))
            try await store.markQueuedMutationForRetry(
                id: queued.id,
                errorDescription: String(describing: error),
                retryCount: queued.retryCount + 1,
                nextAttemptAt: nextRetryAt
            )
            mutationLogger.notice(
                "Deferring queued mutation \(queued.id.uuidString, privacy: .public) for \(queued.accountID.rawValue, privacy: .public) by \(self.retryDelay(for: error, retryCount: queued.retryCount), privacy: .public)s"
            )
            scheduleQueuedMutationWakeup()
            return false
        }

        await handleFailedQueuedMutation(queued, error: error)
        return source == .userInitiated
    }

    func handleFailedQueuedMutation(_ queued: QueuedMailMutation, error: Error) async {
        if let rollback = queued.mutation.rollbackMutation {
            try? await store.applyOptimistic(rollback)
            publishChange()
        }
        if isUnauthorized(error) {
            try? await store.completeQueuedMutation(id: queued.id)
            await markAuthorizationFailure(queued.accountID)
        } else {
            try? await store.failQueuedMutation(id: queued.id, errorDescription: String(describing: error))
            scheduleRefreshAfterMutation(for: queued.accountID)
        }
    }

    func refreshAccount(_ accountID: MailAccountID, rethrowFailures: Bool = false) async throws {
        let now = Date()
        if let nextEligible = nextEligibleRefresh[accountID], nextEligible > now {
            return
        }
        if (try? await store.hasPendingQueuedMutations(accountID: accountID)) == true {
            scheduleQueuedMutationWakeup()
            return
        }

        guard let account = try await store.listAccounts().first(where: { $0.id == accountID }) else {
            return
        }
        guard let provider = providers[account.providerKind] else {
            return
        }
        guard var session = try credentialsStore.load(accountID: accountID) else {
            await markAuthorizationFailure(accountID, missingCredentials: true)
            if rethrowFailures {
                throw MailProviderError.unauthorized
            }
            return
        }

        do {
            let restored = try await provider.restoreSession(session)
            if restored.accessToken != session.accessToken {
                session = restored
                try credentialsStore.save(session: session, for: accountID)
            }
        } catch {
            if isUnauthorized(error) {
                await markAuthorizationFailure(accountID)
            } else {
                await saveSyncFailure(accountID: accountID, lastSuccessfulSyncAt: account.syncState.lastSuccessfulSyncAt, error: error)
            }
            if rethrowFailures { throw error }
            return
        }

        try await store.saveSyncState(accountID: accountID, .init(phase: .syncing, lastSuccessfulSyncAt: account.syncState.lastSuccessfulSyncAt))

        do {
            let syncedAccount = try await syncAccountPages(account: account, provider: provider, session: session)
            try await store.saveAccount(syncedAccount)
            try await store.evictColdBodies(maxHotThreads: 200, maxAge: 14 * 24 * 60 * 60)
            if account.syncState.isErrorState {
                syncLogger.notice("Sync recovered for account \(account.id.rawValue, privacy: .public)")
            }
            refreshBackoff[accountID] = 0
            nextEligibleRefresh[accountID] = nil
        } catch {
            if isUnauthorized(error) {
                await markAuthorizationFailure(accountID)
                if rethrowFailures {
                    throw error
                }
                return
            }
            if isRetryableMutationError(error) {
                let nextIndex = min((refreshBackoff[accountID] ?? 0) + 1, 5)
                refreshBackoff[accountID] = nextIndex
                let delay = retryDelay(for: error, retryCount: nextIndex - 1)
                nextEligibleRefresh[accountID] = Date().addingTimeInterval(delay)
                syncLogger.notice("Sync rate-limited for account \(account.id.rawValue, privacy: .public)")
                try? await store.saveSyncState(
                    accountID: accountID,
                    .init(phase: .idle, lastSuccessfulSyncAt: account.syncState.lastSuccessfulSyncAt)
                )
                if rethrowFailures {
                    throw error
                }
                return
            }
            let nextIndex = min((refreshBackoff[accountID] ?? 0) + 1, 5)
            refreshBackoff[accountID] = nextIndex
            let delay: TimeInterval = [0, 30, 60, 120, 300, 900][nextIndex]
            nextEligibleRefresh[accountID] = Date().addingTimeInterval(delay)
            syncLogger.error("Sync failed for account \(account.id.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            try await store.saveSyncState(
                accountID: accountID,
                .init(
                    phase: .error,
                    lastSuccessfulSyncAt: account.syncState.lastSuccessfulSyncAt,
                    lastErrorDescription: String(describing: error)
                )
            )
            if rethrowFailures {
                throw error
            }
        }

        // Refresh label visibility separately (individual API calls, done after sync to avoid rate limits).
        // Done once per session per account — restart the app to pick up visibility changes from Gmail web.
        if !labelVisibilityRefreshed.contains(accountID) {
            labelVisibilityRefreshed.insert(accountID)
            try? await refreshLabelVisibility(accountID: accountID, provider: provider, session: session)
        }
    }

    func markAuthorizationFailure(_ accountID: MailAccountID, missingCredentials: Bool = false) async {
        refreshBackoff[accountID] = nil
        nextEligibleRefresh[accountID] = nil
        if missingCredentials == false {
            try? credentialsStore.delete(accountID: accountID)
        }
        if let account = try? await store.listAccounts().first(where: { $0.id == accountID }) {
            try? await store.saveSyncState(
                accountID: accountID,
                .init(
                    phase: .reauthRequired,
                    lastSuccessfulSyncAt: account.syncState.lastSuccessfulSyncAt,
                    lastErrorDescription: missingCredentials
                        ? "Account credentials are missing. Reconnect the account to resume sync."
                        : "Account authorization expired. Reconnect the account to resume sync."
                )
            )
        }
        publishChange()
    }

    func saveSyncFailure(accountID: MailAccountID, lastSuccessfulSyncAt: Date?, error: Error) async {
        let description = String(describing: error)
        try? await store.saveSyncState(
            accountID: accountID,
            .init(
                phase: .error,
                lastSuccessfulSyncAt: lastSuccessfulSyncAt,
                lastErrorDescription: description
            )
        )
        publishChange()
    }

    func refreshLabelVisibility(accountID: MailAccountID, provider: any MailProvider, session: ProviderSession) async throws {
        let detailed = try await provider.fetchLabelVisibility(session: session, accountID: accountID)
        guard detailed.isEmpty == false else { return }
        var stored = try await store.listMailboxes(accountID: accountID)
        var changed = false
        for ref in detailed {
            if let idx = stored.firstIndex(where: { $0.id == ref.id }), stored[idx].isHiddenInLabelList != ref.isHiddenInLabelList {
                stored[idx].isHiddenInLabelList = ref.isHiddenInLabelList
                changed = true
            }
        }
        if changed {
            try await store.saveMailboxes(stored)
            publishChange()
        }
    }

    func isUnauthorized(_ error: Error) -> Bool {
        guard let providerError = error as? MailProviderError else { return false }
        if case .unauthorized = providerError {
            return true
        }
        return false
    }

    func saveAuthorizedAccount(_ account: MailAccount, session: ProviderSession) async throws {
        try await store.saveAccount(account)
        try credentialsStore.save(session: session, for: account.id)
        do {
            try await refreshAccount(account.id, rethrowFailures: true)
        } catch {}
        publishChange()
    }

    func isRetryableMutationError(_ error: Error) -> Bool {
        guard let providerError = error as? MailProviderError else { return false }
        if case .rateLimited = providerError {
            return true
        }
        return false
    }

    func retryDelay(for error: Error, retryCount: Int) -> TimeInterval {
        if case let MailProviderError.rateLimited(_, retryAfter) = error {
            let floor = [15.0, 30.0, 60.0, 120.0, 300.0][min(retryCount, 4)]
            return max(retryAfter ?? 0, floor)
        }
        return [15.0, 30.0, 60.0, 120.0, 300.0][min(retryCount, 4)]
    }

    func syncAccountPages(
        account: MailAccount,
        provider: any MailProvider,
        session: ProviderSession
    ) async throws -> MailAccount {
        let checkpoint = try await store.loadCheckpoint(accountID: account.id)
        let didFinishBackfill = checkpoint?.lastBackfillAt != nil
        let hasUsableCheckpoint = checkpoint.map { isUsableCheckpoint($0.payload, for: account.providerKind) } ?? false
        let shouldRunFullBackfill = checkpoint == nil || didFinishBackfill == false || hasUsableCheckpoint == false
        let syncedAt = Date()

        if let checkpoint, didFinishBackfill, hasUsableCheckpoint == false {
            syncLogger.notice("Discarding invalid checkpoint for account \(account.id.rawValue, privacy: .public): \(checkpoint.payload, privacy: .public)")
        }

        do {
            if shouldRunFullBackfill {
                return try await runBackfillSync(account: account, provider: provider, session: session, syncedAt: syncedAt)
            }
            return try await runDeltaSync(
                account: account,
                provider: provider,
                session: session,
                checkpointPayload: checkpoint!.payload,
                syncedAt: syncedAt
            )
        } catch MailProviderError.invalidCheckpoint {
            syncLogger.notice("Provider rejected checkpoint for account \(account.id.rawValue, privacy: .public). Falling back to full backfill.")
            return try await runBackfillSync(account: account, provider: provider, session: session, syncedAt: syncedAt)
        }
    }

    func runBackfillSync(
        account: MailAccount,
        provider: any MailProvider,
        session: ProviderSession,
        syncedAt: Date
    ) async throws -> MailAccount {
        var request = MailSyncRequest(mode: .initial, limit: 50)
        var latestPage: MailSyncPage?
        var latestCheckpointPayload: String?

        while true {
            let page = try await provider.syncPage(session: session, accountID: account.id, request: request)
            latestPage = page
            latestCheckpointPayload = page.checkpointPayload ?? latestCheckpointPayload

            let checkpointToSave = latestCheckpointPayload.map {
                SyncCheckpoint(
                    accountID: account.id,
                    payload: $0,
                    lastSuccessfulSyncAt: syncedAt,
                    lastBackfillAt: page.isBackfillComplete ? syncedAt : nil
                )
            }
            try await store.saveMailboxes(page.mailboxes)
            try await store.upsertThreadDetails(page.threadDetails, checkpoint: checkpointToSave)

            guard page.isBackfillComplete == false, let nextPageToken = page.nextPageToken else {
                return savedAccount(from: latestPage ?? page, account: account, syncedAt: syncedAt)
            }

            request = MailSyncRequest(mode: .backfill(pageToken: nextPageToken), limit: request.limit)
        }
    }

    func runDeltaSync(
        account: MailAccount,
        provider: any MailProvider,
        session: ProviderSession,
        checkpointPayload: String,
        syncedAt: Date
    ) async throws -> MailAccount {
        var request = MailSyncRequest(mode: .delta(checkpointPayload: checkpointPayload, pageToken: nil), limit: 50)
        var latestPage: MailSyncPage?
        var latestCheckpointPayload = checkpointPayload

        while true {
            let page = try await provider.syncPage(session: session, accountID: account.id, request: request)
            latestPage = page
            latestCheckpointPayload = page.checkpointPayload ?? latestCheckpointPayload

            try await store.saveMailboxes(page.mailboxes)
            let checkpointToSave = SyncCheckpoint(
                accountID: account.id,
                payload: latestCheckpointPayload,
                lastSuccessfulSyncAt: syncedAt,
                lastBackfillAt: syncedAt
            )
            try await store.upsertThreadDetails(page.threadDetails, checkpoint: checkpointToSave)

            guard let nextPageToken = page.nextPageToken else {
                return savedAccount(from: latestPage ?? page, account: account, syncedAt: syncedAt)
            }

            request = MailSyncRequest(
                mode: .delta(checkpointPayload: checkpointPayload, pageToken: nextPageToken),
                limit: request.limit
            )
        }
    }

    func savedAccount(from page: MailSyncPage, account: MailAccount, syncedAt: Date) -> MailAccount {
        MailAccount(
            id: account.id,
            providerKind: account.providerKind,
            providerAccountID: page.profile.providerAccountID,
            primaryEmail: page.profile.emailAddress,
            displayName: page.profile.displayName,
            syncState: .init(phase: .idle, lastSuccessfulSyncAt: syncedAt),
            capabilities: account.capabilities
        )
    }

    func startForegroundRefreshLoop() {
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = Task { [weak self] in
            guard let self else { return }
            while Task.isCancelled == false {
                let interval = await self.currentRefreshInterval()
                try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
                if Task.isCancelled { break }
                await self.refreshAll()
            }
        }
    }

    func currentRefreshInterval() -> UInt64 {
        isForegroundActive ? 60 : 300
    }

    func capabilities(for kind: ProviderKind) -> MailAccountCapabilities {
        switch kind {
        case .gmail:
            .init(supportsArchive: true, supportsLabels: true, supportsFolders: false, supportsCategories: false, supportsCompose: true)
        case .microsoft:
            .init(supportsArchive: true, supportsLabels: false, supportsFolders: true, supportsCategories: true, supportsCompose: false)
        }
    }

    func isUsableCheckpoint(_ payload: String, for kind: ProviderKind) -> Bool {
        switch kind {
        case .gmail:
            payload.isEmpty == false && payload.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains)
        case .microsoft:
            payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }
}
