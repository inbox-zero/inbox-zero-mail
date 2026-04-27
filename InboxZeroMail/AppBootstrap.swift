import AppKit
import Foundation
import MailCore
import MailData
import MailFeatures
import Network
import ProviderCore
import ProviderGmail
import ProviderOutlook

struct ProviderLaunchConfiguration {
    let useEmulator: Bool
    let autoConnectGmailOnLaunch: Bool
    let availableAccountProviders: [ProviderKind]
    let gmailEnvironment: ProviderEnvironment
    let gmailClientID: String
    let gmailClientSecret: String?
    let gmailEmulatorClientID: String
    let gmailEmulatorClientSecret: String
    let gmailRedirectURL: URL
    let emulatorAutoEmail: String?
    let emulatorAccounts: [String]
    let outlookEnvironment: ProviderEnvironment
    let outlookClientID: String
    let outlookClientSecret: String?
    let outlookEmulatorClientID: String
    let outlookEmulatorClientSecret: String
    let outlookRedirectURL: URL
    let outlookEmulatorAutoEmail: String?
    let outlookEmulatorAccounts: [String]
}

struct AppBootstrap {
    let store: MailAppStore
    let workspace: MailWorkspaceController
    let controlPlane: AppControlPlane
    let isControlPlaneEnabled: Bool
    let seedDemoData: Bool
    let autoConnectGmailOnLaunch: Bool
    let isUITesting: Bool
    let debugACPRequest: DebugACPRequest?

    static var isRunningUITests: Bool {
        let processInfo = ProcessInfo.processInfo
        let launchArguments = processInfo.arguments
        let environment = processInfo.environment
        return launchArguments.contains("--ui-testing")
            || environment["INBOX_ZERO_UI_TESTING"] == "1"
            || environment["XCTestConfigurationFilePath"] != nil
    }

    @MainActor
    static func make() -> AppBootstrap {
        let processInfo = ProcessInfo.processInfo
        let launchArguments = processInfo.arguments
        let environment = processInfo.environment
        let previewMode = processInfo.arguments.contains("--seed-demo-data")
        let isUITesting = isRunningUITests
        let configuration = providerLaunchConfiguration(
            arguments: launchArguments,
            environment: environment
        )
        let isControlPlaneEnabled = launchArguments.contains("--enable-control-plane")
            || environment["INBOX_ZERO_ENABLE_CONTROL_PLANE"] == "1"

        let storePath: String
        if previewMode {
            storePath = NSTemporaryDirectory().appending("InboxZeroMail-preview.sqlite")
        } else {
            let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("InboxZeroMail", isDirectory: true)
            try? FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
            storePath = supportURL.appendingPathComponent("mail.sqlite").path
        }

        let store = try! SQLiteMailStore(path: storePath)
        let credentialsStore = SystemCredentialsStore()

        let gmailProvider = GmailProvider(
            configuration: GmailProviderConfiguration(
                environment: configuration.gmailEnvironment,
                clientID: configuration.useEmulator ? configuration.gmailEmulatorClientID : configuration.gmailClientID,
                clientSecret: configuration.useEmulator ? nil : configuration.gmailClientSecret,
                emulatorClientSecret: configuration.gmailEmulatorClientSecret,
                redirectURL: configuration.gmailRedirectURL,
                emulatorAccounts: configuration.emulatorAccounts,
                emulatorAutoEmail: configuration.emulatorAutoEmail,
                presentingWindowProvider: { NSApplication.shared.keyWindow }
            )
        )

        let outlookProvider = OutlookProvider(
            configuration: OutlookProviderConfiguration(
                environment: configuration.outlookEnvironment,
                clientID: configuration.useEmulator ? configuration.outlookEmulatorClientID : configuration.outlookClientID,
                clientSecret: configuration.useEmulator ? nil : configuration.outlookClientSecret,
                emulatorClientSecret: configuration.outlookEmulatorClientSecret,
                redirectURL: configuration.outlookRedirectURL,
                emulatorAccounts: configuration.outlookEmulatorAccounts,
                emulatorAutoEmail: configuration.outlookEmulatorAutoEmail,
                presentingWindowProvider: { NSApplication.shared.keyWindow }
            )
        )

        let workspace = MailWorkspaceController(
            store: store,
            credentialsStore: credentialsStore,
            providers: [
                .gmail: gmailProvider,
                .microsoft: outlookProvider,
            ],
            previewMode: previewMode
        )

        let appStore = MailAppStore(
            workspace: workspace,
            availableAccountProviders: configuration.availableAccountProviders
        )
        let controlPlane = AppControlPlane(store: appStore)
        if isControlPlaneEnabled {
            controlPlane.start()
        }
        return AppBootstrap(
            store: appStore,
            workspace: workspace,
            controlPlane: controlPlane,
            isControlPlaneEnabled: isControlPlaneEnabled,
            seedDemoData: previewMode,
            autoConnectGmailOnLaunch: configuration.autoConnectGmailOnLaunch,
            isUITesting: isUITesting,
            debugACPRequest: debugACPRequest(
                arguments: launchArguments,
                environment: environment
            )
        )
    }

