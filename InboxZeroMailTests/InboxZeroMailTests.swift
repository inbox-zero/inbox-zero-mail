//
//  InboxZeroMailTests.swift
//  InboxZeroMailTests
//
//  Created by Eliezer Steinbock on 28/03/2026.
//

import Testing
import MailData
import MailCore
import ProviderCore
import WebKit
@testable import MailFeatures
@testable import InboxZeroMail

struct InboxZeroMailTests {
    @Test
    func messageDetailTimestampUsesTimeForToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "en_US_POSIX")
        let timeZone = TimeZone(secondsFromGMT: 0)!

        let now = utcDate(year: 2026, month: 3, day: 30, hour: 12, minute: 0)
        let date = utcDate(year: 2026, month: 3, day: 30, hour: 10, minute: 15)

        let formatted = MessageDetailTimestampFormatter.string(
            for: date,
            relativeTo: now,
            calendar: calendar,
            locale: locale,
            timeZone: timeZone
        )

        #expect(formatted == "10:15 AM")
    }

    @Test
    func messageDetailTimestampUsesDayAndMonthForSameYear() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "en_US_POSIX")
        let timeZone = TimeZone(secondsFromGMT: 0)!

        let now = utcDate(year: 2026, month: 3, day: 30, hour: 12, minute: 0)
        let date = utcDate(year: 2026, month: 3, day: 18, hour: 5, minute: 0)

        #expect(
            MessageDetailTimestampFormatter.string(
                for: date,
                relativeTo: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            ) == "18 March"
        )
    }

    @Test
    func messageDetailTimestampIncludesYearForOlderMessages() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "en_US_POSIX")
        let timeZone = TimeZone(secondsFromGMT: 0)!

        let now = utcDate(year: 2026, month: 3, day: 30, hour: 12, minute: 0)
        let date = utcDate(year: 2024, month: 3, day: 30, hour: 0, minute: 0)

        #expect(
            MessageDetailTimestampFormatter.string(
                for: date,
                relativeTo: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            ) == "30 March 2024"
        )
    }

    @Test
    func automaticAvatarColorsAreDistinctAcrossAccounts() {
        let defaults = UserDefaults(suiteName: "InboxZeroMailTests.\(#function)")!
        defaults.removePersistentDomain(forName: "InboxZeroMailTests.\(#function)")

        let accounts = [
            makeAccount(id: "gmail:alpha@example.com", email: "alpha@example.com", name: "Elie Alpha"),
            makeAccount(id: "gmail:beta@example.com", email: "beta@example.com", name: "Elie Beta"),
            makeAccount(id: "gmail:gamma@example.com", email: "gamma@example.com", name: "Elie Gamma"),
        ]

        let colors = accounts.map {
            AppPreferences.effectiveAccountAvatarColorHex(for: $0, accounts: accounts, defaults: defaults)
        }

        #expect(Set(colors).count == colors.count)
    }

    @Test
    func avatarColorOverridePersistsAndCanReset() {
        let suiteName = "InboxZeroMailTests.\(#function)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let account = makeAccount(id: "gmail:override@example.com", email: "override@example.com", name: "Elie Override")
        let automatic = AppPreferences.effectiveAccountAvatarColorHex(for: account, accounts: [account], defaults: defaults)

        AppPreferences.setAccountAvatarColorHex("#123ABC", for: account.id, defaults: defaults)

        #expect(AppPreferences.storedAccountAvatarColorHex(for: account.id, defaults: defaults) == "#123ABC")
        #expect(AppPreferences.effectiveAccountAvatarColorHex(for: account, accounts: [account], defaults: defaults) == "#123ABC")
        #expect(defaults.integer(forKey: AppPreferences.accountAvatarColorsVersionKey) == 1)

        AppPreferences.setAccountAvatarColorHex(nil, for: account.id, defaults: defaults)

        #expect(AppPreferences.storedAccountAvatarColorHex(for: account.id, defaults: defaults) == nil)
        #expect(AppPreferences.effectiveAccountAvatarColorHex(for: account, accounts: [account], defaults: defaults) == automatic)
        #expect(defaults.integer(forKey: AppPreferences.accountAvatarColorsVersionKey) == 2)
    }

    @Test
    @MainActor
    func bootstrapCreatesAppModelAndWorkspace() {
        let bootstrap = AppBootstrap.make()
        #expect(bootstrap.seedDemoData == false)
    }

    @Test
    @MainActor
    func commandPaletteDoesNotListSavedDrafts() async {
        let account = makeAccount(id: "gmail:drafts@example.com", email: "drafts@example.com", name: "Draft Tester")
        let threadID = MailThreadID(accountID: account.id, providerThreadID: "thread-1")
        let draft = OutgoingDraft(
            accountID: account.id,
            replyMode: .reply,
            threadID: threadID,
            toRecipients: [MailParticipant(name: "Elie", emailAddress: "eliesteinbock+assistant@gmail.com")],
            subject: "Fwd: your temporary password",
            plainBody: "Saved body"
        )
        let model = makeWindowModel(
            workspace: StubWorkspace(
                accounts: [account],
                drafts: [draft]
            )
        )

        await model.store.reloadSharedData(reason: .initial)
        let items = commandPaletteBaseItems(model: model)

        #expect(items.contains(where: { $0.category == "Drafts" }) == false)
        #expect(items.contains(where: { $0.title == draft.subject }) == false)
        #expect(items.contains(where: { $0.subtitle.contains("eliesteinbock+assistant@gmail.com") }) == false)
    }

    @Test
    func productionProviderEndpointsIgnoreEnvironmentOverrides() {
        let configuration = AppBootstrap.providerLaunchConfiguration(
            arguments: [],
            environment: [
                "INBOX_ZERO_GOOGLE_BASE_URL": "https://evil.example/google-api",
                "INBOX_ZERO_GOOGLE_AUTH_BASE_URL": "https://evil.example/google-auth",
                "INBOX_ZERO_MICROSOFT_BASE_URL": "https://evil.example/graph",
                "INBOX_ZERO_MICROSOFT_AUTH_BASE_URL": "https://evil.example/login",
            ],
            infoDictionary: [:]
        )

        #expect(configuration.useEmulator == false)
        #expect(configuration.gmailEnvironment.apiBaseURL == URL(string: "https://gmail.googleapis.com")!)
        #expect(configuration.gmailEnvironment.authBaseURL == URL(string: "https://accounts.google.com")!)
        #expect(configuration.outlookEnvironment.apiBaseURL == URL(string: "https://graph.microsoft.com")!)
        #expect(configuration.outlookEnvironment.authBaseURL == URL(string: "https://login.microsoftonline.com/common")!)
        #expect(configuration.availableAccountProviders.isEmpty)
    }

    @Test
    func emulatorProviderEndpointsStillAllowExplicitOverrides() {
        let configuration = AppBootstrap.providerLaunchConfiguration(
            arguments: ["--use-emulator"],
            environment: [
                "INBOX_ZERO_GOOGLE_BASE_URL": "http://127.0.0.1:5502",
                "INBOX_ZERO_GOOGLE_AUTH_BASE_URL": "http://127.0.0.1:6602",
                "INBOX_ZERO_MICROSOFT_BASE_URL": "http://127.0.0.1:5503",
                "INBOX_ZERO_MICROSOFT_AUTH_BASE_URL": "http://127.0.0.1:6603",
            ],
            infoDictionary: [:]
        )

        #expect(configuration.useEmulator == true)
        #expect(configuration.gmailEnvironment.apiBaseURL == URL(string: "http://127.0.0.1:5502")!)
        #expect(configuration.gmailEnvironment.authBaseURL == URL(string: "http://127.0.0.1:6602")!)
        #expect(configuration.outlookEnvironment.apiBaseURL == URL(string: "http://127.0.0.1:5503")!)
        #expect(configuration.outlookEnvironment.authBaseURL == URL(string: "http://127.0.0.1:6603")!)
        #expect(configuration.availableAccountProviders == [.gmail, .microsoft])
    }

    @Test
    func emulatorOAuthDefaultsStaySeparateFromLiveOAuthOverrides() {
        let configuration = AppBootstrap.providerLaunchConfiguration(
            arguments: ["--use-emulator"],
            environment: [
                "INBOX_ZERO_GMAIL_CLIENT_ID": "real-client-id.apps.googleusercontent.com",
                "INBOX_ZERO_GMAIL_CLIENT_SECRET": "real-client-secret",
            ],
            infoDictionary: [:]
        )

        #expect(configuration.useEmulator == true)
        #expect(configuration.gmailClientID == "real-client-id.apps.googleusercontent.com")
        #expect(configuration.gmailClientSecret == "real-client-secret")
        #expect(configuration.gmailEmulatorClientID == "inbox-zero-mail-dev")
        #expect(configuration.gmailEmulatorClientSecret == "inbox-zero-google-secret")
        #expect(configuration.outlookEmulatorClientID == "inbox-zero-mail-dev")
        #expect(configuration.outlookEmulatorClientSecret == "inbox-zero-microsoft-secret")
    }

    @Test
    func configuredProvidersAppearInAddAccountOptions() {
        let configuration = AppBootstrap.providerLaunchConfiguration(
            arguments: [],
            environment: [
                "INBOX_ZERO_GMAIL_CLIENT_ID": "gmail-client-id.apps.googleusercontent.com",
                "INBOX_ZERO_OUTLOOK_CLIENT_ID": "outlook-client-id",
            ],
            infoDictionary: [:]
        )

        #expect(configuration.availableAccountProviders == [.gmail, .microsoft])
        #expect(configuration.outlookClientID == "outlook-client-id")
    }

    @Test
    func loadRemoteImagesDefaultsToOn() {
        #expect(AppPreferences.loadRemoteImagesByDefault == true)
    }

    @Test
    func imageProxyConfigurationDefaultsToInboxZeroHostedProxy() {
        let configuration = try! #require(ImageProxyConfiguration.resolve(environment: [:]))

        #expect(configuration.baseURL == URL(string: "https://img.getinboxzero.com/proxy")!)
        #expect(configuration.signingSecret == nil)
    }

    @Test
    func imageProxyConfigurationNormalizesHostOnlyEnvironmentValues() {
        let configuration = try! #require(ImageProxyConfiguration.resolve(environment: [
            "INBOX_ZERO_IMAGE_PROXY_BASE_URL": "img.getinboxzero.com",
        ]))

        #expect(configuration.baseURL == URL(string: "https://img.getinboxzero.com/proxy")!)
        #expect(configuration.origin == "https://img.getinboxzero.com")
    }

    @Test
    func imageProxyConfigurationCanBeDisabledViaEnvironment() {
        let configuration = ImageProxyConfiguration.resolve(environment: [
            "INBOX_ZERO_IMAGE_PROXY_BASE_URL": "off",
        ])

        #expect(configuration == nil)
    }

    @Test
    func imageProxyConfigurationAlsoAcceptsWebAppEnvironmentVariableName() {
        let configuration = try! #require(ImageProxyConfiguration.resolve(environment: [
            "NEXT_PUBLIC_IMAGE_PROXY_BASE_URL": "https://img.example.com/custom-proxy",
        ]))

        #expect(configuration.baseURL == URL(string: "https://img.example.com/custom-proxy")!)
        #expect(configuration.origin == "https://img.example.com")
    }

    @Test
    func imageProxyConfigurationAcceptsSharedSigningSecretEnvironmentVariableName() {
        let configuration = try! #require(ImageProxyConfiguration.resolve(environment: [
            "IMAGE_PROXY_SIGNING_SECRET": "test-signing-secret",
        ]))

        #expect(configuration.signingSecret == "test-signing-secret")
    }

    @Test
    func imageProxyConfigurationAlsoReadsBundleSettings() {
        let configuration = try! #require(ImageProxyConfiguration.resolve(
            environment: [:],
            infoDictionary: [
                "InboxZeroImageProxyBaseURL": "https://img.example.com/custom-proxy",
                "InboxZeroImageProxySigningSecret": "bundle-signing-secret",
            ]
        ))

        #expect(configuration.baseURL == URL(string: "https://img.example.com/custom-proxy")!)
        #expect(configuration.signingSecret == "bundle-signing-secret")
    }

    @Test
    func imageProxyConfigurationBuildsSignedProxyURLsThatMatchWebAppContract() {
        let configuration = try! #require(ImageProxyConfiguration.normalized(
            from: "https://img.example.com/proxy",
            signingSecret: "test-signing-secret"
        ))

        let proxyURL = URL(string: configuration.proxiedAssetURL(
            for: "https://cdn.example.com/image.png?size=large",
            now: Date(timeIntervalSince1970: 1_775_124_000)
        ))!
        let components = URLComponents(url: proxyURL, resolvingAgainstBaseURL: false)!
        let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(queryItems["u"] == "https://cdn.example.com/image.png?size=large")
        #expect(queryItems["e"] == "1775124300")
        #expect(queryItems["s"] == "JATn8hmgf_0zitefD9AmiPrqSr9NuTuh1tKPXKSrPAA")
    }

    @Test
    func htmlSanitizerRemovesActiveContentEvenWhenRemoteImagesAreAllowed() {
        let html = """
        <script>alert('owned')</script>
        <meta http-equiv="refresh" content="0;url=https://evil.example">
        <link rel="stylesheet" href="https://evil.example/style.css">
        <iframe src="https://evil.example/frame"></iframe>
        <img src="https://cdn.example/logo.png" onerror="stealCookies()">
        """

        let sanitized = HTMLContentSecurity.sanitizedBody(html, allowsRemoteContent: true)

        #expect(sanitized.contains("<script") == false)
        #expect(sanitized.contains("http-equiv=\"refresh\"") == false)
        #expect(sanitized.contains("<link") == false)
        #expect(sanitized.contains("<iframe") == false)
        #expect(sanitized.contains("onerror=") == false)
        #expect(sanitized.contains("https://cdn.example/logo.png"))
    }

    @Test
    func htmlSanitizerRoutesRemoteAssetsThroughConfiguredImageProxy() {
        let html = """
        <img src="https://cdn.example/logo.png?cache=1&amp;size=2">
        <img srcset="https://cdn.example/photo.png 1x, https://cdn.example/photo@2x.png 2x">
        <table background="https://tracker.example/bg.png"></table>
        <div style="background-image: url('https://cdn.example/banner.png')"></div>
        """
        let imageProxy = try! #require(ImageProxyConfiguration.normalized(from: "img.getinboxzero.com"))

        let sanitized = HTMLContentSecurity.sanitizedBody(
            html,
            allowsRemoteContent: true,
            imageProxy: imageProxy
        )

        #expect(
            sanitized.contains(
                "https://img.getinboxzero.com/proxy?u=https%3A%2F%2Fcdn.example%2Flogo.png%3Fcache%3D1%26size%3D2"
            )
        )
        #expect(
            sanitized.contains(
                "https://img.getinboxzero.com/proxy?u=https%3A%2F%2Fcdn.example%2Fphoto.png"
            )
        )
        #expect(
            sanitized.contains(
                "https://img.getinboxzero.com/proxy?u=https%3A%2F%2Fcdn.example%2Fphoto%402x.png"
            )
        )
        #expect(
            sanitized.contains(
                "https://img.getinboxzero.com/proxy?u=https%3A%2F%2Ftracker.example%2Fbg.png"
            )
        )
        #expect(
            sanitized.contains(
                "https://img.getinboxzero.com/proxy?u=https%3A%2F%2Fcdn.example%2Fbanner.png"
            )
        )
    }

    @Test
    func htmlSanitizerRemovesRemoteImageURLsWhenPreferenceIsOff() {
        let html = """
        <img src="https://tracker.example/pixel.gif" srcset="https://tracker.example/pixel-2x.gif 2x">
        <table background="https://tracker.example/bg.png"></table>
        <video poster="https://tracker.example/poster.png"></video>
        """
        let imageProxy = try! #require(ImageProxyConfiguration.normalized(from: "img.getinboxzero.com"))

        let sanitized = HTMLContentSecurity.sanitizedBody(
            html,
            allowsRemoteContent: false,
            imageProxy: imageProxy
        )

        #expect(sanitized.contains("tracker.example") == false)
        #expect(sanitized.contains("img.getinboxzero.com") == false)
        #expect(sanitized.contains("src=\"about:blank\""))
        #expect(sanitized.contains("background=\"about:blank\""))
    }

    @Test
    func htmlSecurityHeadersRestrictRemoteImagesToProxyOriginWhenConfigured() {
        let imageProxy = try! #require(ImageProxyConfiguration.normalized(from: "img.getinboxzero.com"))

        let headers = HTMLContentSecurity.securityHeaders(
            allowsRemoteContent: true,
            imageProxy: imageProxy
        )

        #expect(headers.contains("img-src data: https://img.getinboxzero.com;"))
        #expect(headers.contains("default-src 'none';"))
    }

    @Test
    func htmlNavigationDecisionOnlyAllowsSafeUserInitiatedSchemes() {
        #expect(
            HTMLContentSecurity.navigationDecision(
                url: URL(string: "https://example.com/reset"),
                navigationType: .linkActivated,
                isMainFrame: true
            ) == .openExternally
        )
        #expect(
            HTMLContentSecurity.navigationDecision(
                url: URL(string: "mailto:founder@example.com"),
                navigationType: .linkActivated,
                isMainFrame: true
            ) == .openExternally
        )
        #expect(
            HTMLContentSecurity.navigationDecision(
                url: URL(string: "file:///etc/passwd"),
                navigationType: .linkActivated,
                isMainFrame: true
            ) == .cancel
        )
        #expect(
            HTMLContentSecurity.navigationDecision(
                url: URL(string: "https://evil.example/meta-refresh"),
                navigationType: .other,
                isMainFrame: true
            ) == .cancel
        )
        #expect(
            HTMLContentSecurity.navigationDecision(
                url: URL(string: "about:blank"),
                navigationType: .other,
                isMainFrame: true
            ) == .allowInWebView
        )
        #expect(
            HTMLContentSecurity.navigationDecision(
                url: URL(string: "https://evil.example/frame"),
                navigationType: .other,
                isMainFrame: false
            ) == .cancel
        )
    }

    @Test
    func htmlQuotedContentDetectorFindsCommonQuotedMarkup() {
        let html = """
        <p>Latest update</p>
        <div class="gmail_quote">
            <blockquote>Older thread</blockquote>
        </div>
        """

        #expect(HTMLQuotedContentDetector.containsQuotedContent(html))
    }

    @Test
    func plainTextQuotedContentSplitsReplyChain() {
        let text = """
        Shipping update

        On Mon, Apr 6, 2026 at 9:00 AM Alex wrote:
        > Previous reply
        > More history
        """

        let content = MessagePresentationRules.splitPlainTextQuotedContent(text)

        #expect(content.visibleText == "Shipping update")
        #expect(content.quotedText?.contains("Alex wrote:") == true)
    }

    @Test
    func plainTextQuotedContentKeepsBodyWhenOnlyQuoteExists() {
        let text = """
        > Previous reply
        > More history
        """

        let content = MessagePresentationRules.splitPlainTextQuotedContent(text)

        #expect(content.visibleText == text)
        #expect(content.quotedText == nil)
    }

    @Test
    func messagePresentationStartsExpandedOnlyForUnreadOrFinalMessage() {
        let account = makeAccount(id: "gmail:visibility@example.com", email: "visibility@example.com", name: "Visibility Tester")
        let threadID = MailThreadID(accountID: account.id, providerThreadID: "thread-visibility")
        let readMessage = MailMessage(
            id: MailMessageID(accountID: account.id, providerMessageID: "message-read"),
            threadID: threadID,
            accountID: account.id,
            providerMessageID: "message-read",
            sender: MailParticipant(name: "Alex", emailAddress: "alex@example.com"),
            snippet: "Read body",
            isRead: true,
            isOutgoing: false
        )
        let unreadMessage = MailMessage(
            id: MailMessageID(accountID: account.id, providerMessageID: "message-unread"),
            threadID: threadID,
            accountID: account.id,
            providerMessageID: "message-unread",
            sender: MailParticipant(name: "Alex", emailAddress: "alex@example.com"),
            snippet: "Unread body",
            isRead: false,
            isOutgoing: false
        )

        #expect(MessagePresentationRules.startsExpanded(message: readMessage, isLastMessage: false) == false)
        #expect(MessagePresentationRules.startsExpanded(message: readMessage, isLastMessage: true))
        #expect(MessagePresentationRules.startsExpanded(message: unreadMessage, isLastMessage: false))
    }

    private func makeAccount(id: String, email: String, name: String) -> MailAccount {
        MailAccount(
            id: MailAccountID(rawValue: id),
            providerKind: .gmail,
            providerAccountID: id,
            primaryEmail: email,
            displayName: name,
            capabilities: MailAccountCapabilities(supportsArchive: true, supportsLabels: true)
        )
    }

    private func utcDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return components.date!
    }
}

