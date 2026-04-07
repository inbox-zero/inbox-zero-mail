import AppKit
import Foundation
import MailCore
import ProviderCore

enum GmailThreadFetchMode: Sendable, Equatable {
    case full
    case metadata
}

public struct GmailProviderConfiguration: Sendable {
    public var environment: ProviderEnvironment
    public var clientID: String
    public var clientSecret: String?
    public var emulatorClientSecret: String
    public var redirectURL: URL
    public var scopes: [String]
    public var emulatorAccounts: [String]
    public var emulatorAutoEmail: String?
    public var presentingWindowProvider: @MainActor @Sendable () -> NSWindow?

    public init(
        environment: ProviderEnvironment,
        clientID: String,
        clientSecret: String? = nil,
        emulatorClientSecret: String = "inbox-zero-google-secret",
        redirectURL: URL,
        scopes: [String] = [
            "openid",
            "email",
            "profile",
            "https://www.googleapis.com/auth/gmail.modify",
        ],
        emulatorAccounts: [String] = [],
        emulatorAutoEmail: String? = nil,
        presentingWindowProvider: @escaping @MainActor @Sendable () -> NSWindow? = { nil }
    ) {
        self.environment = environment
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.emulatorClientSecret = emulatorClientSecret
        self.redirectURL = redirectURL
        self.scopes = scopes
        self.emulatorAccounts = emulatorAccounts
        self.emulatorAutoEmail = emulatorAutoEmail
        self.presentingWindowProvider = presentingWindowProvider
    }

    public static func production(
        clientID: String,
        clientSecret: String? = nil,
        redirectURL: URL,
        presentingWindowProvider: @escaping @MainActor @Sendable () -> NSWindow? = { nil }
    ) -> Self {
        .init(
            environment: .production(
                apiBaseURL: URL(string: "https://gmail.googleapis.com")!,
                authBaseURL: URL(string: "https://accounts.google.com")!,
                userInfoURL: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")
            ),
            clientID: clientID,
            clientSecret: clientSecret,
            redirectURL: redirectURL,
            presentingWindowProvider: presentingWindowProvider
        )
    }
}

public final class GmailProvider: NSObject, @unchecked Sendable, MailProvider {
    public let kind: ProviderKind = .gmail
    public let environment: ProviderEnvironment

    private let configuration: GmailProviderConfiguration
    private let httpClient: HTTPClient
    private let syncMetadataCache = GmailSyncMetadataCache()

    public init(
        configuration: GmailProviderConfiguration,
        httpClient: HTTPClient = .init()
    ) {
        self.configuration = configuration
        self.environment = configuration.environment
        self.httpClient = httpClient
        super.init()
    }

    @MainActor
    public func authorize() async throws -> ProviderSession {
        if environment.kind == .emulator {
            return try await authorizeEmulator()
        }

        guard configuration.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw MailProviderError.missingConfiguration(
                "Live Gmail OAuth is not configured. Set INBOX_ZERO_GMAIL_CLIENT_ID in your Xcode scheme environment variables or release pipeline. Use a Desktop app credential from Google Cloud Console — never a Web app credential."
            )
        }

        guard let authBaseURL = environment.authBaseURL else {
            throw MailProviderError.missingConfiguration("Gmail authBaseURL is missing.")
        }

        guard let presentingWindow = configuration.presentingWindowProvider() else {
            throw MailProviderError.missingConfiguration("A presenting window is required for Gmail OAuth.")
        }

        // Google Desktop OAuth clients require loopback redirects, not custom URI schemes.
        let authorizationPayload = try await authorizeWithLoopback(
            .init(
                providerDisplayName: "Gmail",
                clientID: configuration.clientID,
                clientSecret: configuration.clientSecret,
                scopes: configuration.scopes,
                authorizationEndpoint: authBaseURL.appendingPathComponent("o/oauth2/v2/auth"),
                tokenEndpoint: authBaseURL.appendingPathComponent("o/oauth2/token"),
                additionalParameters: [
                    "access_type": "offline",
                    "prompt": "consent",
                ],
                presentingWindow: presentingWindow
            )
        )

        let accessToken = authorizationPayload.accessToken
        guard accessToken.isEmpty == false else {
            throw MailProviderError.transport("Google OAuth completed without an access token.")
        }

        let profile = try await fetchProfile(
            accessToken: accessToken,
            fallbackEmail: ""
        )

