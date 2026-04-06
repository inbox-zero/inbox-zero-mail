import Foundation
import MailCore
import ProviderCore

public struct QueuedMailMutation: Sendable, Hashable {
    public enum Status: String, Sendable {
        case pending
        case failed
    }

    public var id: UUID
    public var accountID: MailAccountID
    public var mutation: MailMutation
    public var createdAt: Date
    public var retryCount: Int
    public var nextAttemptAt: Date?
    public var lastAttemptAt: Date?
    public var lastErrorDescription: String?
    public var status: Status

    public init(
        id: UUID,
        accountID: MailAccountID,
        mutation: MailMutation,
        createdAt: Date,
        retryCount: Int = 0,
        nextAttemptAt: Date? = nil,
        lastAttemptAt: Date? = nil,
        lastErrorDescription: String? = nil,
        status: Status = .pending
    ) {
        self.id = id
        self.accountID = accountID
        self.mutation = mutation
        self.createdAt = createdAt
        self.retryCount = retryCount
        self.nextAttemptAt = nextAttemptAt
        self.lastAttemptAt = lastAttemptAt
        self.lastErrorDescription = lastErrorDescription
        self.status = status
    }
}

public protocol CredentialsStore: Sendable {
    func save(session: ProviderSession, for accountID: MailAccountID) throws
    func load(accountID: MailAccountID) throws -> ProviderSession?
    func delete(accountID: MailAccountID) throws
}

public protocol MailStore: Sendable {
    func listAccounts() async throws -> [MailAccount]
    func listThreads(query: ThreadListQuery) async throws -> [MailThread]
    func countThreads(query: ThreadListQuery) async throws -> Int
    func loadThread(id: MailThreadID) async throws -> MailThreadDetail?
    func loadCheckpoint(accountID: MailAccountID) async throws -> SyncCheckpoint?
    func saveAccount(_ account: MailAccount) async throws
    func saveMailboxes(_ mailboxes: [MailboxRef]) async throws
    func upsertThreadDetails(_ details: [MailThreadDetail], checkpoint: SyncCheckpoint?) async throws
    func enqueue(_ mutation: MailMutation) async throws -> UUID
    func queuedMutation(id: UUID) async throws -> QueuedMailMutation?
    func hasPendingQueuedMutations(accountID: MailAccountID) async throws -> Bool
    func loadReadyQueuedMutations(asOf: Date, limit: Int) async throws -> [QueuedMailMutation]
    func nextQueuedMutationAttemptDate() async throws -> Date?
    func completeQueuedMutation(id: UUID) async throws
    func markQueuedMutationForRetry(id: UUID, errorDescription: String, retryCount: Int, nextAttemptAt: Date) async throws
    func failQueuedMutation(id: UUID, errorDescription: String) async throws
    func applyOptimistic(_ mutation: MailMutation) async throws
    func saveSyncState(accountID: MailAccountID, _ state: MailAccountSyncState) async throws
    func listMailboxes(accountID: MailAccountID?) async throws -> [MailboxRef]
    func evictColdBodies(maxHotThreads: Int, maxAge: TimeInterval) async throws
    func saveDraft(_ draft: OutgoingDraft) async throws
    func listDrafts() async throws -> [OutgoingDraft]
    func deleteDraft(id: UUID) async throws
    func seedDemoDataIfNeeded() async throws
    func removeAccount(accountID: MailAccountID) async throws
}

public protocol MailWorkspace: Sendable {
    func changes() async -> AsyncStream<Int>
    func start() async
    func setForegroundActive(_ isActive: Bool) async
    func connectAccount(kind: ProviderKind) async throws
    func reconnectAccount(accountID: MailAccountID) async throws
    func listAccounts() async throws -> [MailAccount]
    func listThreads(query: ThreadListQuery) async throws -> [MailThread]
    func countThreads(query: ThreadListQuery) async throws -> Int
    func loadThread(id: MailThreadID) async throws -> MailThreadDetail?
    func listMailboxes(accountID: MailAccountID?) async throws -> [MailboxRef]
    func refreshAll() async
    func perform(_ mutation: MailMutation) async throws
    func send(_ draft: OutgoingDraft) async throws
    func seedDemoDataIfNeeded() async throws
    func removeAccount(accountID: MailAccountID) async throws
    func saveDraft(_ draft: OutgoingDraft) async throws
    func listDrafts() async throws -> [OutgoingDraft]
    func deleteDraft(id: UUID) async throws
    func handleRedirectURL(_ url: URL) async -> Bool
    func updateMailboxVisibility(mailboxID: MailboxID, hidden: Bool) async throws
    func fetchAttachment(_ attachment: MailAttachment) async throws -> Data
}