private actor StubWorkspace: MailWorkspace {
    let accounts: [MailAccount]
    let drafts: [OutgoingDraft]
    let mailboxes: [MailboxRef]

    init(
        accounts: [MailAccount],
        drafts: [OutgoingDraft] = [],
        mailboxes: [MailboxRef] = []
    ) {
        self.accounts = accounts
        self.drafts = drafts
        self.mailboxes = mailboxes
    }

    func changes() async -> AsyncStream<Int> { AsyncStream { $0.finish() } }
    func start() async {}
    func setForegroundActive(_ isActive: Bool) async {}
    func connectAccount(kind: ProviderKind) async throws {}
    func reconnectAccount(accountID: MailAccountID) async throws {}
    func listAccounts() async throws -> [MailAccount] { accounts }
    func listThreads(query: ThreadListQuery) async throws -> [MailThread] { [] }
    func countThreads(query: ThreadListQuery) async throws -> Int { 0 }
    func loadThread(id: MailThreadID) async throws -> MailThreadDetail? { nil }
    func listMailboxes(accountID: MailAccountID?) async throws -> [MailboxRef] { mailboxes }
    func refreshAll() async {}
    func perform(_ mutation: MailMutation) async throws {}
    func send(_ draft: OutgoingDraft) async throws {}
    func seedDemoDataIfNeeded() async throws {}
    func removeAccount(accountID: MailAccountID) async throws {}
    func saveDraft(_ draft: OutgoingDraft) async throws {}
    func listDrafts() async throws -> [OutgoingDraft] { drafts }
    func deleteDraft(id: UUID) async throws {}
    func handleRedirectURL(_ url: URL) async -> Bool { false }
    func updateMailboxVisibility(mailboxID: MailboxID, hidden: Bool) async throws {}
    func fetchAttachment(_ attachment: MailAttachment) async throws -> Data { Data() }
}

@MainActor
private func makeWindowModel(workspace: StubWorkspace) -> WindowModel {
    let store = MailAppStore(workspace: workspace)
    return WindowModel(store: store)
}