        return ProviderSession(
            providerKind: .gmail,
            providerAccountID: profile.providerAccountID,
            emailAddress: profile.emailAddress,
            displayName: profile.displayName,
            accessToken: accessToken,
            refreshToken: authorizationPayload.refreshToken,
            idToken: authorizationPayload.idToken,
            expirationDate: authorizationPayload.expirationDate,
            scopes: configuration.scopes
        )
    }

    @MainActor
    public func handleRedirectURL(_ url: URL) -> Bool {
        false
    }

    public func restoreSession(_ session: ProviderSession) async throws -> ProviderSession {
        guard session.accessToken.isEmpty == false else {
            throw MailProviderError.unauthorized
        }

        // Token still valid (with 60s buffer to avoid mid-request expiry)
        if let expirationDate = session.expirationDate, expirationDate > Date().addingTimeInterval(60) {
            return session
        }

        guard let refreshToken = session.refreshToken else {
            throw MailProviderError.unauthorized
        }

        return try await refreshAccessToken(session: session, refreshToken: refreshToken)
    }

    public func listMailboxes(session: ProviderSession, accountID: MailAccountID) async throws -> [MailboxRef] {
        var request = URLRequest(url: environment.apiBaseURL.appending(path: "/gmail/v1/users/me/labels"))
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")

        let response = try await httpClient.decode(GmailLabelListResponse.self, from: request)
        return response.labels.map { $0.asMailbox(accountID: accountID) }
    }

    /// Fetches individual label details to get labelListVisibility (not returned by labels.list).
    /// Returns only user labels with their visibility resolved.
    public func fetchLabelVisibility(session: ProviderSession, accountID: MailAccountID) async throws -> [MailboxRef] {
        let listRequest = URLRequest(url: environment.apiBaseURL.appending(path: "/gmail/v1/users/me/labels"))
        var req = listRequest
        req.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        let listResponse = try await httpClient.decode(GmailLabelListResponse.self, from: req)
        let userLabelIDs = listResponse.labels.filter { $0.type != "system" }.map(\.id)

        // Fetch in batches of 5 to avoid Gmail API rate limits
        return try await withThrowingTaskGroup(of: MailboxRef.self) { group in
            var index = 0
            var results: [MailboxRef] = []
            for labelID in userLabelIDs {
                group.addTask {
                    let label = try await self.fetchLabel(accessToken: session.accessToken, labelID: labelID)
                    return label.asMailbox(accountID: accountID)
                }
                index += 1
                if index % 5 == 0 {
                    for try await ref in group { results.append(ref) }
                }
            }
            for try await ref in group { results.append(ref) }
            return results
        }
    }

    public func syncPage(session: ProviderSession, accountID: MailAccountID, request: MailSyncRequest) async throws -> MailSyncPage {
        let profile = try await cachedProfile(session: session, accountID: accountID)
        let mailboxes = try await cachedMailboxes(session: session, accountID: accountID)
        let mailboxLookup = Dictionary(uniqueKeysWithValues: mailboxes.map { ($0.providerMailboxID, $0) })

        let threadFetchPlans: [String: GmailHistoryThreadFetchPlan]
        let nextPageToken: String?
        let checkpointPayload: String?
        let isBackfillComplete: Bool

        switch request.mode {
        case .initial:
            let response = try await listThreads(accessToken: session.accessToken, labelIDs: ["INBOX"], pageToken: nil, maxResults: request.limit)
            threadFetchPlans = Dictionary(uniqueKeysWithValues: (response.threads?.map(\.id) ?? []).map { ($0, .full) })
            nextPageToken = response.nextPageToken
            checkpointPayload = normalizedHistoryID(response.historyId)
            isBackfillComplete = response.nextPageToken == nil
        case let .backfill(pageToken):
            let response = try await listThreads(accessToken: session.accessToken, labelIDs: ["INBOX"], pageToken: pageToken, maxResults: request.limit)
            threadFetchPlans = Dictionary(uniqueKeysWithValues: (response.threads?.map(\.id) ?? []).map { ($0, .full) })
            nextPageToken = response.nextPageToken
            checkpointPayload = normalizedHistoryID(response.historyId)
            isBackfillComplete = response.nextPageToken == nil
        case let .delta(checkpoint, pageToken):
            guard let historyID = normalizedHistoryID(checkpoint) else {
                throw MailProviderError.invalidCheckpoint
            }
            let response = try await listHistory(
                accessToken: session.accessToken,
                startHistoryID: historyID,
                pageToken: pageToken,
                maxResults: request.limit
            )
            threadFetchPlans = response.threadFetchPlans
            nextPageToken = response.nextPageToken
            checkpointPayload = normalizedHistoryID(response.historyID)
            isBackfillComplete = response.nextPageToken == nil
        }

        let threadIDs = threadFetchPlans.keys.sorted()

        let maxConcurrency = 5
        let threadDetails = try await withThrowingTaskGroup(of: MailThreadDetail.self) { group in
            var results: [MailThreadDetail] = []
            var index = 0

            // Seed the group with up to maxConcurrency tasks
            while index < min(maxConcurrency, threadIDs.count) {
                let threadID = threadIDs[index]
                group.addTask { [self] in
                    try await fetchThreadDetail(
                        session: session,
                        accountID: accountID,
                        providerThreadID: threadID,
                        mailboxLookup: mailboxLookup,
                        primaryEmail: profile.emailAddress,
                        fetchPlan: threadFetchPlans[threadID] ?? .full,
                        checkpointPayload: checkpointPayload
                    )
                }
                index += 1
            }

            // As each task completes, add the next one
            for try await detail in group {
                results.append(detail)
                if index < threadIDs.count {
                    let threadID = threadIDs[index]
                    group.addTask { [self] in
                        try await fetchThreadDetail(
                            session: session,
                            accountID: accountID,
                            providerThreadID: threadID,
                            mailboxLookup: mailboxLookup,
                            primaryEmail: profile.emailAddress,
                            fetchPlan: threadFetchPlans[threadID] ?? .full,
                            checkpointPayload: checkpointPayload
                        )
                    }
                    index += 1
                }
            }

            return results.sorted { $0.thread.lastActivityAt > $1.thread.lastActivityAt }
        }

        return MailSyncPage(
            profile: profile,
            mailboxes: mailboxes,
            threadDetails: threadDetails,
            checkpointPayload: checkpointPayload,
            nextPageToken: nextPageToken,
            isBackfillComplete: isBackfillComplete
        )
    }

    public func fetchThread(session: ProviderSession, accountID: MailAccountID, providerThreadID: String) async throws -> MailThreadDetail {
        let mailboxes = try await cachedMailboxes(session: session, accountID: accountID)
        let lookup = Dictionary(uniqueKeysWithValues: mailboxes.map { ($0.providerMailboxID, $0) })
        let profile = try await cachedProfile(session: session, accountID: accountID)
        return try await fetchThread(
            session: session,
            accountID: accountID,
            providerThreadID: providerThreadID,
            mailboxLookup: lookup,
            primaryEmail: profile.emailAddress
        )
    }

    public func fetchAttachment(session: ProviderSession, accountID: MailAccountID, attachment: MailAttachment) async throws -> Data {
        let path = "/gmail/v1/users/me/messages/\(attachment.messageID.providerMessageID)/attachments/\(attachment.id)"
        var request = URLRequest(url: environment.apiBaseURL.appending(path: path))
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")

        let response = try await httpClient.decode(GmailAttachmentResponse.self, from: request)
        guard let encoded = response.data, let data = Data(base64URLEncoded: encoded) else {
            throw MailProviderError.decoding("Gmail attachment \(attachment.filename) did not contain valid attachment data.")
        }
        return data
    }

    public func apply(session: ProviderSession, mutation: MailMutation) async throws {
        switch mutation {
        case let .archive(threadID):
            try await modifyThread(accessToken: session.accessToken, providerThreadID: threadID.providerThreadID, add: [], remove: ["INBOX"])
        case let .unarchive(threadID):
            try await modifyThread(accessToken: session.accessToken, providerThreadID: threadID.providerThreadID, add: ["INBOX"], remove: [])
        case let .markRead(threadID):
            try await modifyThread(accessToken: session.accessToken, providerThreadID: threadID.providerThreadID, add: [], remove: ["UNREAD"])
        case let .markUnread(threadID):
            try await modifyThread(accessToken: session.accessToken, providerThreadID: threadID.providerThreadID, add: ["UNREAD"], remove: [])
        case let .star(threadID):
            try await modifyThread(accessToken: session.accessToken, providerThreadID: threadID.providerThreadID, add: ["STARRED"], remove: [])
        case let .unstar(threadID):
            try await modifyThread(accessToken: session.accessToken, providerThreadID: threadID.providerThreadID, add: [], remove: ["STARRED"])
        case let .applyMailbox(threadID, mailboxID):
            try await modifyThread(accessToken: session.accessToken, providerThreadID: threadID.providerThreadID, add: [mailboxID.providerMailboxID], remove: [])
        case let .removeMailbox(threadID, mailboxID):
            try await modifyThread(accessToken: session.accessToken, providerThreadID: threadID.providerThreadID, add: [], remove: [mailboxID.providerMailboxID])
        case let .trash(threadID):
            try await modifyThread(accessToken: session.accessToken, providerThreadID: threadID.providerThreadID, add: ["TRASH"], remove: ["INBOX"])
        case let .untrash(threadID):
            try await modifyThread(accessToken: session.accessToken, providerThreadID: threadID.providerThreadID, add: ["INBOX"], remove: ["TRASH"])
        case .snooze, .unsnooze:
            break // Snooze is client-side only — no provider action needed
        case .send:
            break
        }
    }

    public func send(session: ProviderSession, draft: OutgoingDraft) async throws -> SentDraftReceipt {
        if draft.providerDraftID != nil {
            let syncedDraft = try await saveDraft(session: session, draft: draft)
            guard let providerDraftID = syncedDraft.providerDraftID else {
                throw MailProviderError.transport("Gmail returned a saved draft without an ID.")
            }
            let response = try await sendDraft(accessToken: session.accessToken, providerDraftID: providerDraftID)
            return .init(providerMessageID: response.id, providerThreadID: response.threadId)
        }

        let rawMessage = GmailMIMEBuilder.makeRawMessage(from: draft, fromEmail: session.emailAddress)
        var request = URLRequest(url: environment.apiBaseURL.appending(path: "/gmail/v1/users/me/messages/send"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try httpClient.encoder.encode(
            GmailSendRequest(raw: rawMessage, threadId: draft.threadID?.providerThreadID)
        )

        let response = try await httpClient.decode(GmailSendResponse.self, from: request)
        return .init(providerMessageID: response.id, providerThreadID: response.threadId)
    }

    public func saveDraft(session: ProviderSession, draft: OutgoingDraft) async throws -> OutgoingDraft {
        let mailboxes = try await listMailboxes(session: session, accountID: draft.accountID)
        let mailboxLookup = Dictionary(uniqueKeysWithValues: mailboxes.map { ($0.providerMailboxID, $0) })
        let profile = try await fetchProfile(accessToken: session.accessToken, fallbackEmail: session.emailAddress)
        let rawMessage = GmailMIMEBuilder.makeRawMessage(from: draft, fromEmail: session.emailAddress)
        let response = try await upsertDraft(
            accessToken: session.accessToken,
            providerDraftID: draft.providerDraftID,
            rawMessage: rawMessage,
            threadId: draft.threadID?.providerThreadID
        )
        return GmailDraftMapper.draft(
            from: response,
            accountID: draft.accountID,
            mailboxLookup: mailboxLookup,
            primaryEmail: profile.emailAddress,
            preferredID: draft.id
        )
    }

    public func listDrafts(session: ProviderSession, accountID: MailAccountID) async throws -> [OutgoingDraft] {
        let mailboxes = try await listMailboxes(session: session, accountID: accountID)
        let mailboxLookup = Dictionary(uniqueKeysWithValues: mailboxes.map { ($0.providerMailboxID, $0) })
        let profile = try await fetchProfile(accessToken: session.accessToken, fallbackEmail: session.emailAddress)
        let draftIDs = try await listAllDraftIDs(accessToken: session.accessToken)
        let maxConcurrency = 5

        return try await withThrowingTaskGroup(of: OutgoingDraft.self) { group in
            var drafts: [OutgoingDraft] = []
            var index = 0

            while index < min(maxConcurrency, draftIDs.count) {
                let providerDraftID = draftIDs[index]
                group.addTask { [self] in
                    let response = try await fetchDraft(accessToken: session.accessToken, providerDraftID: providerDraftID)
                    return GmailDraftMapper.draft(
                        from: response,
                        accountID: accountID,
                        mailboxLookup: mailboxLookup,
                        primaryEmail: profile.emailAddress
                    )
                }
                index += 1
            }

            for try await draft in group {
                drafts.append(draft)
                if index < draftIDs.count {
                    let providerDraftID = draftIDs[index]
                    group.addTask { [self] in
                        let response = try await fetchDraft(accessToken: session.accessToken, providerDraftID: providerDraftID)
                        return GmailDraftMapper.draft(
                            from: response,
                            accountID: accountID,
                            mailboxLookup: mailboxLookup,
                            primaryEmail: profile.emailAddress
                        )
                    }
                    index += 1
                }
            }

            return drafts.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    public func deleteDraft(session: ProviderSession, providerDraftID: String) async throws {
        try await deleteDraft(accessToken: session.accessToken, providerDraftID: providerDraftID)
    }

    public func updateMailboxVisibility(session: ProviderSession, providerMailboxID: String, hidden: Bool) async throws {
        let visibility = hidden ? "labelHide" : "labelShow"
        try await patchLabel(accessToken: session.accessToken, labelID: providerMailboxID, labelListVisibility: visibility)
    }
}

private struct GmailAuthorizationPayload: Sendable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expirationDate: Date?
    let fallbackEmail: String
}

private struct GmailRefreshTokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
    }
}

