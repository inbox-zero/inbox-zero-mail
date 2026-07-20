import AppKit
import Foundation
import MailCore
import ProviderCore

enum OutlookRequestSecurity {
    static func paginationURL(from token: String, trustedBaseURL: URL) throws -> URL {
        guard let url = URL(string: token) else {
            throw MailProviderError.transport("Outlook returned an invalid pagination URL.")
        }

        guard matchesTrustedHost(url, trustedBaseURL: trustedBaseURL) else {
            throw MailProviderError.transport("Outlook pagination URL pointed at an untrusted host.")
        }

        return url
    }

    private static func matchesTrustedHost(_ url: URL, trustedBaseURL: URL) -> Bool {
        guard
            let urlScheme = url.scheme?.lowercased(),
            let trustedScheme = trustedBaseURL.scheme?.lowercased(),
            let urlHost = url.host?.lowercased(),
            let trustedHost = trustedBaseURL.host?.lowercased()
        else {
            return false
        }

        return urlScheme == trustedScheme
            && urlHost == trustedHost
            && normalizedPort(for: url) == normalizedPort(for: trustedBaseURL)
    }

    private static func normalizedPort(for url: URL) -> Int {
        if let port = url.port {
            return port
        }

        switch url.scheme?.lowercased() {
        case "https":
            return 443
        case "http":
            return 80
        default:
            return -1
        }
    }
}

public struct OutlookProviderConfiguration: Sendable {
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
        emulatorClientSecret: String = "inbox-zero-microsoft-secret",
        redirectURL: URL,
        scopes: [String] = [
            "openid",
            "email",
            "profile",
            "offline_access",
            "User.Read",
            "Mail.ReadWrite",
            "Mail.Send",
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
                apiBaseURL: URL(string: "https://graph.microsoft.com")!,
                authBaseURL: URL(string: "https://login.microsoftonline.com/common")!,
                userInfoURL: URL(string: "https://graph.microsoft.com/v1.0/me")!
            ),
            clientID: clientID,
            clientSecret: clientSecret,
            redirectURL: redirectURL,
            presentingWindowProvider: presentingWindowProvider
        )
    }
}

public final class OutlookProvider: NSObject, @unchecked Sendable, MailProvider {
    public let kind: ProviderKind = .microsoft
    public let environment: ProviderEnvironment

    private let configuration: OutlookProviderConfiguration
    private let httpClient: HTTPClient

