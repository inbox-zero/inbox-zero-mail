import Foundation
import MailCore
import ProviderCore
import Testing
@testable import ProviderGmail

@Test
func base64URLRoundTripPreservesMIMEBodies() {
    let original = "Subject: Demo\r\n\r\nBody"
    let encoded = Data(original.utf8).base64URLEncodedString()
    let decoded = Data(base64URLEncoded: encoded).flatMap { String(data: $0, encoding: .utf8) }

    #expect(decoded == original)
}

@Test
func formURLEncodingEscapesReservedCharacters() {
    let body = formURLEncodedBody([
        "email": "user+tag@gmail.com",
        "code": "abc+123/=&",
        "scope": "openid email",
    ])
    let encoded = String(decoding: body, as: UTF8.self)

    #expect(encoded.contains("email=user%2Btag%40gmail.com"))
    #expect(encoded.contains("code=abc%2B123%2F%3D%26"))
    #expect(encoded.contains("scope=openid+email"))
}

@Test
@MainActor
func liveAuthorizationRequiresAConfiguredClientID() async throws {
    let provider = GmailProvider(
        configuration: .production(
            clientID: "",
            redirectURL: URL(string: "inboxzeromail://oauth/google")!
        )
    )

    do {
        _ = try await provider.authorize()
        Issue.record("Expected live Gmail auth to require a configured client ID.")
    } catch let error as MailProviderError {
        switch error {
        case let .missingConfiguration(message):
            #expect(message.contains("INBOX_ZERO_GMAIL_CLIENT_ID"))
        default:
            Issue.record("Unexpected Gmail provider error: \(error)")
        }
    }
}

@Test
func gmailEmulatorContractCoversSyncMutationsAndSend() async throws {
    guard emulatorTestsEnabled else { return }

    let baseURL = googleBaseURL
    let redirectURL = baseURL.appending(path: "/oauth/google")
    let provider = GmailProvider(
        configuration: GmailProviderConfiguration(
            environment: .emulator(
                apiBaseURL: baseURL,
                authBaseURL: baseURL,
                userInfoURL: baseURL.appending(path: "/oauth2/v2/userinfo")
            ),
            clientID: "inbox-zero-mail-dev",
            redirectURL: redirectURL
        )
    )

    let session = try await googleSession(baseURL: baseURL, redirectURL: redirectURL, email: "alpha.inbox@example.com")
    let accountID = MailAccountID(rawValue: "gmail:alpha.inbox@example.com")

    let mailboxes = try await provider.listMailboxes(session: session, accountID: accountID)
    #expect(mailboxes.contains(where: { $0.providerMailboxID == "Label_ops" && $0.kind == .label }))

    let page = try await provider.syncPage(session: session, accountID: accountID, request: MailSyncRequest(mode: .initial, limit: 10))
    let thread = try #require(page.threadDetails.first(where: { $0.thread.subject == "Release checklist" }))

    #expect(page.profile.emailAddress == "alpha.inbox@example.com")
    #expect(thread.thread.hasUnread == true)
    #expect(thread.thread.isStarred == true)
    #expect(thread.thread.isInInbox == true)

    try await provider.apply(session: session, mutation: .archive(threadID: thread.thread.id))
    let archived = try await provider.fetchThread(session: session, accountID: accountID, providerThreadID: thread.thread.providerThreadID)
    #expect(archived.thread.isInInbox == false)

    try await provider.apply(session: session, mutation: .markRead(threadID: thread.thread.id))
    let readThread = try await provider.fetchThread(session: session, accountID: accountID, providerThreadID: thread.thread.providerThreadID)
    #expect(readThread.thread.hasUnread == false)

    try await provider.apply(session: session, mutation: .unstar(threadID: thread.thread.id))
    let unstarred = try await provider.fetchThread(session: session, accountID: accountID, providerThreadID: thread.thread.providerThreadID)
    #expect(unstarred.thread.isStarred == false)

    let receipt = try await provider.send(
        session: session,
        draft: OutgoingDraft(
            accountID: accountID,
            replyMode: .new,
            toRecipients: [MailParticipant(name: "Ops", emailAddress: "ops@example.com")],
            subject: "Contract test",
            plainBody: "Hello from the Gmail provider contract test."
        )
    )
    #expect(receipt.providerMessageID.isEmpty == false)
}

