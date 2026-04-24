import AppKit
import DesignSystem
import MailCore
import MailData
import MailFeatures
import SwiftUI

#if canImport(AppUpdates) && !APP_STORE
import AppUpdates
#endif

// MARK: - FocusedValue for per-window commands

struct FocusedWindowModelKey: FocusedValueKey {
    typealias Value = WindowModel
}

extension FocusedValues {
    var windowModel: WindowModel? {
        get { self[FocusedWindowModelKey.self] }
        set { self[FocusedWindowModelKey.self] = newValue }
    }
}

// MARK: - App Entry Point

@main
struct InboxZeroMailApp: App {
    @NSApplicationDelegateAdaptor(InboxZeroMailAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var bootstrap: AppBootstrap
    @State private var hasStartedStore = false
    @StateObject private var updater: AppUpdateController

    init() {
        let bootstrap = AppBootstrap.make()
        _bootstrap = State(initialValue: bootstrap)
        _updater = StateObject(wrappedValue: AppUpdateController(isEnabled: bootstrap.isUITesting == false))
    }

    var body: some Scene {
        WindowGroup {
            WindowRoot(
                store: bootstrap.store,
                seedDemoData: bootstrap.seedDemoData,
                autoConnectGmailOnLaunch: bootstrap.autoConnectGmailOnLaunch,
                isUITesting: bootstrap.isUITesting
            )
                .background(WindowChromeConfigurator())
                .onChange(of: scenePhase) { _, newValue in
                    bootstrap.store.setForegroundActive(newValue == .active)
                }
                .onOpenURL { url in
                    Task {
                        _ = await bootstrap.workspace.handleRedirectURL(url)
                    }
                }
                .onAppear {
                    guard hasStartedStore == false else { return }
                    hasStartedStore = true
                    if bootstrap.isUITesting == false {
                        NotificationManager.shared.requestPermission()
                    }
                    bootstrap.store.onReload = { reason, threads in
                        NotificationManager.shared.handleReload(reason: reason, threads: threads)
                    }
                    bootstrap.store.start(seedDemoData: bootstrap.seedDemoData)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 920)
        .commands {
            MailAppCommands(store: bootstrap.store, updater: updater)
        }

        Settings {
            AppSettingsView(store: bootstrap.store)
        }
    }
}

final class InboxZeroMailAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard AppBootstrap.isRunningUITests else { return }
        UITestActivationCoordinator.promoteAppToForeground()
    }
}

private enum UITestActivationCoordinator {
    static func promoteAppToForeground() {
        for delay in [0.0, 0.05, 0.15, 0.35, 0.75] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSApplication.shared.setActivationPolicy(.regular)
                _ = NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
    }
}

// MARK: - WindowRoot (creates per-window state)

private struct WindowRoot: View {
    let store: MailAppStore
    let seedDemoData: Bool
    let autoConnectGmailOnLaunch: Bool
    let isUITesting: Bool
    @State private var windowModel: WindowModel?

    var body: some View {
        Group {
            if let windowModel {
                ContentView(model: windowModel)
                    .background(WindowActivityBridge(model: windowModel, store: store, isUITesting: isUITesting))
            }
        }
        .task {
            guard windowModel == nil else { return }
            let model = WindowModel(store: store)
            store.register(model)
            self.windowModel = model
            await model.initialLoad()
            if autoConnectGmailOnLaunch, store.availableAccountProviders.contains(.gmail) {
                store.connectAccount(kind: .gmail)
            }
        }
        .onDisappear {
            if let windowModel {
                store.unregister(windowModel)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openThreadFromNotification)) { notification in
            guard let rawID = notification.userInfo?["threadID"] as? String else { return }
            windowModel?.open(threadID: MailThreadID(rawValue: rawID))
        }
    }
}

// MARK: - Settings

