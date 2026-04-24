import Foundation
import MailCore
import MailData
import Observation

struct WeakBox<T: AnyObject> {
    weak var value: T?
}

@MainActor
@Observable
public final class MailAppStore {
    public private(set) var accounts: [MailAccount] = []
    public private(set) var mailboxes: [MailboxRef] = []
    public private(set) var savedDrafts: [OutgoingDraft] = []
    public private(set) var isRefreshing = false
    public private(set) var isConnectingAccount = false
    public private(set) var activeWindowID: String?
    public let availableAccountProviders: [ProviderKind]

    let workspace: any MailWorkspace

    private var windowModels: [WeakBox<WindowModel>] = []

    @ObservationIgnored
    private nonisolated(unsafe) var changeTask: Task<Void, Never>?

    /// Called after each shared reload so the app layer can update notifications/badges.
    public var onReload: ((_ reason: MailReloadReason, _ allInboxThreads: [MailThread]) -> Void)?

    public init(
        workspace: any MailWorkspace,
        availableAccountProviders: [ProviderKind] = ProviderKind.allCases
    ) {
        self.workspace = workspace
        self.availableAccountProviders = availableAccountProviders
    }

    deinit {
        changeTask?.cancel()
    }

    // MARK: - Window Registry

    public func register(_ model: WindowModel) {
        windowModels.append(WeakBox(value: model))
        if activeWindowID == nil {
            activeWindowID = model.windowID
        }
    }

    public func unregister(_ model: WindowModel) {
        windowModels.removeAll { $0.value === model || $0.value == nil }
        if activeWindowID == model.windowID {
            activeWindowID = windowModels.compactMap(\.value).first?.windowID
        }
    }

    public func setActiveWindow(windowID: String?) {
        guard let windowID else {
            activeWindowID = nil
            return
        }
        guard windowModels.contains(where: { $0.value?.windowID == windowID }) else { return }
        activeWindowID = windowID
    }

    public func allWindowModels() -> [WindowModel] {
        windowModels.removeAll { $0.value == nil }
        return windowModels.compactMap(\.value)
    }

    public func windowModel(windowID: String?) -> WindowModel? {
        let windows = allWindowModels()
        if let windowID {
            if windowID == "active" {
                return windows.first(where: { $0.windowID == activeWindowID }) ?? windows.first
            }
            return windows.first(where: { $0.windowID == windowID })
        }
        return windows.first(where: { $0.windowID == activeWindowID }) ?? windows.first
    }

    // MARK: - Lifecycle

    public func start(seedDemoData: Bool = false) {
        changeTask?.cancel()
        let workspace = self.workspace
        changeTask = Task { [weak self, workspace] in
            if seedDemoData {
                try? await workspace.seedDemoDataIfNeeded()
            }
            await self?.reloadSharedData(reason: .initial)
            await workspace.start()

            let changes = await workspace.changes()
            for await _ in changes {
                guard Task.isCancelled == false else { break }
                await self?.reloadSharedData(reason: .workspaceChange)
            }
        }
    }

    public func setForegroundActive(_ isActive: Bool) {
        Task {
            await workspace.setForegroundActive(isActive)
        }
    }

    public func refreshAll() {
        Task {
            await workspace.refreshAll()
        }
    }

    // MARK: - Shared Data Reload

    func reloadSharedData(reason: MailReloadReason) async {
        do {
            isRefreshing = true
            accounts = try await workspace.listAccounts()
            let validAccountIDs = Set(accounts.map(\.id))
            windowModels.removeAll { $0.value == nil }
            for ref in windowModels {
                ref.value?.reconcileAccountAvailability(validAccountIDs: validAccountIDs)
            }
            // Reload mailboxes for all accounts (no filter)
            mailboxes = try await workspace.listMailboxes(accountID: nil)
            savedDrafts = (try? await workspace.listDrafts()) ?? []
            isRefreshing = false

            // Notify all windows to reload their threads
            await notifyAllWindows(reason: reason)

            // Update notification badge independently
            await updateNotifications(reason: reason)
        } catch {
            isRefreshing = false
        }
    }

    private func notifyAllWindows(reason: MailReloadReason) async {
        // Clean up dead references
        windowModels.removeAll { $0.value == nil }

        for ref in windowModels {
            await ref.value?.reloadThreads(reason: reason)
        }
    }