@Test
func gmailMimeBuilderIncludesPlainHtmlAndQuotedReplySections() {
    let draft = OutgoingDraft(
        accountID: MailAccountID(rawValue: "gmail:test@example.com"),
        replyMode: .reply,
        toRecipients: [MailParticipant(name: "Customer", emailAddress: "customer@example.com")],
        subject: "Re: Rich reply",
        plainBody: "Hello there",
        htmlBody: "<p><strong>Hello</strong> there</p>",
        quotedReply: DraftQuotedReply(
            subject: "Rich reply",
            sender: MailParticipant(name: "Customer", emailAddress: "customer@example.com"),
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            plainBody: "Quoted text",
            htmlBody: "<div>Quoted <em>HTML</em></div>"
        )
    )

    let rawMessage = GmailMIMEBuilder.makeRawMessage(from: draft, fromEmail: "me@example.com")
    let decoded = String(data: Data(base64URLEncoded: rawMessage)!, encoding: .utf8)!

    #expect(decoded.contains("Content-Type: multipart/alternative"))
    #expect(decoded.contains("Content-Type: text/plain; charset=utf-8"))
    #expect(decoded.contains("Content-Type: text/html; charset=utf-8"))
    #expect(decoded.contains("Hello there"))
    #expect(decoded.contains("Quoted text"))
    #expect(decoded.contains("<strong>Hello</strong>"))
    #expect(decoded.contains("<blockquote"))
}