private struct GmailEmulatorTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case scope
    }
}

private extension GmailProvider {
    @MainActor
    func authorizeEmulator() async throws -> ProviderSession {
        guard let authBaseURL = environment.authBaseURL else {
            throw MailProviderError.missingConfiguration("Gmail emulator authBaseURL is missing.")
        }

        let selectedEmail = configuration.emulatorAutoEmail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? configuration.emulatorAutoEmail!.trimmingCharacters(in: .whitespacesAndNewlines)
            : try promptForEmulatorEmail()
        let redirectURL = authBaseURL.appending(path: "/oauth/google")

        var authRequest = URLRequest(url: authBaseURL.appending(path: "/o/oauth2/v2/auth/callback"))
        authRequest.httpMethod = "POST"
        authRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        authRequest.httpBody = formURLEncodedBody([
            "email": selectedEmail,
            "redirect_uri": redirectURL.absoluteString,
            "scope": configuration.scopes.joined(separator: " "),
            "client_id": configuration.clientID,
            "state": "",
            "code_challenge": "",
            "code_challenge_method": "",
        ])

        let (_, authResponse) = try await httpClient.session.data(for: authRequest)
        guard let callbackURL = authResponse.url,
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw MailProviderError.transport("The Gmail emulator did not return an authorization code.")
        }

