import Foundation
import MailCore
import ProviderCore
import Testing
@testable import ProviderOutlook

@Test
@MainActor
func liveAuthorizationRequiresAConfiguredClientID() async throws {
    let provider = OutlookProvider(
        configuration: .production(
            clientID: "",
            redirectURL: URL(string: "inboxzeromail://oauth/microsoft")!
        )
    )

    do {
        _ = try await provider.authorize()
        Issue.record("Expected live Outlook auth to require a configured client ID.")
    } catch let error as MailProviderError {
        switch error {
        case let .missingConfiguration(message):
            #expect(message.contains("INBOX_ZERO_OUTLOOK_CLIENT_ID"))
        default:
            Issue.record("Unexpected Outlook provider error: \(error)")
        }
    }
}

@Test
func foldersAndCategoriesMapToDistinctMailboxKinds() {
    let accountID = MailAccountID(rawValue: "microsoft:primary@outlook.com")
    let folder = OutlookFolder(id: "inbox", displayName: "Inbox", wellKnownName: "inbox").asMailbox(accountID: accountID)
    let category = OutlookCategory(id: "follow-up", displayName: "Follow Up", color: "preset4").asMailbox(accountID: accountID)

    #expect(folder.kind == .folder)
    #expect(folder.systemRole == .inbox)
    #expect(category.kind == .category)
}

@Test
func paginationURLMustStayOnTrustedHost() throws {
    let trustedBaseURL = try #require(URL(string: "https://graph.microsoft.com"))

    let trustedURL = try OutlookRequestSecurity.paginationURL(
        from: "https://graph.microsoft.com/v1.0/me/messages?$skiptoken=abc",
        trustedBaseURL: trustedBaseURL
    )
    #expect(trustedURL.host() == "graph.microsoft.com")

    #expect(throws: MailProviderError.self) {
        _ = try OutlookRequestSecurity.paginationURL(
            from: "https://evil.example/collect",
            trustedBaseURL: trustedBaseURL
        )
    }
}

@Test
func outlookEmulatorContractCoversMailboxSyncAndFlags() async throws {
    guard emulatorTestsEnabled else { return }

    let baseURL = microsoftBaseURL
    let redirectURL = baseURL.appending(path: "/oauth/microsoft")
    let provider = OutlookProvider(
        configuration: OutlookProviderConfiguration(
            environment: .emulator(
                apiBaseURL: baseURL,
                authBaseURL: baseURL,
                userInfoURL: baseURL.appending(path: "/v1.0/me")
            ),
            clientID: "inbox-zero-mail-dev",
            redirectURL: redirectURL
        )
    )

    let session = try await microsoftSession(baseURL: baseURL, redirectURL: redirectURL, email: "gamma.outlook@example.com")
    let accountID = MailAccountID(rawValue: "microsoft:gamma.outlook@example.com")

    let mailboxes = try await provider.listMailboxes(session: session, accountID: accountID)
    #expect(mailboxes.contains(where: { $0.kind == .folder && $0.systemRole == .inbox }))
    #expect(mailboxes.contains(where: { $0.kind == .category && $0.displayName == "Follow Up" }))

    let page = try await provider.syncPage(session: session, accountID: accountID, request: MailSyncRequest(mode: .initial, limit: 20))
    let thread = try #require(page.threadDetails.first(where: { $0.thread.subject == "Microsoft follow up" }))

    #expect(page.profile.emailAddress == "gamma.outlook@example.com")
    #expect(thread.thread.isInInbox == true)

    try await provider.apply(session: session, mutation: .markRead(threadID: thread.thread.id))
    let readThread = try await provider.fetchThread(session: session, accountID: accountID, providerThreadID: thread.thread.providerThreadID)
    #expect(readThread.thread.hasUnread == false)
}

private var emulatorTestsEnabled: Bool {
    ProcessInfo.processInfo.environment["INBOX_ZERO_RUN_EMULATOR_TESTS"] == "1"
}

private var microsoftBaseURL: URL {
    URL(string: ProcessInfo.processInfo.environment["INBOX_ZERO_MICROSOFT_BASE_URL"] ?? "http://localhost:4403")!
}

private struct MicrosoftTokenResponse: Decodable {
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

private func microsoftSession(baseURL: URL, redirectURL: URL, email: String) async throws -> ProviderSession {
    var authRequest = URLRequest(url: baseURL.appending(path: "/oauth2/v2.0/authorize/callback"))
    authRequest.httpMethod = "POST"
    authRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    authRequest.httpBody = formEncodedBody([
        "email": email,
        "redirect_uri": redirectURL.absoluteString,
        "scope": "openid offline_access Mail.ReadWrite",
        "client_id": "inbox-zero-mail-dev",
        "response_mode": "query",
        "state": "",
        "code_challenge": "",
        "code_challenge_method": "",
    ])

    let (_, authResponse) = try await URLSession.shared.data(for: authRequest)
    let authURL = try #require(authResponse.url)
    let authComponents = try #require(URLComponents(url: authURL, resolvingAgainstBaseURL: false))
    let code = try #require(authComponents.queryItems?.first(where: { $0.name == "code" })?.value)

    var tokenRequest = URLRequest(url: baseURL.appending(path: "/oauth2/v2.0/token"))
    tokenRequest.httpMethod = "POST"
    tokenRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    tokenRequest.httpBody = formEncodedBody([
        "code": code,
        "client_id": "inbox-zero-mail-dev",
        "client_secret": "inbox-zero-microsoft-secret",
        "grant_type": "authorization_code",
        "redirect_uri": redirectURL.absoluteString,
    ])

    let (tokenData, _) = try await URLSession.shared.data(for: tokenRequest)
    let token = try JSONDecoder().decode(MicrosoftTokenResponse.self, from: tokenData)

    return ProviderSession(
        providerKind: .microsoft,
        providerAccountID: email,
        emailAddress: email,
        displayName: email,
        accessToken: token.accessToken,
        refreshToken: token.refreshToken,
        idToken: token.idToken,
        scopes: token.scope?.split(separator: " ").map(String.init) ?? []
    )
}

private func formEncodedBody(_ values: [String: String]) -> Data {
    let body = values
        .map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        .sorted()
        .joined(separator: "&")
    return Data(body.utf8)
}