    static func providerLaunchConfiguration(
        arguments: [String],
        environment: [String: String],
        infoDictionary: [String: Any]? = nil
    ) -> ProviderLaunchConfiguration {
        let bundleInfo = infoDictionary ?? Bundle.main.infoDictionary ?? [:]
        let useEmulator = arguments.contains("--seed-demo-data") || arguments.contains("--use-emulator")
        let autoConnectGmailOnLaunch = arguments.contains("--autoconnect-gmail")
            || environment["INBOX_ZERO_AUTOCONNECT_GMAIL"] == "1"

        let gmailAPIBaseURL = resolvedEndpointURL(
            envKey: "INBOX_ZERO_GOOGLE_BASE_URL",
            environment: environment,
            useEmulator: useEmulator,
            fallback: URL(string: useEmulator ? "http://localhost:4402" : "https://gmail.googleapis.com")!
        )
        let gmailAuthBaseURL = resolvedEndpointURL(
            envKey: "INBOX_ZERO_GOOGLE_AUTH_BASE_URL",
            environment: environment,
            useEmulator: useEmulator,
            fallback: URL(string: useEmulator ? gmailAPIBaseURL.absoluteString : "https://accounts.google.com")!
        )
        let outlookAPIBaseURL = resolvedEndpointURL(
            envKey: "INBOX_ZERO_MICROSOFT_BASE_URL",
            environment: environment,
            useEmulator: useEmulator,
            fallback: URL(string: useEmulator ? "http://localhost:4403" : "https://graph.microsoft.com")!
        )
        let outlookAuthBaseURL = resolvedEndpointURL(
            envKey: "INBOX_ZERO_MICROSOFT_AUTH_BASE_URL",
            environment: environment,
            useEmulator: useEmulator,
            fallback: URL(string: useEmulator ? outlookAPIBaseURL.absoluteString : "https://login.microsoftonline.com/common")!
        )

        let gmailEnvironment: ProviderEnvironment = useEmulator
            ? .emulator(
                apiBaseURL: gmailAPIBaseURL,
                authBaseURL: gmailAuthBaseURL,
                userInfoURL: gmailAPIBaseURL.appending(path: "/oauth2/v2/userinfo")
            )
            : .production(
                apiBaseURL: gmailAPIBaseURL,
                authBaseURL: gmailAuthBaseURL,
                userInfoURL: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")
            )
        let outlookEnvironment: ProviderEnvironment = useEmulator
            ? .emulator(
                apiBaseURL: outlookAPIBaseURL,
                authBaseURL: outlookAuthBaseURL,
                userInfoURL: outlookAPIBaseURL.appending(path: "/v1.0/me")
            )
            : .production(
                apiBaseURL: outlookAPIBaseURL,
                authBaseURL: outlookAuthBaseURL,
                userInfoURL: URL(string: "https://graph.microsoft.com/v1.0/me")
            )

        let emulatorAutoEmail = launchArgumentValue(named: "--gmail-emulator-email", in: arguments)
            ?? environment["INBOX_ZERO_GMAIL_EMULATOR_EMAIL"]
        let emulatorAccounts = environment["INBOX_ZERO_GMAIL_EMULATOR_ACCOUNTS"]?
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            ?? ["alpha.inbox@example.com", "beta.inbox@example.com"]
        // Google OAuth "Desktop app" credentials. These are safe to commit per Google's
        // documentation — installed/desktop apps cannot keep secrets, so Google treats
        // them as public identifiers. They are NOT equivalent to web-app client secrets.
        //
        // WARNING: Never replace these with Web Application credentials. Web client
        // secrets are confidential and must not be committed to source control.
        let gmailClientID = trimmedEnvironmentValue(
            for: "INBOX_ZERO_GMAIL_CLIENT_ID",
            environment: environment
        ) ?? resolvedBundleSettingValue(for: "InboxZeroGmailClientID", infoDictionary: bundleInfo) ?? ""
        let gmailClientSecret = trimmedEnvironmentValue(
            for: "INBOX_ZERO_GMAIL_CLIENT_SECRET",
            environment: environment
        ) ?? resolvedBundleSettingValue(for: "InboxZeroGmailClientSecret", infoDictionary: bundleInfo)
        let gmailEmulatorClientID = trimmedEnvironmentValue(
            for: "INBOX_ZERO_GMAIL_EMULATOR_CLIENT_ID",
            environment: environment
        ) ?? "inbox-zero-mail-dev"
        let gmailEmulatorClientSecret = trimmedEnvironmentValue(
            for: "INBOX_ZERO_GMAIL_EMULATOR_CLIENT_SECRET",
            environment: environment
        ) ?? "inbox-zero-google-secret"
        let outlookClientID = trimmedEnvironmentValue(
            for: "INBOX_ZERO_OUTLOOK_CLIENT_ID",
            environment: environment
        ) ?? resolvedBundleSettingValue(for: "InboxZeroOutlookClientID", infoDictionary: bundleInfo) ?? ""
        let outlookClientSecret = trimmedEnvironmentValue(
            for: "INBOX_ZERO_OUTLOOK_CLIENT_SECRET",
            environment: environment
        ) ?? resolvedBundleSettingValue(for: "InboxZeroOutlookClientSecret", infoDictionary: bundleInfo)
        let outlookEmulatorClientID = trimmedEnvironmentValue(
            for: "INBOX_ZERO_OUTLOOK_EMULATOR_CLIENT_ID",
            environment: environment
        ) ?? "inbox-zero-mail-dev"
        let outlookEmulatorClientSecret = trimmedEnvironmentValue(
            for: "INBOX_ZERO_OUTLOOK_EMULATOR_CLIENT_SECRET",
            environment: environment
        ) ?? "inbox-zero-microsoft-secret"
        let outlookEmulatorAutoEmail = launchArgumentValue(named: "--outlook-emulator-email", in: arguments)
            ?? environment["INBOX_ZERO_OUTLOOK_EMULATOR_EMAIL"]
        let outlookEmulatorAccounts = environment["INBOX_ZERO_OUTLOOK_EMULATOR_ACCOUNTS"]?
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            ?? ["gamma.outlook@example.com"]
        let availableAccountProviders: [ProviderKind] = useEmulator
            ? [.gmail, .microsoft]
            : ProviderKind.allCases.filter { kind in
                switch kind {
                case .gmail:
                    return gmailClientID.isEmpty == false
                case .microsoft:
                    return outlookClientID.isEmpty == false
                }
            }

        return ProviderLaunchConfiguration(
            useEmulator: useEmulator,
            autoConnectGmailOnLaunch: autoConnectGmailOnLaunch,
            availableAccountProviders: availableAccountProviders,
            gmailEnvironment: gmailEnvironment,
            gmailClientID: gmailClientID,
            gmailClientSecret: gmailClientSecret,
            gmailEmulatorClientID: gmailEmulatorClientID,
            gmailEmulatorClientSecret: gmailEmulatorClientSecret,
            gmailRedirectURL: URL(
                string: trimmedEnvironmentValue(
                    for: "INBOX_ZERO_GMAIL_REDIRECT_URL",
                    environment: environment
                ) ?? "inboxzeromail://oauth/google"
            )!,
            emulatorAutoEmail: emulatorAutoEmail,
            emulatorAccounts: emulatorAccounts,
            outlookEnvironment: outlookEnvironment,
            outlookClientID: outlookClientID,
            outlookClientSecret: outlookClientSecret,
            outlookEmulatorClientID: outlookEmulatorClientID,
            outlookEmulatorClientSecret: outlookEmulatorClientSecret,
            outlookRedirectURL: URL(
                string: trimmedEnvironmentValue(
                    for: "INBOX_ZERO_OUTLOOK_REDIRECT_URL",
                    environment: environment
                ) ?? "inboxzeromail://oauth/microsoft"
            )!,
            outlookEmulatorAutoEmail: outlookEmulatorAutoEmail,
            outlookEmulatorAccounts: outlookEmulatorAccounts
        )
    }