    public init(configuration: OutlookProviderConfiguration, httpClient: HTTPClient = .init()) {
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
                "Live Outlook OAuth is not configured. Set INBOX_ZERO_OUTLOOK_CLIENT_ID in your Xcode scheme environment variables or release pipeline. Use a Desktop or native-public client from Microsoft Entra, not a confidential web-app secret."
            )
        }

        guard let authBaseURL = environment.authBaseURL else {
            throw MailProviderError.missingConfiguration("Outlook authBaseURL is missing.")
        }

        guard let presentingWindow = configuration.presentingWindowProvider() else {
            throw MailProviderError.missingConfiguration("A presenting window is required for Outlook OAuth.")
        }

        let authorizationPayload = try await authorizeWithLoopback(
            .init(
                providerDisplayName: "Outlook",
                clientID: configuration.clientID,
                clientSecret: configuration.clientSecret,
                scopes: configuration.scopes,
                authorizationEndpoint: authBaseURL.appending(path: "/oauth2/v2.0/authorize"),
                tokenEndpoint: authBaseURL.appending(path: "/oauth2/v2.0/token"),
                additionalParameters: [
                    "prompt": "select_account",
                ],
                presentingWindow: presentingWindow
            )
        )

        guard authorizationPayload.accessToken.isEmpty == false else {
            throw MailProviderError.transport("Outlook OAuth completed without an access token.")
        }

        let profile = try await fetchProfile(accessToken: authorizationPayload.accessToken)

        return ProviderSession(
            providerKind: .microsoft,
            providerAccountID: profile.providerAccountID,
            emailAddress: profile.emailAddress,
            displayName: profile.displayName,
            accessToken: authorizationPayload.accessToken,
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
        if session.accessToken.isEmpty == false,
           let expirationDate = session.expirationDate,
           expirationDate > Date().addingTimeInterval(60) {
            return session
        }

        guard let refreshToken = session.refreshToken else {
            throw MailProviderError.unauthorized
        }

        return try await refreshAccessToken(session: session, refreshToken: refreshToken)
    }

    public func listMailboxes(session: ProviderSession, accountID: MailAccountID) async throws -> [MailboxRef] {
        async let folders = fetchFolders(session: session, accountID: accountID)
        async let categories = fetchCategories(session: session, accountID: accountID)
        return try await folders + categories
    }

    public func syncPage(session: ProviderSession, accountID: MailAccountID, request: MailSyncRequest) async throws -> MailSyncPage {
        let profile = try await fetchProfile(accessToken: session.accessToken)
        let mailboxes = try await listMailboxes(session: session, accountID: accountID)
        let mailboxLookup = Dictionary(uniqueKeysWithValues: mailboxes.map { ($0.providerMailboxID, $0) })
        let messages = try await fetchMessages(session: session, pageToken: pageToken(for: request), limit: request.limit)
        let grouped = Dictionary(grouping: messages.value, by: \.conversationId)

        let threadDetails = grouped.compactMap { conversationID, threadMessages in
            OutlookMapper.threadDetail(
                accountID: accountID,
                conversationID: conversationID,
                messages: threadMessages,
                mailboxLookup: mailboxLookup,
                primaryEmail: profile.emailAddress
            )
        }.sorted { $0.thread.lastActivityAt > $1.thread.lastActivityAt }

        return MailSyncPage(
            profile: profile,
            mailboxes: mailboxes,
            threadDetails: threadDetails,
            checkpointPayload: nil,
            nextPageToken: messages.nextLink,
            isBackfillComplete: messages.nextLink == nil
        )
    }

    public func fetchThread(session: ProviderSession, accountID: MailAccountID, providerThreadID: String) async throws -> MailThreadDetail {
        let profile = try await fetchProfile(accessToken: session.accessToken)
        let mailboxes = try await listMailboxes(session: session, accountID: accountID)
        let mailboxLookup = Dictionary(uniqueKeysWithValues: mailboxes.map { ($0.providerMailboxID, $0) })
        let response = try await fetchConversationMessages(session: session, conversationID: providerThreadID)
        guard let detail = OutlookMapper.threadDetail(
            accountID: accountID,
            conversationID: providerThreadID,
            messages: response,
            mailboxLookup: mailboxLookup,
            primaryEmail: profile.emailAddress
        ) else {
            throw MailProviderError.transport("No Outlook conversation matched \(providerThreadID).")
        }
        return detail
    }

    public func apply(session: ProviderSession, mutation: MailMutation) async throws {
        switch mutation {
        case let .markRead(threadID):
            try await patchConversation(session: session, conversationID: threadID.providerThreadID, payload: ["isRead": true])
        case let .markUnread(threadID):
            try await patchConversation(session: session, conversationID: threadID.providerThreadID, payload: ["isRead": false])
        case let .star(threadID):
            try await patchConversation(session: session, conversationID: threadID.providerThreadID, payload: ["flag": ["flagStatus": "flagged"]])
        case let .unstar(threadID):
            try await patchConversation(session: session, conversationID: threadID.providerThreadID, payload: ["flag": ["flagStatus": "notFlagged"]])
        case let .archive(threadID):
            try await moveConversation(session: session, conversationID: threadID.providerThreadID, destinationID: "archive")
        case let .unarchive(threadID):
            try await moveConversation(session: session, conversationID: threadID.providerThreadID, destinationID: "inbox")
        case let .trash(threadID):
            try await moveConversation(session: session, conversationID: threadID.providerThreadID, destinationID: "deleteditems")
        case let .untrash(threadID):
            try await moveConversation(session: session, conversationID: threadID.providerThreadID, destinationID: "inbox")
        case .snooze, .unsnooze:
            break
        case let .applyMailbox(threadID, mailboxID):
            let mailbox = try await resolveMailbox(session: session, accountID: mailboxID.accountID, mailboxID: mailboxID)
            switch mailbox.kind {
            case .category:
                try await setConversationCategory(
                    session: session,
                    conversationID: threadID.providerThreadID,
                    categoryName: mailbox.displayName,
                    isAdding: true
                )
            case .folder, .system:
                try await moveConversation(session: session, conversationID: threadID.providerThreadID, destinationID: mailbox.providerMailboxID)
            case .label:
                throw MailProviderError.unsupported("Outlook does not support Gmail-style labels.")
            }
        case let .removeMailbox(threadID, mailboxID):
            let mailbox = try await resolveMailbox(session: session, accountID: mailboxID.accountID, mailboxID: mailboxID)
            switch mailbox.kind {
            case .category:
                try await setConversationCategory(
                    session: session,
                    conversationID: threadID.providerThreadID,
                    categoryName: mailbox.displayName,
                    isAdding: false
                )
            case .folder, .system:
                throw MailProviderError.unsupported("Outlook folders are moved between, not removed from a thread.")
            case .label:
                throw MailProviderError.unsupported("Outlook does not support Gmail-style labels.")
            }
        case .send:
            throw MailProviderError.unsupported("Outlook compose is deferred.")
        }
    }

    public func send(session: ProviderSession, draft: OutgoingDraft) async throws -> SentDraftReceipt {
        throw MailProviderError.unsupported("Outlook compose is deferred.")
    }
}