@Test
func deltaSyncCachesProfileAndMailboxMetadataBetweenPolls() async throws {
    let testHost = "cache.example.test"
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [MockGmailURLProtocol.self]
    let urlSession = URLSession(configuration: sessionConfiguration)
    let httpClient = HTTPClient(session: urlSession)
    let provider = GmailProvider(
        configuration: GmailProviderConfiguration(
            environment: .production(
                apiBaseURL: URL(string: "https://\(testHost)")!,
                authBaseURL: URL(string: "https://\(testHost)")!,
                userInfoURL: URL(string: "https://\(testHost)/oauth2/v2/userinfo")!
            ),
            clientID: "test-client",
            redirectURL: URL(string: "http://localhost")!
        ),
        httpClient: httpClient
    )

    await MockGmailURLProtocol.reset(host: testHost)
    await MockGmailURLProtocol.setHandler(host: testHost) { request in
        let url = try #require(request.url)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!

        switch url.path {
        case "/oauth2/v2/userinfo":
            return (response, #"{"email":"delta@example.com","name":"Delta Tester","sub":"acct-1"}"#.data(using: .utf8)!)
        case "/gmail/v1/users/me/labels":
            return (response, #"{"labels":[{"id":"INBOX","name":"Inbox","type":"system"}]}"#.data(using: .utf8)!)
        case "/gmail/v1/users/me/history":
            let historyID = url.query?.contains("startHistoryId=101") == true ? "102" : "101"
            return (response, #"{"history":[],"historyId":"\#(historyID)"}"#.data(using: .utf8)!)
        default:
            Issue.record("Unexpected request: \(url.absoluteString)")
            return (response, Data())
        }
    }

    let providerSession = ProviderSession(
        providerKind: .gmail,
        providerAccountID: "acct-1",
        emailAddress: "delta@example.com",
        displayName: "Delta Tester",
        accessToken: "access-token"
    )
    let accountID = MailAccountID(rawValue: "gmail:delta@example.com")

    _ = try await provider.syncPage(
        session: providerSession,
        accountID: accountID,
        request: MailSyncRequest(mode: .delta(checkpointPayload: "100", pageToken: nil))
    )
    _ = try await provider.syncPage(
        session: providerSession,
        accountID: accountID,
        request: MailSyncRequest(mode: .delta(checkpointPayload: "101", pageToken: nil))
    )

    #expect(await MockGmailURLProtocol.requestCount(host: testHost, path: "/oauth2/v2/userinfo") == 1)
    #expect(await MockGmailURLProtocol.requestCount(host: testHost, path: "/gmail/v1/users/me/labels") == 1)
    #expect(await MockGmailURLProtocol.requestCount(host: testHost, path: "/gmail/v1/users/me/history") == 2)
}

@Test
func labelOnlyDeltaUsesMetadataThreadFetch() async throws {
    let testHost = "metadata.example.test"
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [MockGmailURLProtocol.self]
    let urlSession = URLSession(configuration: sessionConfiguration)
    let httpClient = HTTPClient(session: urlSession)
    let provider = GmailProvider(
        configuration: GmailProviderConfiguration(
            environment: .production(
                apiBaseURL: URL(string: "https://\(testHost)")!,
                authBaseURL: URL(string: "https://\(testHost)")!,
                userInfoURL: URL(string: "https://\(testHost)/oauth2/v2/userinfo")!
            ),
            clientID: "test-client",
            redirectURL: URL(string: "http://localhost")!
        ),
        httpClient: httpClient
    )

    await MockGmailURLProtocol.reset(host: testHost)
    await MockGmailURLProtocol.setHandler(host: testHost) { request in
        let url = try #require(request.url)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!

        switch url.path {
        case "/oauth2/v2/userinfo":
            return (response, #"{"email":"delta@example.com","name":"Delta Tester","sub":"acct-1"}"#.data(using: .utf8)!)
        case "/gmail/v1/users/me/labels":
            return (response, #"{"labels":[{"id":"INBOX","name":"Inbox","type":"system"},{"id":"STARRED","name":"Starred","type":"system"}]}"#.data(using: .utf8)!)
        case "/gmail/v1/users/me/history":
            return (
                response,
                #"{"history":[{"labelsAdded":[{"message":{"id":"message-1","threadId":"thread-1"},"labelIds":["STARRED"]}]}],"historyId":"101"}"#.data(using: .utf8)!
            )
        case "/gmail/v1/users/me/threads/thread-1":
            return (
                response,
                #"{"id":"thread-1","snippet":"Updated snippet","historyId":"101","messages":[{"id":"message-1","threadId":"thread-1","labelIds":["INBOX","STARRED"],"payload":{"headers":[{"name":"Subject","value":"Release checklist"},{"name":"From","value":"Ops <ops@example.com>"},{"name":"To","value":"delta@example.com"},{"name":"Date","value":"Tue, 07 Apr 2026 10:00:00 +0000"}]}}]}"#.data(using: .utf8)!
            )
        default:
            Issue.record("Unexpected request: \(url.absoluteString)")
            return (response, Data())
        }
    }

    let providerSession = ProviderSession(
        providerKind: .gmail,
        providerAccountID: "acct-1",
        emailAddress: "delta@example.com",
        displayName: "Delta Tester",
        accessToken: "access-token"
    )
    let accountID = MailAccountID(rawValue: "gmail:delta@example.com")

    let page = try await provider.syncPage(
        session: providerSession,
        accountID: accountID,
        request: MailSyncRequest(mode: .delta(checkpointPayload: "100", pageToken: nil))
    )

    let thread = try #require(page.threadDetails.first)
    #expect(thread.thread.isStarred == true)
    #expect(thread.messages.first?.plainBody == nil)
    let requests = await MockGmailURLProtocol.requests(host: testHost, path: "/gmail/v1/users/me/threads/thread-1")
    let threadURL = try #require(requests.first?.url)
    let queryItems = URLComponents(url: threadURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(queryItems.contains(URLQueryItem(name: "format", value: "metadata")))
    #expect(queryItems.contains(URLQueryItem(name: "metadataHeaders", value: "Subject")))
}

@Test
func messageAddedDeltaUsesMessageFetchInsteadOfFullThreadFetch() async throws {
    let testHost = "incremental.example.test"
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [MockGmailURLProtocol.self]
    let urlSession = URLSession(configuration: sessionConfiguration)
    let httpClient = HTTPClient(session: urlSession)
    let provider = GmailProvider(
        configuration: GmailProviderConfiguration(
            environment: .production(
                apiBaseURL: URL(string: "https://\(testHost)")!,
                authBaseURL: URL(string: "https://\(testHost)")!,
                userInfoURL: URL(string: "https://\(testHost)/oauth2/v2/userinfo")!
            ),
            clientID: "test-client",
            redirectURL: URL(string: "http://localhost")!
        ),
        httpClient: httpClient
    )

    await MockGmailURLProtocol.reset(host: testHost)
    await MockGmailURLProtocol.setHandler(host: testHost) { request in
        let url = try #require(request.url)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!

        switch url.path {
        case "/oauth2/v2/userinfo":
            return (response, #"{"email":"delta@example.com","name":"Delta Tester","sub":"acct-1"}"#.data(using: .utf8)!)
        case "/gmail/v1/users/me/labels":
            return (response, #"{"labels":[{"id":"INBOX","name":"Inbox","type":"system"},{"id":"UNREAD","name":"Unread","type":"system"}]}"#.data(using: .utf8)!)
        case "/gmail/v1/users/me/history":
            return (
                response,
                #"{"history":[{"messagesAdded":[{"message":{"id":"message-1","threadId":"thread-1"}}]}],"historyId":"101"}"#.data(using: .utf8)!
            )
        case "/gmail/v1/users/me/messages/message-1":
            return (
                response,
                #"{"id":"message-1","threadId":"thread-1","historyId":"101","labelIds":["INBOX","UNREAD"],"snippet":"New reply","internalDate":"1712484000000","payload":{"headers":[{"name":"Subject","value":"Release checklist"},{"name":"From","value":"Ops <ops@example.com>"},{"name":"To","value":"delta@example.com"},{"name":"Date","value":"Tue, 07 Apr 2026 10:00:00 +0000"}],"body":{"size":0}}}"#.data(using: .utf8)!
            )
        default:
            Issue.record("Unexpected request: \(url.absoluteString)")
            return (response, Data())
        }
    }

    let providerSession = ProviderSession(
        providerKind: .gmail,
        providerAccountID: "acct-1",
        emailAddress: "delta@example.com",
        displayName: "Delta Tester",
        accessToken: "access-token"
    )
    let accountID = MailAccountID(rawValue: "gmail:delta@example.com")

    let page = try await provider.syncPage(
        session: providerSession,
        accountID: accountID,
        request: MailSyncRequest(mode: .delta(checkpointPayload: "100", pageToken: nil))
    )

    let detail = try #require(page.threadDetails.first)
    #expect(detail.persistenceMode == .merge)
    #expect(detail.messages.map(\.providerMessageID) == ["message-1"])
    #expect(await MockGmailURLProtocol.requestCount(host: testHost, path: "/gmail/v1/users/me/messages/message-1") == 1)
    #expect(await MockGmailURLProtocol.requestCount(host: testHost, path: "/gmail/v1/users/me/threads/thread-1") == 0)
}

@Test
func historyResponseClassifiesMessageAddedAsIncremental() throws {
    let data = #"{"history":[{"messagesAdded":[{"message":{"id":"message-1","threadId":"thread-1"}}]}],"historyId":"101"}"#.data(using: .utf8)!
    let response = try JSONDecoder().decode(GmailHistoryResponse.self, from: data)
    #expect(response.threadFetchPlans["thread-1"] == .incrementalMessageIDs(["message-1"]))
}

private var emulatorTestsEnabled: Bool {
    ProcessInfo.processInfo.environment["INBOX_ZERO_RUN_EMULATOR_TESTS"] == "1"
}

private var googleBaseURL: URL {
    URL(string: ProcessInfo.processInfo.environment["INBOX_ZERO_GOOGLE_BASE_URL"] ?? "http://localhost:4402")!
}

private struct GoogleTokenResponse: Decodable {
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

private func googleSession(baseURL: URL, redirectURL: URL, email: String) async throws -> ProviderSession {
    var authRequest = URLRequest(url: baseURL.appending(path: "/o/oauth2/v2/auth/callback"))
    authRequest.httpMethod = "POST"
    authRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    authRequest.httpBody = formURLEncodedBody([
        "email": email,
        "redirect_uri": redirectURL.absoluteString,
        "scope": "openid email profile https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/gmail.send",
        "client_id": "inbox-zero-mail-dev",
        "state": "",
        "code_challenge": "",
        "code_challenge_method": "",
    ])

    let (_, authResponse) = try await URLSession.shared.data(for: authRequest)
    let authURL = try #require(authResponse.url)
    let authComponents = try #require(URLComponents(url: authURL, resolvingAgainstBaseURL: false))
    let code = try #require(authComponents.queryItems?.first(where: { $0.name == "code" })?.value)

    var tokenRequest = URLRequest(url: baseURL.appending(path: "/oauth2/token"))
    tokenRequest.httpMethod = "POST"
    tokenRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    tokenRequest.httpBody = formURLEncodedBody([
        "code": code,
        "client_id": "inbox-zero-mail-dev",
        "client_secret": "inbox-zero-google-secret",
        "grant_type": "authorization_code",
        "redirect_uri": redirectURL.absoluteString,
    ])

    let (tokenData, _) = try await URLSession.shared.data(for: tokenRequest)
    let token = try JSONDecoder().decode(GoogleTokenResponse.self, from: tokenData)

    return ProviderSession(
        providerKind: .gmail,
        providerAccountID: email,
        emailAddress: email,
        displayName: email,
        accessToken: token.accessToken,
        refreshToken: token.refreshToken,
        idToken: token.idToken,
        scopes: token.scope?.split(separator: " ").map(String.init) ?? []
    )
}

private final class MockGmailURLProtocol: URLProtocol, @unchecked Sendable {
    private static let store = MockGmailURLProtocolStore()

    static func reset(host: String) async {
        await store.reset(host: host)
    }

    static func setHandler(host: String, _ handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) async {
        await store.setHandler(host: host, handler)
    }

    static func requestCount(host: String, path: String) async -> Int {
        await store.requestCount(for: key(host: host, path: path))
    }

    static func requests(host: String, path: String) async -> [URLRequest] {
        await store.requests(for: key(host: host, path: path))
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        Task {
            do {
                await Self.store.recordRequest(
                    key: Self.key(host: url.host ?? "", path: url.path),
                    request: request
                )
                guard let handler = await Self.store.handler(for: url.host ?? "") else {
                    throw URLError(.badServerResponse)
                }
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}

    private static func key(host: String, path: String) -> String {
        "\(host)\(path)"
    }
}

private actor MockGmailURLProtocolStore {
    private var handlersByHost: [String: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)] = [:]
    private var requestCounts: [String: Int] = [:]
    private var requestsByPath: [String: [URLRequest]] = [:]

    func reset(host: String) {
        handlersByHost[host] = nil
        let prefix = "\(host)"
        requestCounts = requestCounts.filter { $0.key.hasPrefix(prefix) == false }
        requestsByPath = requestsByPath.filter { $0.key.hasPrefix(prefix) == false }
    }

    func setHandler(host: String, _ handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) {
        handlersByHost[host] = handler
    }

    func handler(for host: String) -> (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
        handlersByHost[host]
    }

    func recordRequest(key: String, request: URLRequest) {
        requestCounts[key, default: 0] += 1
        requestsByPath[key, default: []].append(request)
    }

    func requestCount(for path: String) -> Int {
        requestCounts[path, default: 0]
    }

    func requests(for path: String) -> [URLRequest] {
        requestsByPath[path, default: []]
    }
}