        var tokenRequest = URLRequest(url: authBaseURL.appending(path: "/oauth2/token"))
        tokenRequest.httpMethod = "POST"
        tokenRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        tokenRequest.httpBody = formURLEncodedBody([
            "code": code,
            "client_id": configuration.clientID,
            "client_secret": configuration.emulatorClientSecret,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURL.absoluteString,
        ])

        let token = try await httpClient.decode(GmailEmulatorTokenResponse.self, from: tokenRequest)
        let profile = try await fetchProfile(accessToken: token.accessToken, fallbackEmail: selectedEmail)

        return ProviderSession(
            providerKind: .gmail,
            providerAccountID: profile.providerAccountID,
            emailAddress: profile.emailAddress,
            displayName: profile.displayName,
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            idToken: token.idToken,
            scopes: token.scope?.split(separator: " ").map(String.init) ?? configuration.scopes
        )
    }

    func refreshAccessToken(session: ProviderSession, refreshToken: String) async throws -> ProviderSession {
        guard let authBaseURL = environment.authBaseURL else {
            throw MailProviderError.unauthorized
        }

        var request = URLRequest(url: authBaseURL.appendingPathComponent("o/oauth2/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var params: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": configuration.clientID,
        ]
        if let clientSecret = configuration.clientSecret {
            params["client_secret"] = clientSecret
        }
        request.httpBody = formURLEncodedBody(params)

        let data = try await httpClient.data(for: request)
        let tokenResponse = try httpClient.decoder.decode(GmailRefreshTokenResponse.self, from: data)

        var updated = session
        updated.accessToken = tokenResponse.accessToken
        if let expiresIn = tokenResponse.expiresIn {
            updated.expirationDate = Date().addingTimeInterval(TimeInterval(expiresIn))
        }
        return updated
    }

    @MainActor
    func promptForEmulatorEmail() throws -> String {
        let alert = NSAlert()
        alert.messageText = "Connect Gmail Emulator"
        alert.informativeText = "Choose one of the seeded Gmail accounts or type another seeded address."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let comboBox = NSComboBox(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        comboBox.usesDataSource = false
        comboBox.isEditable = true
        comboBox.addItems(withObjectValues: configuration.emulatorAccounts)
        comboBox.stringValue = configuration.emulatorAccounts.first ?? "alpha.inbox@example.com"
        alert.accessoryView = comboBox

        guard alert.runModal() == .alertFirstButtonReturn else {
            throw CancellationError()
        }

        let selectedEmail = comboBox.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard selectedEmail.isEmpty == false else {
            throw MailProviderError.transport("Choose a Gmail emulator account before continuing.")
        }
        return selectedEmail
    }

    func fetchProfile(accessToken: String, fallbackEmail: String) async throws -> ProviderAccountProfile {
        let profileURL = environment.userInfoURL ?? environment.apiBaseURL.appending(path: "/gmail/v1/users/me/profile")
        var request = URLRequest(url: profileURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let data = try await httpClient.data(for: request)

        if let response = try? httpClient.decoder.decode(GmailUserInfoResponse.self, from: data) {
            let emailAddress = response.email.isEmpty ? fallbackEmail : response.email
            return ProviderAccountProfile(
                providerAccountID: response.sub ?? emailAddress,
                emailAddress: emailAddress,
                displayName: response.name ?? emailAddress
            )
        }

        let response = try httpClient.decoder.decode(GmailProfileResponse.self, from: data)
        let emailAddress = response.emailAddress.isEmpty ? fallbackEmail : response.emailAddress
        return ProviderAccountProfile(
            providerAccountID: emailAddress,
            emailAddress: emailAddress,
            displayName: emailAddress
        )
    }

    func listThreads(accessToken: String, labelIDs: [String], pageToken: String?, maxResults: Int) async throws -> GmailThreadListResponse {
        var components = URLComponents(url: environment.apiBaseURL.appending(path: "/gmail/v1/users/me/threads"), resolvingAgainstBaseURL: false)
        var items = [
            URLQueryItem(name: "maxResults", value: String(maxResults)),
        ]
        items.append(contentsOf: labelIDs.map { URLQueryItem(name: "labelIds", value: $0) })
        if let pageToken {
            items.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        components?.queryItems = items

        var request = URLRequest(url: try requireURL(from: components))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return try await httpClient.decode(GmailThreadListResponse.self, from: request)
    }

    func listHistory(accessToken: String, startHistoryID: String, pageToken: String?, maxResults: Int) async throws -> GmailHistoryResponse {
        var components = URLComponents(url: environment.apiBaseURL.appending(path: "/gmail/v1/users/me/history"), resolvingAgainstBaseURL: false)
        var items = [
            URLQueryItem(name: "startHistoryId", value: startHistoryID),
            URLQueryItem(name: "maxResults", value: String(maxResults)),
            URLQueryItem(
                name: "fields",
                value: "history(id,messagesAdded(message(id,threadId)),messagesDeleted(message(id,threadId)),labelsAdded(message(id,threadId),labelIds),labelsRemoved(message(id,threadId),labelIds)),historyId,nextPageToken"
            ),
        ]
        items.append(contentsOf: [
            URLQueryItem(name: "historyTypes", value: "messageAdded"),
            URLQueryItem(name: "historyTypes", value: "messageDeleted"),
            URLQueryItem(name: "historyTypes", value: "labelAdded"),
            URLQueryItem(name: "historyTypes", value: "labelRemoved"),
        ])
        if let pageToken {
            items.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        components?.queryItems = items

        var request = URLRequest(url: try requireURL(from: components))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            return try await httpClient.decode(GmailHistoryResponse.self, from: request)
        } catch let error as MailProviderError {
            if case .transport(let message) = error, message.contains("404") || message.contains("historyId") {
                throw MailProviderError.invalidCheckpoint
            }
            throw error
        }
    }

    func fetchThread(
        session: ProviderSession,
        accountID: MailAccountID,
        providerThreadID: String,
        mailboxLookup: [String: MailboxRef],
        primaryEmail: String,
        fetchMode: GmailThreadFetchMode = .full
    ) async throws -> MailThreadDetail {
        var components = URLComponents(url: environment.apiBaseURL.appending(path: "/gmail/v1/users/me/threads/\(providerThreadID)"), resolvingAgainstBaseURL: false)
        var queryItems = [URLQueryItem(name: "format", value: fetchMode == .full ? "full" : "metadata")]
        if fetchMode == .metadata {
            queryItems.append(contentsOf: [
                URLQueryItem(
                    name: "fields",
                    value: "id,snippet,historyId,messages(id,threadId,labelIds,snippet,internalDate,payload(headers))"
                ),
                URLQueryItem(name: "metadataHeaders", value: "Subject"),
                URLQueryItem(name: "metadataHeaders", value: "From"),
                URLQueryItem(name: "metadataHeaders", value: "To"),
                URLQueryItem(name: "metadataHeaders", value: "Cc"),
                URLQueryItem(name: "metadataHeaders", value: "Bcc"),
                URLQueryItem(name: "metadataHeaders", value: "Date"),
            ])
        }
        components?.queryItems = queryItems

        var request = URLRequest(url: try requireURL(from: components))
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")

        let response = try await httpClient.decode(GmailThreadResponse.self, from: request)
        return response.asThreadDetail(accountID: accountID, mailboxLookup: mailboxLookup, primaryEmail: primaryEmail)
    }

    func fetchThreadDetail(
        session: ProviderSession,
        accountID: MailAccountID,
        providerThreadID: String,
        mailboxLookup: [String: MailboxRef],
        primaryEmail: String,
        fetchPlan: GmailHistoryThreadFetchPlan,
        checkpointPayload: String?
    ) async throws -> MailThreadDetail {
        switch fetchPlan {
        case .full:
            return try await fetchThread(
                session: session,
                accountID: accountID,
                providerThreadID: providerThreadID,
                mailboxLookup: mailboxLookup,
                primaryEmail: primaryEmail,
                fetchMode: .full
            )
        case .metadata:
            return try await fetchThread(
                session: session,
                accountID: accountID,
                providerThreadID: providerThreadID,
                mailboxLookup: mailboxLookup,
                primaryEmail: primaryEmail,
                fetchMode: .metadata
            )
        case let .incrementalMessageIDs(messageIDs):
            let threadID = MailThreadID(accountID: accountID, providerThreadID: providerThreadID)
            let messages = try await withThrowingTaskGroup(of: MailMessage.self) { group in
                for messageID in messageIDs {
                    group.addTask { [self] in
                        let response = try await fetchMessage(
                            accessToken: session.accessToken,
                            providerMessageID: messageID,
                            format: "full",
                            fields: "id,threadId,historyId,labelIds,snippet,internalDate,payload"
                        )
                        return response.asMailMessage(
                            accountID: accountID,
                            threadID: threadID,
                            mailboxLookup: mailboxLookup,
                            primaryEmail: primaryEmail
                        )
                    }
                }

                var results: [MailMessage] = []
                for try await message in group {
                    results.append(message)
                }
                return results.sorted { ($0.receivedAt ?? $0.sentAt ?? .distantPast) < ($1.receivedAt ?? $1.sentAt ?? .distantPast) }
            }

            return incrementalThreadDetail(
                accountID: accountID,
                providerThreadID: providerThreadID,
                messages: messages,
                syncRevision: checkpointPayload ?? messages.compactMap(\.providerMessageID).last ?? providerThreadID
            )
        }
    }

    func fetchMessage(accessToken: String, providerMessageID: String, format: String, fields: String? = nil) async throws -> GmailMessage {
        var components = URLComponents(url: environment.apiBaseURL.appending(path: "/gmail/v1/users/me/messages/\(providerMessageID)"), resolvingAgainstBaseURL: false)
        var queryItems = [URLQueryItem(name: "format", value: format)]
        if let fields {
            queryItems.append(URLQueryItem(name: "fields", value: fields))
        }
        components?.queryItems = queryItems
        var request = URLRequest(url: try requireURL(from: components))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return try await httpClient.decode(GmailMessage.self, from: request)
    }

    func fetchLabel(accessToken: String, labelID: String) async throws -> GmailLabel {
        var request = URLRequest(url: environment.apiBaseURL.appending(path: "/gmail/v1/users/me/labels/\(labelID)"))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return try await httpClient.decode(GmailLabel.self, from: request)
    }

    func modifyThread(accessToken: String, providerThreadID: String, add: [String], remove: [String]) async throws {
        var request = URLRequest(url: environment.apiBaseURL.appending(path: "/gmail/v1/users/me/threads/\(providerThreadID)/modify"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try httpClient.encoder.encode(GmailModifyRequest(addLabelIds: add, removeLabelIds: remove))
        _ = try await httpClient.data(for: request)
    }

    func listAllDraftIDs(accessToken: String) async throws -> [String] {
        var pageToken: String?
        var draftIDs: [String] = []

        repeat {
            let response = try await listDraftReferences(accessToken: accessToken, pageToken: pageToken)
            draftIDs.append(contentsOf: response.drafts?.map(\.id) ?? [])
            pageToken = response.nextPageToken
        } while pageToken != nil

        return draftIDs
    }

    func listDraftReferences(accessToken: String, pageToken: String?) async throws -> GmailDraftListResponse {
        var components = URLComponents(url: environment.apiBaseURL.appending(path: "/gmail/v1/users/me/drafts"), resolvingAgainstBaseURL: false)
        var queryItems = [URLQueryItem(name: "maxResults", value: "100")]
        if let pageToken {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        components?.queryItems = queryItems
        var request = URLRequest(url: try requireURL(from: components))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return try await httpClient.decode(GmailDraftListResponse.self, from: request)
    }

    func fetchDraft(accessToken: String, providerDraftID: String) async throws -> GmailDraftResponse {
        var components = URLComponents(url: environment.apiBaseURL.appending(path: "/gmail/v1/users/me/drafts/\(providerDraftID)"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "format", value: "full")]
        var request = URLRequest(url: try requireURL(from: components))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return try await httpClient.decode(GmailDraftResponse.self, from: request)
    }

    func upsertDraft(accessToken: String, providerDraftID: String?, rawMessage: String, threadId: String?) async throws -> GmailDraftResponse {
        let path: String
        let httpMethod: String
        if let providerDraftID {
            path = "/gmail/v1/users/me/drafts/\(providerDraftID)"
            httpMethod = "PUT"
        } else {
            path = "/gmail/v1/users/me/drafts"
            httpMethod = "POST"
        }

        var request = URLRequest(url: environment.apiBaseURL.appending(path: path))
        request.httpMethod = httpMethod
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try httpClient.encoder.encode(
            GmailDraftUpsertRequest(message: GmailDraftMessageRequest(raw: rawMessage, threadId: threadId))
        )
        return try await httpClient.decode(GmailDraftResponse.self, from: request)
    }

    func sendDraft(accessToken: String, providerDraftID: String) async throws -> GmailSendResponse {
        var request = URLRequest(url: environment.apiBaseURL.appending(path: "/gmail/v1/users/me/drafts/send"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try httpClient.encoder.encode(GmailDraftSendRequest(id: providerDraftID))
        return try await httpClient.decode(GmailSendResponse.self, from: request)
    }

    func deleteDraft(accessToken: String, providerDraftID: String) async throws {
        var request = URLRequest(url: environment.apiBaseURL.appending(path: "/gmail/v1/users/me/drafts/\(providerDraftID)"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        _ = try await httpClient.data(for: request)
    }

    func patchLabel(accessToken: String, labelID: String, labelListVisibility: String) async throws {
        var request = URLRequest(url: environment.apiBaseURL.appending(path: "/gmail/v1/users/me/labels/\(labelID)"))
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try httpClient.encoder.encode(["labelListVisibility": labelListVisibility])
        _ = try await httpClient.data(for: request)
    }

    func requireURL(from components: URLComponents?) throws -> URL {
        guard let url = components?.url else {
            throw MailProviderError.transport("Failed to build Gmail request URL.")
        }
        return url
    }

    func cachedProfile(session: ProviderSession, accountID: MailAccountID) async throws -> ProviderAccountProfile {
        if let cached = await syncMetadataCache.profile(accountID: accountID, accessToken: session.accessToken) {
            return cached
        }

        let profile = try await fetchProfile(accessToken: session.accessToken, fallbackEmail: session.emailAddress)
        await syncMetadataCache.saveProfile(profile, accountID: accountID, accessToken: session.accessToken)
        return profile
    }

    func cachedMailboxes(session: ProviderSession, accountID: MailAccountID) async throws -> [MailboxRef] {
        if let cached = await syncMetadataCache.mailboxes(accountID: accountID, accessToken: session.accessToken) {
            return cached
        }

        let mailboxes = try await listMailboxes(session: session, accountID: accountID)
        await syncMetadataCache.saveMailboxes(mailboxes, accountID: accountID, accessToken: session.accessToken)
        return mailboxes
    }

    func incrementalThreadDetail(
        accountID: MailAccountID,
        providerThreadID: String,
        messages: [MailMessage],
        syncRevision: String
    ) -> MailThreadDetail {
        let threadID = MailThreadID(accountID: accountID, providerThreadID: providerThreadID)
        let newestMessage = messages.max(by: { ($0.receivedAt ?? $0.sentAt ?? .distantPast) < ($1.receivedAt ?? $1.sentAt ?? .distantPast) })
        let senderNames = Array(NSOrderedSet(array: messages.map(\.sender.displayName))) as? [String] ?? []
        let participantSummary = senderNames.prefix(2).joined(separator: ", ")
        let threadMailboxRefs = Array(Set(messages.flatMap(\.mailboxRefs))).sorted { $0.displayName < $1.displayName }
        let subject = newestMessage?.headers.first(where: { $0.name.caseInsensitiveCompare("Subject") == .orderedSame })?.value ?? "(No subject)"
        let snippet = newestMessage?.snippet ?? ""
        let lastActivityAt = newestMessage?.receivedAt ?? newestMessage?.sentAt ?? .distantPast
        let hasUnread = messages.contains(where: { !$0.isRead })
        let isStarred = messages.contains { $0.mailboxRefs.contains(where: { $0.systemRole == .starred }) }
        let isInInbox = messages.contains { $0.mailboxRefs.contains(where: { $0.systemRole == .inbox }) }

        return MailThreadDetail(
            thread: MailThread(
                id: threadID,
                accountID: accountID,
                providerThreadID: providerThreadID,
                subject: subject,
                participantSummary: participantSummary.isEmpty ? newestMessage?.sender.displayName ?? "" : participantSummary,
                snippet: snippet,
                lastActivityAt: lastActivityAt,
                hasUnread: hasUnread,
                isStarred: isStarred,
                isInInbox: isInInbox,
                mailboxRefs: threadMailboxRefs,
                latestMessageID: newestMessage?.id,
                attachmentCount: messages.reduce(0) { $0 + $1.attachments.count },
                syncRevision: syncRevision
            ),
            messages: messages,
            persistenceMode: .merge
        )
    }

    func normalizedHistoryID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), value.isEmpty == false else {
            return nil
        }
        guard value.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains) else {
            return nil
        }
        return value
    }
}

private actor GmailSyncMetadataCache {
    private struct Entry<Value: Sendable>: Sendable {
        let accessToken: String
        let value: Value
        let expiresAt: Date
    }

    private var profiles: [String: Entry<ProviderAccountProfile>] = [:]
    private var mailboxes: [String: Entry<[MailboxRef]>] = [:]

    func profile(accountID: MailAccountID, accessToken: String, now: Date = Date()) -> ProviderAccountProfile? {
        let key = accountID.rawValue
        guard let entry = profiles[key],
              entry.accessToken == accessToken,
              entry.expiresAt > now else {
            profiles[key] = nil
            return nil
        }
        return entry.value
    }

    func saveProfile(_ profile: ProviderAccountProfile, accountID: MailAccountID, accessToken: String, now: Date = Date()) {
        profiles[accountID.rawValue] = Entry(
            accessToken: accessToken,
            value: profile,
            expiresAt: now.addingTimeInterval(60 * 60)
        )
    }

    func mailboxes(accountID: MailAccountID, accessToken: String, now: Date = Date()) -> [MailboxRef]? {
        let key = accountID.rawValue
        guard let entry = mailboxes[key],
              entry.accessToken == accessToken,
              entry.expiresAt > now else {
            mailboxes[key] = nil
            return nil
        }
        return entry.value
    }

    func saveMailboxes(_ mailboxes: [MailboxRef], accountID: MailAccountID, accessToken: String, now: Date = Date()) {
        self.mailboxes[accountID.rawValue] = Entry(
            accessToken: accessToken,
            value: mailboxes,
            expiresAt: now.addingTimeInterval(10 * 60)
        )
    }
}