private struct OutlookAuthorizationPayload: Sendable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expirationDate: Date?
}

private struct OutlookTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expiresIn: Int?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresIn = "expires_in"
        case scope
    }
}

private extension OutlookProvider {
    @MainActor
    func authorizeEmulator() async throws -> ProviderSession {
        guard let authBaseURL = environment.authBaseURL else {
            throw MailProviderError.missingConfiguration("Outlook emulator authBaseURL is missing.")
        }

        let selectedEmail = configuration.emulatorAutoEmail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? configuration.emulatorAutoEmail!.trimmingCharacters(in: .whitespacesAndNewlines)
            : try promptForEmulatorEmail()
        let redirectURL = configuration.redirectURL

        var authRequest = URLRequest(url: authBaseURL.appending(path: "/oauth2/v2.0/authorize/callback"))
        authRequest.httpMethod = "POST"
        authRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        authRequest.httpBody = formURLEncodedBody([
            "email": selectedEmail,
            "redirect_uri": redirectURL.absoluteString,
            "scope": configuration.scopes.joined(separator: " "),
            "client_id": configuration.clientID,
            "response_mode": "query",
            "state": "",
            "code_challenge": "",
            "code_challenge_method": "",
        ])

        let (_, authResponse) = try await httpClient.session.data(for: authRequest)
        guard let callbackURL = authResponse.url,
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw MailProviderError.transport("The Outlook emulator did not return an authorization code.")
        }

        var tokenRequest = URLRequest(url: authBaseURL.appending(path: "/oauth2/v2.0/token"))
        tokenRequest.httpMethod = "POST"
        tokenRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        tokenRequest.httpBody = formURLEncodedBody([
            "code": code,
            "client_id": configuration.clientID,
            "client_secret": configuration.emulatorClientSecret,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURL.absoluteString,
        ])

        let token = try await httpClient.decode(OutlookTokenResponse.self, from: tokenRequest)
        let profile = try await fetchProfile(accessToken: token.accessToken)