    private func updateNotifications(reason: MailReloadReason) async {
        guard let onReload else { return }
        do {
            let notificationQuery = ThreadListQuery(
                tab: .all,
                mailboxScope: .inboxOnly,
                limit: 100
            )
            let allInboxThreads = try await workspace.listThreads(query: notificationQuery)
            onReload(reason, allInboxThreads)
        } catch {
            // Non-critical; silently ignore
        }
    }

    // MARK: - Account Management

    public func connectAccount(kind: ProviderKind) {
        guard availableAccountProviders.contains(kind) else { return }
        guard isConnectingAccount == false else { return }
        isConnectingAccount = true
        Task { [weak self] in
            defer { self?.isConnectingAccount = false }
            guard let self else { return }
            do {
                try await workspace.connectAccount(kind: kind)
                await reloadSharedData(reason: .manual)
            } catch {
                if error is CancellationError { return }
                // AppAuth signals user-cancelled via NSError domain
                // "org.openid.appauth.general" code -3.
                let nsError = error as NSError
                if nsError.domain == "org.openid.appauth.general", nsError.code == -3 { return }
                // Broadcast error to the first window
                windowModels.first(where: { $0.value != nil })?.value?.present(error)
            }
        }
    }

    public func connectGmail() {
        connectAccount(kind: .gmail)
    }

    public func reconnectAccount(accountID: MailAccountID) {
        guard isConnectingAccount == false else { return }
        isConnectingAccount = true
        Task { [weak self] in
            defer { self?.isConnectingAccount = false }
            guard let self else { return }
            do {
                try await workspace.reconnectAccount(accountID: accountID)
                await reloadSharedData(reason: .manual)
            } catch {
                if error is CancellationError { return }
                let nsError = error as NSError
                if nsError.domain == "org.openid.appauth.general", nsError.code == -3 { return }
                windowModels.first(where: { $0.value != nil })?.value?.present(error)
            }
        }
    }

    public func connectDefaultAvailableAccount() {
        guard let kind = availableAccountProviders.first else { return }
        connectAccount(kind: kind)
    }

    public func disconnectAccount(accountID: MailAccountID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await workspace.removeAccount(accountID: accountID)
                await reloadSharedData(reason: .manual)
            } catch {
                windowModels.first(where: { $0.value != nil })?.value?.present(error)
            }
        }
    }

    public func remove(accountID: MailAccountID) {
        disconnectAccount(accountID: accountID)
    }

    public func loadDemoInbox() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await workspace.seedDemoDataIfNeeded()
                await reloadSharedData(reason: .manual)
            } catch {
                windowModels.first(where: { $0.value != nil })?.value?.present(error)
            }
        }
    }

    // MARK: - Mailbox Visibility (shared mutation)

    public func setMailboxHidden(_ mailboxID: MailboxID, hidden: Bool) {
        // Optimistic local update
        if let idx = mailboxes.firstIndex(where: { $0.id == mailboxID }) {
            mailboxes[idx].isHiddenInLabelList = hidden
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await workspace.updateMailboxVisibility(mailboxID: mailboxID, hidden: hidden)
            } catch {
                // Revert on failure
                if let idx = mailboxes.firstIndex(where: { $0.id == mailboxID }) {
                    mailboxes[idx].isHiddenInLabelList = !hidden
                }
                windowModels.first(where: { $0.value != nil })?.value?.present(error)
            }
        }
    }

    // MARK: - Workspace Passthrough

    func perform(_ mutation: MailMutation) async throws {
        try await workspace.perform(mutation)
    }

    func send(_ draft: OutgoingDraft) async throws {
        try await workspace.send(draft)
    }

    func saveDraft(_ draft: OutgoingDraft) async throws {
        try await workspace.saveDraft(draft)
    }

    func deleteDraft(id: UUID) async throws {
        try await workspace.deleteDraft(id: id)
    }

    func loadThreadDetail(for id: MailThreadID) async throws -> MailThreadDetail? {
        try await workspace.loadThread(id: id)
    }

    func listThreads(query: ThreadListQuery) async throws -> [MailThread] {
        try await workspace.listThreads(query: query)
    }

    func countThreads(query: ThreadListQuery) async throws -> Int {
        try await workspace.countThreads(query: query)
    }

    func listMailboxes(accountID: MailAccountID?) async throws -> [MailboxRef] {
        try await workspace.listMailboxes(accountID: accountID)
    }

    func fetchAttachmentData(_ attachment: MailAttachment) async throws -> Data {
        try await workspace.fetchAttachment(attachment)
    }

    public func reloadDrafts() async {
        savedDrafts = (try? await workspace.listDrafts()) ?? []
    }
}