private struct WindowActivityBridge: NSViewRepresentable {
    let model: WindowModel
    let store: MailAppStore
    let isUITesting: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, store: store, isUITesting: isUITesting)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.model = model
        context.coordinator.store = store
        context.coordinator.attach(to: nsView)
    }

    final class Coordinator {
        var model: WindowModel
        var store: MailAppStore
        let isUITesting: Bool
        private weak var observedWindow: NSWindow?
        private var becomeKeyObserver: NSObjectProtocol?
        private var hasForcedUITestActivation = false

        init(model: WindowModel, store: MailAppStore, isUITesting: Bool) {
            self.model = model
            self.store = store
            self.isUITesting = isUITesting
        }

        deinit {
            if let becomeKeyObserver {
                NotificationCenter.default.removeObserver(becomeKeyObserver)
            }
        }

        @MainActor
        func attach(to view: NSView) {
            guard let window = view.window else {
                Task { @MainActor [weak self, weak view] in
                    guard let self, let view else { return }
                    self.attach(to: view)
                }
                return
            }

            guard observedWindow !== window else {
                activateWindowIfNeeded(window)
                if window.isKeyWindow {
                    setActiveWindow()
                }
                return
            }

            if let becomeKeyObserver {
                NotificationCenter.default.removeObserver(becomeKeyObserver)
            }

            observedWindow = window
            activateWindowIfNeeded(window)
            becomeKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.setActiveWindow()
                }
            }

            if window.isKeyWindow {
                setActiveWindow()
            }
        }

        @MainActor
        private func setActiveWindow() {
            store.setActiveWindow(windowID: model.windowID)
        }

        @MainActor
        private func activateWindowIfNeeded(_ window: NSWindow) {
            guard isUITesting, hasForcedUITestActivation == false else { return }
            hasForcedUITestActivation = true
            UITestActivationCoordinator.promoteAppToForeground()
            DispatchQueue.main.async {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}

// MARK: - Settings

private struct AppSettingsView: View {
    let store: MailAppStore

    @AppStorage(AppPreferences.loadRemoteImagesKey)
    private var loadRemoteImagesAutomatically = AppPreferences.loadRemoteImagesByDefault
    @AppStorage(AppPreferences.threadRowDensityKey)
    private var threadRowDensityRawValue = AppPreferences.defaultThreadRowDensity.rawValue
    @AppStorage(AppPreferences.accountAvatarColorsVersionKey)
    private var avatarSettingsVersion = 0
    @AppStorage(AppPreferences.splitInboxTabsVersionKey)
    private var splitInboxTabsVersion = 0
    @State private var newSplitInboxTitle = ""
    @State private var newSplitInboxBaseTab: UnifiedTab = .all
    @State private var newSplitInboxKind: CustomSplitInboxKind = .label
    @State private var selectedLabelQueryText = ""
    @State private var selectedCategoryQueryText = ""
    @State private var customSplitInboxQueryText = ""
    @State private var accountPendingDisconnect: MailAccount?

    private var configuredSplitInboxItems: [SplitInboxItem] {
        AppPreferences.configuredSplitInboxItems()
    }

    private var hiddenBuiltInSplitInboxItems: [SplitInboxItem] {
        SplitInboxItem.defaultItems.filter { item in
            configuredSplitInboxItems.contains(where: { $0.id == item.id }) == false
        }
    }

    private var labelOptions: [SplitInboxMailboxOption] {
        Array(
            Dictionary(
                grouping: store.mailboxes.filter { $0.kind == .label }
            ) { $0.displayName.lowercased() }
            .values
            .compactMap { mailboxes in
                guard let mailbox = mailboxes.sorted(by: { $0.displayName < $1.displayName }).first else { return nil }
                return SplitInboxMailboxOption(
                    title: mailbox.displayName,
                    queryText: "label:\(mailbox.displayName)"
                )
            }
            .sorted(by: { $0.title < $1.title })
        )
    }

    private var categoryOptions: [SplitInboxMailboxOption] {
        Array(
            Dictionary(
                grouping: store.mailboxes.filter { mailbox in
                    mailbox.kind == .category || mailbox.providerMailboxID.uppercased().hasPrefix("CATEGORY_")
                }
            ) { normalizedCategoryName(for: $0) }
            .values
            .compactMap { mailboxes in
                guard let mailbox = mailboxes.sorted(by: { $0.displayName < $1.displayName }).first else { return nil }
                let categoryName = normalizedCategoryName(for: mailbox)
                guard categoryName.isEmpty == false else { return nil }
                return SplitInboxMailboxOption(
                    title: categoryName.capitalized,
                    queryText: "category:\(categoryName)"
                )
            }
            .sorted(by: { $0.title < $1.title })
        )
    }

    private var canAddCustomSplitInbox: Bool {
        let trimmedTitle = newSplitInboxTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTitle.isEmpty == false else { return false }

        switch newSplitInboxKind {
        case .label:
            return selectedLabelQueryText.isEmpty == false
        case .category:
            return selectedCategoryQueryText.isEmpty == false
        case .query:
            return customSplitInboxQueryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    var body: some View {
        let _ = avatarSettingsVersion
        let _ = splitInboxTabsVersion
        TabView {
            generalSettingsTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            accountsSettingsTab
                .tabItem {
                    Label("Accounts", systemImage: "person.crop.circle")
                }
        }
        .frame(width: 560, height: 460)
        .accountDisconnectConfirmation(account: $accountPendingDisconnect) { accountID in
            store.disconnectAccount(accountID: accountID)
        }
    }

    private var generalSettingsTab: some View {
        Form {
            Section {
                Toggle("Load Remote Images Automatically", isOn: $loadRemoteImagesAutomatically)
            } header: {
                Text("Privacy")
            } footer: {
                Text("Blocks external images and other remote assets in HTML email by default.")
            }

            Section {
                Picker("Message List Density", selection: $threadRowDensityRawValue) {
                    ForEach(ThreadRowDensity.allCases) { density in
                        Text(density.title).tag(density.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Display")
            } footer: {
                Text("Comfortable is the default. Compact keeps the previous tighter thread list.")
            }

            Section {
                ForEach(Array(configuredSplitInboxItems.enumerated()), id: \.element.id) { index, item in
                    SplitInboxSettingsRow(
                        title: item.normalizedTitle,
                        subtitle: item.normalizedQueryText,
                        countLabel: "\(index + 1)",
                        canMoveUp: index > 0,
                        canMoveDown: index < configuredSplitInboxItems.count - 1,
                        canRemove: configuredSplitInboxItems.count > 1,
                        onMoveUp: { moveSplitInboxTab(from: index, to: index - 1) },
                        onMoveDown: { moveSplitInboxTab(from: index, to: index + 1) },
                        onRemove: { removeSplitInboxItem(item) }
                    )
                }

                if hiddenBuiltInSplitInboxItems.isEmpty == false {
                    Divider()

                    ForEach(hiddenBuiltInSplitInboxItems) { item in
                        SplitInboxSettingsRow(
                            title: item.normalizedTitle,
                            subtitle: nil,
                            countLabel: nil,
                            canMoveUp: false,
                            canMoveDown: false,
                            canRemove: false,
                            onMoveUp: {},
                            onMoveDown: {},
                            onRemove: {},
                            trailingActionLabel: "Add",
                            trailingAction: { addBuiltInSplitInboxItem(item) }
                        )
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    TextField("Tab Title", text: $newSplitInboxTitle)

                    Picker("Match Type", selection: $newSplitInboxKind) {
                        ForEach(CustomSplitInboxKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }

                    switch newSplitInboxKind {
                    case .label:
                        if labelOptions.isEmpty {
                            Text("No labels are available yet.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Label", selection: $selectedLabelQueryText) {
                                ForEach(labelOptions) { option in
                                    Text(option.title).tag(option.queryText)
                                }
                            }
                        }
                    case .category:
                        if categoryOptions.isEmpty {
                            Text("No categories are available yet.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Category", selection: $selectedCategoryQueryText) {
                                ForEach(categoryOptions) { option in
                                    Text(option.title).tag(option.queryText)
                                }
                            }
                        }
                    case .query:
                        TextField("label:receipts is:unread", text: $customSplitInboxQueryText)
                    }

                    Picker("Base Tab", selection: $newSplitInboxBaseTab) {
                        ForEach(UnifiedTab.allCases) { tab in
                            Text(tab.title).tag(tab)
                        }
                    }

                    HStack {
                        Spacer()
                        Button("Add Custom Tab") {
                            addCustomSplitInbox()
                        }
                        .disabled(canAddCustomSplitInbox == false)
                    }
                }
            } header: {
                Text("Split Inbox")
            } footer: {
                Text("Controls which tabs appear in the split inbox bar and the order used when cycling with Tab. Custom queries currently support `label:`, `category:`, `is:`, and `in:` tokens.")
            }
        }
        .padding(20)
        .onAppear {
            seedCustomSplitInboxDefaultsIfNeeded()
        }
    }

    private var accountsSettingsTab: some View {
        Group {
            if store.accounts.isEmpty {
                ContentUnavailableView(
                    "No Accounts",
                    systemImage: "person.crop.circle.badge.plus",
                    description: Text("Connect an inbox to manage it here.")
                )
                .padding(24)
            } else {
                Form {
                    Section {
                        ForEach(store.accounts) { account in
                            AccountAvatarSettingsRow(
                                account: account,
                                accounts: store.accounts,
                                onDisconnect: {
                                    accountPendingDisconnect = account
                                }
                            )
                        }
                    } header: {
                        Text("Accounts")
                    } footer: {
                        Text("Each inbox starts with a different color. Disconnecting removes cached mail for that account from this Mac.")
                    }
                }
                .padding(20)
            }
        }
    }

    private func moveSplitInboxTab(from sourceIndex: Int, to destinationIndex: Int) {
        guard configuredSplitInboxItems.indices.contains(sourceIndex),
              configuredSplitInboxItems.indices.contains(destinationIndex) else {
            return
        }

        var updatedItems = configuredSplitInboxItems
        let movedItem = updatedItems.remove(at: sourceIndex)
        updatedItems.insert(movedItem, at: destinationIndex)
        AppPreferences.setConfiguredSplitInboxItems(updatedItems)
    }

    private func removeSplitInboxItem(_ item: SplitInboxItem) {
        let updatedItems = configuredSplitInboxItems.filter { $0.id != item.id }
        AppPreferences.setConfiguredSplitInboxItems(updatedItems)
    }

    private func addBuiltInSplitInboxItem(_ item: SplitInboxItem) {
        AppPreferences.setConfiguredSplitInboxItems(configuredSplitInboxItems + [item])
    }

    private func addCustomSplitInbox() {
        guard canAddCustomSplitInbox else { return }

        let queryText: String
        switch newSplitInboxKind {
        case .label:
            queryText = selectedLabelQueryText
        case .category:
            queryText = selectedCategoryQueryText
        case .query:
            queryText = customSplitInboxQueryText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let newItem = SplitInboxItem(
            title: newSplitInboxTitle,
            tab: newSplitInboxBaseTab,
            queryText: queryText
        )

        AppPreferences.setConfiguredSplitInboxItems(configuredSplitInboxItems + [newItem])
        resetCustomSplitInboxBuilder()
    }

    private func seedCustomSplitInboxDefaultsIfNeeded() {
        if selectedLabelQueryText.isEmpty {
            selectedLabelQueryText = labelOptions.first?.queryText ?? ""
        }
        if selectedCategoryQueryText.isEmpty {
            selectedCategoryQueryText = categoryOptions.first?.queryText ?? ""
        }
    }

    private func resetCustomSplitInboxBuilder() {
        newSplitInboxTitle = ""
        newSplitInboxBaseTab = .all
        customSplitInboxQueryText = ""
        seedCustomSplitInboxDefaultsIfNeeded()
    }

    private func normalizedCategoryName(for mailbox: MailboxRef) -> String {
        let uppercaseID = mailbox.providerMailboxID.uppercased()
        if uppercaseID.hasPrefix("CATEGORY_") {
            return mailbox.providerMailboxID
                .dropFirst("CATEGORY_".count)
                .replacingOccurrences(of: "_", with: " ")
                .lowercased()
        }

        return mailbox.displayName
            .replacingOccurrences(of: "Category ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

private struct SplitInboxSettingsRow: View {
    let title: String
    let subtitle: String?
    let countLabel: String?
    let canMoveUp: Bool
    let canMoveDown: Bool
    let canRemove: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onRemove: () -> Void
    var trailingActionLabel: String? = nil
    var trailingAction: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            if let countLabel {
                Text(countLabel)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .leading)
            } else {
                Color.clear
                    .frame(width: 18, height: 1)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if let subtitle, subtitle.isEmpty == false {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let trailingActionLabel, let trailingAction {
                Button(trailingActionLabel, action: trailingAction)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            } else {
                HStack(spacing: 6) {
                    Button(action: onMoveUp) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(canMoveUp == false)

                    Button(action: onMoveDown) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(canMoveDown == false)

                    Button("Remove", role: .destructive, action: onRemove)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .disabled(canRemove == false)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private enum CustomSplitInboxKind: String, CaseIterable, Identifiable {
    case label
    case category
    case query

    var id: String { rawValue }

    var title: String {
        switch self {
        case .label:
            "Label"
        case .category:
            "Category"
        case .query:
            "Query"
        }
    }
}

private struct SplitInboxMailboxOption: Identifiable, Hashable {
    let title: String
    let queryText: String

    var id: String { queryText }
}

private struct AccountAvatarSettingsRow: View {
    let account: MailAccount
    let accounts: [MailAccount]
    let onDisconnect: () -> Void

    private var effectiveColorHex: String {
        AppPreferences.effectiveAccountAvatarColorHex(for: account, accounts: accounts)
    }

    private var selectionBinding: Binding<String> {
        Binding(
            get: { effectiveColorHex },
            set: { selection in
                AppPreferences.setAccountAvatarColorHex(selection, for: account.id)
            }
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Text(String(account.displayName.prefix(1)).uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color(hex: effectiveColorHex))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    Text(account.primaryEmail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 16)

            HStack(spacing: 8) {
                Circle()
                    .fill(Color(hex: effectiveColorHex))
                    .frame(width: 10, height: 10)

                Picker("Avatar Color", selection: selectionBinding) {
                    ForEach(AppPreferences.accountAvatarColorOptions) { option in
                        Text(option.name).tag(option.hex)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 132)

                Text(AppPreferences.accountAvatarColorName(for: effectiveColorHex))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .leading)
            }

            Button(role: .destructive, action: onDisconnect) {
                Label("Disconnect", systemImage: "person.crop.circle.badge.xmark")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Window Chrome

private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        Task { @MainActor in
            configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        Task { @MainActor in
            configure(window: nsView.window)
        }
    }

    @MainActor
    private func configure(window: NSWindow?) {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        window.isMovableByWindowBackground = true
        window.toolbar?.showsBaselineSeparator = false
        if #available(macOS 13.0, *) {
            window.toolbarStyle = .unifiedCompact
        }
    }
}