        return ProviderSession(
            providerKind: .microsoft,
            providerAccountID: profile.providerAccountID,
            emailAddress: profile.emailAddress,
            displayName: profile.displayName,
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            idToken: token.idToken,
            expirationDate: token.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
            scopes: token.scope?.split(separator: " ").map(String.init) ?? configuration.scopes
        )
    }

    func refreshAccessToken(session: ProviderSession, refreshToken: String) async throws -> ProviderSession {
        guard let authBaseURL = environment.authBaseURL else {
            throw MailProviderError.unauthorized
        }

        var request = URLRequest(url: authBaseURL.appending(path: "/oauth2/v2.0/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var params: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": configuration.clientID,
        ]
        if let clientSecret = configuration.resolvedRefreshClientSecret() {
            params["client_secret"] = clientSecret
        }
        request.httpBody = formURLEncodedBody(params)

        let tokenResponse = try await httpClient.decode(OutlookTokenResponse.self, from: request)

        var updated = session
        updated.accessToken = tokenResponse.accessToken
        if let refreshedToken = tokenResponse.refreshToken, refreshedToken.isEmpty == false {
            updated.refreshToken = refreshedToken
        }
        if let expiresIn = tokenResponse.expiresIn {
            updated.expirationDate = Date().addingTimeInterval(TimeInterval(expiresIn))
        }
        return updated
    }

    @MainActor
    func promptForEmulatorEmail() throws -> String {
        let alert = NSAlert()
        alert.messageText = "Connect Outlook Emulator"
        alert.informativeText = "Choose one of the seeded Outlook accounts or type another seeded address."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let comboBox = NSComboBox(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        comboBox.usesDataSource = false
        comboBox.isEditable = true
        comboBox.addItems(withObjectValues: configuration.emulatorAccounts)
        comboBox.stringValue = configuration.emulatorAccounts.first ?? "gamma.outlook@example.com"
        alert.accessoryView = comboBox

        guard alert.runModal() == .alertFirstButtonReturn else {
            throw CancellationError()
        }

        let selectedEmail = comboBox.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard selectedEmail.isEmpty == false else {
            throw MailProviderError.transport("Choose an Outlook emulator account before continuing.")
        }
        return selectedEmail
    }

    func pageToken(for request: MailSyncRequest) -> String? {
        switch request.mode {
        case let .backfill(pageToken):
            return pageToken
        case .initial, .delta:
            return nil
        }
    }

    func fetchProfile(accessToken: String) async throws -> ProviderAccountProfile {
        let profileURL = environment.userInfoURL ?? environment.apiBaseURL.appending(path: "/v1.0/me")
        var request = URLRequest(url: profileURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let response = try await httpClient.decode(OutlookProfileResponse.self, from: request)
        let emailAddress = (response.mail ?? response.userPrincipalName).trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(
            providerAccountID: response.id,
            emailAddress: emailAddress,
            displayName: response.displayName.isEmpty ? emailAddress : response.displayName
        )
    }

    func fetchFolders(session: ProviderSession, accountID: MailAccountID) async throws -> [MailboxRef] {
        var request = URLRequest(url: environment.apiBaseURL.appending(path: "/v1.0/me/mailFolders"))
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        let response = try await httpClient.decode(OutlookFolderListResponse.self, from: request)
        return response.value.map { $0.asMailbox(accountID: accountID) }
    }

    func fetchCategories(session: ProviderSession, accountID: MailAccountID) async throws -> [MailboxRef] {
        var request = URLRequest(url: environment.apiBaseURL.appending(path: "/v1.0/me/outlook/masterCategories"))
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        let response = try await httpClient.decode(OutlookCategoryListResponse.self, from: request)
        return response.value.map { $0.asMailbox(accountID: accountID) }
    }

    func fetchMessages(
        session: ProviderSession,
        pageToken: String?,
        limit: Int,
        conversationID: String? = nil
    ) async throws -> OutlookMessageListResponse {
        if let pageToken {
            let url = try OutlookRequestSecurity.paginationURL(from: pageToken, trustedBaseURL: environment.apiBaseURL)
            var request = URLRequest(url: url)
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            return try await httpClient.decode(OutlookMessageListResponse.self, from: request)
        }

        var components = URLComponents(url: environment.apiBaseURL.appending(path: "/v1.0/me/messages"), resolvingAgainstBaseURL: false)
        var queryItems = [
            URLQueryItem(name: "$top", value: String(limit)),
            URLQueryItem(name: "$orderby", value: "receivedDateTime desc"),
        ]
        if let conversationID {
            queryItems.append(URLQueryItem(name: "$filter", value: "conversationId eq '\(escapedODataString(conversationID))'"))
        }
        components?.queryItems = queryItems

        guard let url = components?.url else {
            throw MailProviderError.transport("Failed to build Outlook messages URL.")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        return try await httpClient.decode(OutlookMessageListResponse.self, from: request)
    }

    func fetchConversationMessages(session: ProviderSession, conversationID: String) async throws -> [OutlookMessage] {
        var pageToken: String?
        var messages: [OutlookMessage] = []

        while true {
            let response = try await fetchMessages(
                session: session,
                pageToken: pageToken,
                limit: 100,
                conversationID: pageToken == nil ? conversationID : nil
            )
            messages.append(contentsOf: response.value)
            guard let nextLink = response.nextLink else { break }
            pageToken = nextLink
        }

        return messages
    }

    func patchConversation(session: ProviderSession, conversationID: String, payload: [String: Any]) async throws {
        let messages = try await fetchConversationMessages(session: session, conversationID: conversationID)
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for message in messages {
                group.addTask { [self] in
                    try await patchMessage(session: session, messageID: message.id, payloadData: payloadData)
                }
            }
            try await group.waitForAll()
        }
    }

    func patchMessage(session: ProviderSession, messageID: String, payload: [String: Any]) async throws {
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        try await patchMessage(session: session, messageID: messageID, payloadData: payloadData)
    }

    func patchMessage(session: ProviderSession, messageID: String, payloadData: Data) async throws {
        var request = URLRequest(url: environment.apiBaseURL.appending(path: "/v1.0/me/messages/\(messageID)"))
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payloadData
        _ = try await httpClient.data(for: request)
    }

    func moveConversation(session: ProviderSession, conversationID: String, destinationID: String) async throws {
        let messages = try await fetchConversationMessages(session: session, conversationID: conversationID)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for message in messages {
                group.addTask { [self] in
                    try await moveMessage(session: session, messageID: message.id, destinationID: destinationID)
                }
            }
            try await group.waitForAll()
        }
    }

    func moveMessage(session: ProviderSession, messageID: String, destinationID: String) async throws {
        var request = URLRequest(url: environment.apiBaseURL.appending(path: "/v1.0/me/messages/\(messageID)/move"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try httpClient.encoder.encode(["destinationId": destinationID])
        _ = try await httpClient.data(for: request)
    }

    func setConversationCategory(
        session: ProviderSession,
        conversationID: String,
        categoryName: String,
        isAdding: Bool
    ) async throws {
        let messages = try await fetchConversationMessages(session: session, conversationID: conversationID)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for message in messages {
                group.addTask { [self] in
                    var categories = Set(message.categories ?? [])
                    if isAdding {
                        categories.insert(categoryName)
                    } else {
                        categories.remove(categoryName)
                    }
                    try await patchMessage(
                        session: session,
                        messageID: message.id,
                        payload: ["categories": categories.sorted()]
                    )
                }
            }
            try await group.waitForAll()
        }
    }

    func resolveMailbox(session: ProviderSession, accountID: MailAccountID, mailboxID: MailboxID) async throws -> MailboxRef {
        let mailboxes = try await listMailboxes(session: session, accountID: accountID)
        if let mailbox = mailboxes.first(where: { $0.id == mailboxID }) {
            return mailbox
        }
        throw MailProviderError.transport("Could not find Outlook mailbox \(mailboxID.providerMailboxID).")
    }

    func escapedODataString(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}

extension OutlookProviderConfiguration {
    func resolvedRefreshClientSecret() -> String? {
        let secret = environment.kind == .emulator ? emulatorClientSecret : clientSecret
        guard let secret, secret.isEmpty == false else { return nil }
        return secret
    }
}