    static func debugACPRequest(
        arguments: [String],
        environment: [String: String]
    ) -> DebugACPRequest? {
        let prompt = launchArgumentValue(named: "--debug-acp-ask", in: arguments)
            ?? trimmedEnvironmentValue(for: "INBOX_ZERO_DEBUG_ACP_ASK", environment: environment)
        guard let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), prompt.isEmpty == false else {
            return nil
        }

        let executable = launchArgumentValue(named: "--debug-acp-agent", in: arguments)
            ?? trimmedEnvironmentValue(for: "INBOX_ZERO_DEBUG_ACP_AGENT", environment: environment)
            ?? "claude-code-acp"
        let agentArguments = launchArgumentValues(named: "--debug-acp-agent-arg", in: arguments)
            + environmentArguments(environment["INBOX_ZERO_DEBUG_ACP_AGENT_ARGS"])
        let cwdPath = launchArgumentValue(named: "--debug-acp-cwd", in: arguments)
            ?? trimmedEnvironmentValue(for: "INBOX_ZERO_DEBUG_ACP_CWD", environment: environment)
            ?? FileManager.default.currentDirectoryPath

        return DebugACPRequest(
            prompt: prompt,
            agent: ACPAgentCommand(executable: executable, arguments: agentArguments),
            cwd: URL(fileURLWithPath: cwdPath, isDirectory: true)
        )
    }

    private static func launchArgumentValue(named name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func launchArgumentValues(named name: String, in arguments: [String]) -> [String] {
        var values: [String] = []
        var searchStart = arguments.startIndex
        while searchStart < arguments.endIndex,
              let index = arguments[searchStart...].firstIndex(of: name) {
            let valueIndex = arguments.index(after: index)
            guard valueIndex < arguments.endIndex else { break }
            values.append(arguments[valueIndex])
            searchStart = arguments.index(after: valueIndex)
        }
        return values
    }

    private static func environmentArguments(_ rawValue: String?) -> [String] {
        rawValue?
            .split(separator: " ")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            ?? []
    }

    private static func resolvedEndpointURL(
        envKey: String,
        environment: [String: String],
        useEmulator: Bool,
        fallback: URL
    ) -> URL {
        guard useEmulator,
              let rawValue = environment[envKey],
              let overrideURL = URL(string: rawValue)
        else {
            return fallback
        }
        return overrideURL
    }

    private static func trimmedEnvironmentValue(
        for key: String,
        environment: [String: String]
    ) -> String? {
        guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isEmpty == false
        else {
            return nil
        }
        return value
    }

    private static func resolvedBundleSettingValue(
        for key: String,
        infoDictionary: [String: Any]
    ) -> String? {
        guard let value = infoDictionary[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        guard trimmed.hasPrefix("$(") == false else { return nil }
        return trimmed
    }
}

struct AppControlRequest: Codable {
    var authToken: String
    var action: String
    var windowID: String?
    var value: String?
    var index: Int?
    var text: String?
}

struct AppControlResponse: Codable {
    var ok: Bool
    var message: String?
    var windows: [MailControlWindowSnapshot]?
    var window: MailControlWindowSnapshot?
    var snapshot: MailControlWindowStateSnapshot?
    var threadItems: [MailControlThreadListItem]?
    var thread: MailControlThreadSnapshot?
    var draft: MailControlDraftSnapshot?
}

struct AppControlPlaneInfo: Codable {
    var port: UInt16
    var token: String
    var pid: Int32
}

final class AppControlPlane {
    static let defaultPort: UInt16 = 61432

    private let store: MailAppStore
    private let queue = DispatchQueue(label: "InboxZeroMail.AppControlPlane")
    private var listener: NWListener?

    init(store: MailAppStore) {
        self.store = store
    }

    func start() {
        guard listener == nil else { return }

        do {
            let port = NWEndpoint.Port(rawValue: Self.defaultPort)!
            let listener = try NWListener(using: .tcp, on: port)
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    NSLog("App control plane failed: %@", String(describing: error))
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            NSLog("App control plane failed to start: %@", String(describing: error))
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                NSLog("App control plane receive error: %@", String(describing: error))
                connection.cancel()
                return
            }

            var accumulated = buffer
            if let data {
                accumulated.append(data)
            }

            if accumulated.isEmpty == false {
                Task {
                    let response = await self.handleRequestData(accumulated)
                    self.send(response: response, on: connection)
                }
            } else if isComplete {
                self.send(
                    response: AppControlResponse(ok: false, message: "Received an empty request.", windows: nil, window: nil, snapshot: nil, threadItems: nil, thread: nil, draft: nil),
                    on: connection
                )
            } else {
                self.receive(on: connection, buffer: accumulated)
            }
        }
    }

    @MainActor
    private func route(_ request: AppControlRequest) async -> AppControlResponse {
        let control = MailAppControlService(store: store)

        do {
            switch request.action {
            case "list-windows":
                return AppControlResponse(ok: true, message: nil, windows: control.listWindows(), window: nil, snapshot: nil, threadItems: nil, thread: nil, draft: nil)

            case "window-snapshot":
                let snapshot = try await control.windowSnapshot(windowID: request.windowID)
                return AppControlResponse(ok: true, message: nil, windows: nil, window: nil, snapshot: snapshot, threadItems: nil, thread: nil, draft: nil)

            case "list-threads":
                return AppControlResponse(ok: true, message: nil, windows: nil, window: nil, snapshot: nil, threadItems: try control.listThreads(windowID: request.windowID), thread: nil, draft: nil)

            case "show-tab":
                guard let value = request.value, let tab = UnifiedTab(rawValue: value) else {
                    return AppControlResponse(ok: false, message: "Expected a valid tab.", windows: nil, window: nil, snapshot: nil, threadItems: nil, thread: nil, draft: nil)
                }
                let window = try await control.showTab(windowID: request.windowID, tab: tab)
                return AppControlResponse(ok: true, message: nil, windows: nil, window: window, snapshot: nil, threadItems: nil, thread: nil, draft: nil)

            case "show-split-inbox":
                guard let value = request.value else {
                    return AppControlResponse(ok: false, message: "Expected a split inbox id or title.", windows: nil, window: nil, snapshot: nil, threadItems: nil, thread: nil, draft: nil)
                }
                let window = try await control.showSplitInbox(windowID: request.windowID, value: value)
                return AppControlResponse(ok: true, message: nil, windows: nil, window: window, snapshot: nil, threadItems: nil, thread: nil, draft: nil)

            case "search":
                let window = try await control.search(windowID: request.windowID, query: request.text ?? "")
                return AppControlResponse(ok: true, message: nil, windows: nil, window: window, snapshot: nil, threadItems: nil, thread: nil, draft: nil)

            case "current-thread":
                let thread = try await control.currentThread(windowID: request.windowID)
                return AppControlResponse(ok: true, message: nil, windows: nil, window: nil, snapshot: nil, threadItems: nil, thread: thread, draft: nil)

            case "open-thread":
                guard let value = request.value else {
                    return AppControlResponse(ok: false, message: "Expected a thread id.", windows: nil, window: nil, snapshot: nil, threadItems: nil, thread: nil, draft: nil)
                }
                let thread = try await control.openThread(windowID: request.windowID, threadIDValue: value)
                return AppControlResponse(ok: true, message: nil, windows: nil, window: nil, snapshot: nil, threadItems: nil, thread: thread, draft: nil)

            case "open-visible-thread":
                guard let index = request.index else {
                    return AppControlResponse(ok: false, message: "Expected a visible thread index.", windows: nil, window: nil, snapshot: nil, threadItems: nil, thread: nil, draft: nil)
                }
                let thread = try await control.openVisibleThread(windowID: request.windowID, index: index)
                return AppControlResponse(ok: true, message: nil, windows: nil, window: nil, snapshot: nil, threadItems: nil, thread: thread, draft: nil)

            case "read-visible-thread":
                guard let index = request.index else {
                    return AppControlResponse(ok: false, message: "Expected a visible thread index.", windows: nil, window: nil, snapshot: nil, threadItems: nil, thread: nil, draft: nil)
                }
                let thread = try await control.readVisibleThread(windowID: request.windowID, index: index)
                return AppControlResponse(ok: true, message: nil, windows: nil, window: nil, snapshot: nil, threadItems: nil, thread: thread, draft: nil)

            case "open-draft":
                let replyMode = ReplyMode(rawValue: request.value ?? ReplyMode.reply.rawValue) ?? .reply
                let draft = try await control.openReplyDraft(
                    windowID: request.windowID,
                    replyMode: replyMode,
                    threadIDValue: request.text,
                    visibleIndex: request.index
                )
                return AppControlResponse(ok: true, message: nil, windows: nil, window: nil, snapshot: nil, threadItems: nil, thread: nil, draft: draft)

            case "current-draft":
                let draft = try control.currentDraft(windowID: request.windowID)
                return AppControlResponse(ok: true, message: nil, windows: nil, window: nil, snapshot: nil, threadItems: nil, thread: nil, draft: draft)

            case "set-draft-body":
                let draft = try control.updateDraftBody(windowID: request.windowID, body: request.text ?? "")
                return AppControlResponse(ok: true, message: nil, windows: nil, window: nil, snapshot: nil, threadItems: nil, thread: nil, draft: draft)

            case "set-draft-subject":
                let draft = try control.updateDraftSubject(windowID: request.windowID, subject: request.text ?? "")
                return AppControlResponse(ok: true, message: nil, windows: nil, window: nil, snapshot: nil, threadItems: nil, thread: nil, draft: draft)

            default:
                return AppControlResponse(ok: false, message: "Unknown action '\(request.action)'.", windows: nil, window: nil, snapshot: nil, threadItems: nil, thread: nil, draft: nil)
            }
        } catch {
            return AppControlResponse(ok: false, message: error.localizedDescription, windows: nil, window: nil, snapshot: nil, threadItems: nil, thread: nil, draft: nil)
        }
    }

    private func handleRequestData(_ data: Data) async -> AppControlResponse {
        do {
            let request = try JSONDecoder().decode(AppControlRequest.self, from: data)
            return await route(request)
        } catch {
            return AppControlResponse(ok: false, message: "Could not decode request: \(error.localizedDescription)", windows: nil, window: nil, snapshot: nil, threadItems: nil, thread: nil, draft: nil)
        }
    }

    nonisolated private func send(response: AppControlResponse, on connection: NWConnection) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(response)
            connection.send(content: data, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
        } catch {
            connection.cancel()
        }
    }
}
