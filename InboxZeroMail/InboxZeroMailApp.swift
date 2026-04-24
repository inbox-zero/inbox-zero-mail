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

    @State private var selectedPane: SettingsPane = .general
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

    private var selectedLabelOption: SplitInboxMailboxOption? {
        labelOptions.first { $0.queryText == selectedLabelQueryText }
    }

    private var selectedCategoryOption: SplitInboxMailboxOption? {
        categoryOptions.first { $0.queryText == selectedCategoryQueryText }
    }

    private var resolvedNewSplitInboxTitle: String {
        let trimmedTitle = newSplitInboxTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty == false {
            return trimmedTitle
        }

        switch newSplitInboxKind {
        case .label:
            return selectedLabelOption?.title ?? "Label"
        case .category:
            return selectedCategoryOption?.title ?? "Category"
        case .query:
            return "Custom"
        }
    }

    private var newSplitInboxTitlePlaceholder: String {
        switch newSplitInboxKind {
        case .label:
            selectedLabelOption?.title ?? "Tab title"
        case .category:
            selectedCategoryOption?.title ?? "Tab title"
        case .query:
            "Tab title"
        }
    }

    private var canAddCustomSplitInbox: Bool {
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
        HStack(spacing: 0) {
            settingsSidebar

            Divider()

            settingsDetail
        }
        .frame(minWidth: 780, idealWidth: 820, minHeight: 560, idealHeight: 620)
        .background(SettingsPalette.windowBackground)
        .accountDisconnectConfirmation(account: $accountPendingDisconnect) { accountID in
            store.disconnectAccount(accountID: accountID)
        }
        .onAppear {
            seedCustomSplitInboxDefaultsIfNeeded()
        }
        .onChange(of: labelOptions) { _, _ in
            seedCustomSplitInboxDefaultsIfNeeded()
        }
        .onChange(of: categoryOptions) { _, _ in
            seedCustomSplitInboxDefaultsIfNeeded()
        }
        .onChange(of: newSplitInboxKind) { _, _ in
            seedCustomSplitInboxDefaultsIfNeeded()
        }
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings")
                .font(.system(size: 16, weight: .semibold))
                .padding(.horizontal, 10)

            VStack(spacing: 4) {
                ForEach(SettingsPane.allCases) { pane in
                    Button {
                        selectedPane = pane
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: pane.systemImage)
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: 18)

                            Text(pane.title)
                                .lineLimit(1)

                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 13, weight: selectedPane == pane ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background {
                            if selectedPane == pane {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.16))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(pane.title)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 18)
        .frame(width: 180)
        .frame(maxHeight: .infinity)
        .background(SettingsPalette.sidebarBackground)
    }

    @ViewBuilder
    private var settingsDetail: some View {
        switch selectedPane {
        case .general:
            generalSettingsTab
        case .accounts:
            accountsSettingsTab
        }
    }

    private var generalSettingsTab: some View {
        SettingsPaneContent(
            title: "General",
            subtitle: "Reading, display, and split inbox preferences."
        ) {
            SettingsSection("Privacy", footer: "Remote assets can reveal when a message was opened.") {
                SettingsRow(
                    title: "Load remote images",
                    subtitle: "Show external images in HTML messages automatically."
                ) {
                    Toggle("Load remote images", isOn: $loadRemoteImagesAutomatically)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            SettingsSection("Display", footer: "Comfortable is the default. Compact keeps the thread list tighter.") {
                SettingsRow(title: "Message list density") {
                    Picker("Message list density", selection: $threadRowDensityRawValue) {
                        ForEach(ThreadRowDensity.allCases) { density in
                            Text(density.title).tag(density.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }
            }

            SettingsSection(
                "Split Inbox Tabs",
                footer: "These tabs appear in the split inbox bar and define the cycling order."
            ) {
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

                    if index < configuredSplitInboxItems.count - 1 || hiddenBuiltInSplitInboxItems.isEmpty == false {
                        SettingsSeparator()
                    }
                }

                if hiddenBuiltInSplitInboxItems.isEmpty == false {
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
                            trailingActionSystemImage: "plus",
                            trailingAction: { addBuiltInSplitInboxItem(item) }
                        )

                        if item.id != hiddenBuiltInSplitInboxItems.last?.id {
                            SettingsSeparator()
                        }
                    }
                }

                SettingsSeparator()

                SettingsRow(
                    title: "Default tabs",
                    subtitle: "Restore All, Unread, Starred, and Snoozed."
                ) {
                    Button("Reset") {
                        resetSplitInboxTabs()
                    }
                    .controlSize(.small)
                    .disabled(configuredSplitInboxItems == SplitInboxItem.defaultItems)
                }
            }

            SettingsSection(
                "New Split Inbox Tab",
                footer: "Custom queries support label, category, state, and mailbox tokens."
            ) {
                SettingsRow(title: "Title", subtitle: "Shown in the split inbox bar.") {
                    TextField(newSplitInboxTitlePlaceholder, text: $newSplitInboxTitle)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }

                SettingsSeparator()

                SettingsRow(title: "Match") {
                    Picker("Match", selection: $newSplitInboxKind) {
                        ForEach(CustomSplitInboxKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }

                SettingsSeparator()

                splitInboxMatchRow

                SettingsSeparator()

                SettingsRow(title: "Base tab", subtitle: "Applies a built-in view first.") {
                    Picker("Base tab", selection: $newSplitInboxBaseTab) {
                        ForEach(UnifiedTab.allCases) { tab in
                            Text(tab.title).tag(tab)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                }

                SettingsSeparator()

                HStack {
                    Spacer()
                    Button {
                        addCustomSplitInbox()
                    } label: {
                        Label("Add Tab", systemImage: "plus")
                    }
                    .controlSize(.small)
                    .disabled(canAddCustomSplitInbox == false)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
    }

    @ViewBuilder
    private var splitInboxMatchRow: some View {
        switch newSplitInboxKind {
        case .label:
            SettingsRow(
                title: "Label",
                subtitle: labelOptions.isEmpty ? "No labels are available yet." : nil
            ) {
                if labelOptions.isEmpty {
                    Text("Unavailable")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Label", selection: $selectedLabelQueryText) {
                        ForEach(labelOptions) { option in
                            Text(option.title).tag(option.queryText)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
            }
        case .category:
            SettingsRow(
                title: "Category",
                subtitle: categoryOptions.isEmpty ? "No categories are available yet." : nil
            ) {
                if categoryOptions.isEmpty {
                    Text("Unavailable")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Category", selection: $selectedCategoryQueryText) {
                        ForEach(categoryOptions) { option in
                            Text(option.title).tag(option.queryText)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
            }
        case .query:
            SettingsRow(title: "Query", subtitle: "Example: label:receipts is:unread") {
                TextField("label:receipts is:unread", text: $customSplitInboxQueryText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
        }
    }

    private var accountsSettingsTab: some View {
        SettingsPaneContent(
            title: "Accounts",
            subtitle: "Per-account appearance in unified inbox views."
        ) {
            if store.accounts.isEmpty {
                SettingsEmptyState(
                    title: "No Accounts",
                    systemImage: "person.crop.circle.badge.plus",
                    message: "Connect an inbox to manage it here."
                )
            } else {
                SettingsSection(
                    "Accounts",
                    footer: "Each inbox starts with a different color. Disconnecting removes cached mail for that account from this Mac."
                ) {
                    ForEach(Array(store.accounts.enumerated()), id: \.element.id) { index, account in
                        AccountAvatarSettingsRow(
                            account: account,
                            accounts: store.accounts,
                            onDisconnect: {
                                accountPendingDisconnect = account
                            }
                        )

                        if index < store.accounts.count - 1 {
                            SettingsSeparator()
                        }
                    }
                }
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

    private func resetSplitInboxTabs() {
        AppPreferences.setConfiguredSplitInboxItems(SplitInboxItem.defaultItems)
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
            title: resolvedNewSplitInboxTitle,
            tab: newSplitInboxBaseTab,
            queryText: queryText
        )

        AppPreferences.setConfiguredSplitInboxItems(configuredSplitInboxItems + [newItem])
        resetCustomSplitInboxBuilder()
    }

    private func seedCustomSplitInboxDefaultsIfNeeded() {
        if selectedLabelQueryText.isEmpty || labelOptions.contains(where: { $0.queryText == selectedLabelQueryText }) == false {
            selectedLabelQueryText = labelOptions.first?.queryText ?? ""
        }
        if selectedCategoryQueryText.isEmpty || categoryOptions.contains(where: { $0.queryText == selectedCategoryQueryText }) == false {
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

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case accounts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            "General"
        case .accounts:
            "Accounts"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            "gearshape"
        case .accounts:
            "person.crop.circle"
        }
    }
}

private enum SettingsPalette {
    static var windowBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    static var sidebarBackground: Color {
        Color(nsColor: .underPageBackgroundColor)
    }

    static var sectionBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    static var sectionBorder: Color {
        Color(nsColor: .separatorColor).opacity(0.45)
    }
}

private struct SettingsPaneContent<Content: View>: View {
    let title: String
    let subtitle: String?
    let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 26, weight: .semibold))

                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 2)

                content
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsPalette.windowBackground)
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let footer: String?
    let content: Content

    init(
        _ title: String,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                content
            }
            .background(SettingsPalette.sectionBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(SettingsPalette.sectionBorder, lineWidth: 1)
            }

            if let footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsRow<Accessory: View>: View {
    let title: String
    let subtitle: String?
    let accessory: Accessory

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let subtitle, subtitle.isEmpty == false {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 16)

            accessory
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: 44)
    }
}

private struct SettingsSeparator: View {
    var body: some View {
        Divider()
            .padding(.leading, 12)
    }
}

private struct SettingsEmptyState: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.system(size: 15, weight: .semibold))

            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 220)
        .background(SettingsPalette.sectionBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(SettingsPalette.sectionBorder, lineWidth: 1)
        }
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
    var trailingActionSystemImage: String? = nil
    var trailingAction: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            if let countLabel {
                Text(countLabel)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 22, alignment: .center)
            } else {
                Image(systemName: "plus.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, alignment: .center)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)

                if let subtitle, subtitle.isEmpty == false {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 16)

            if let trailingActionLabel, let trailingAction {
                Button(action: trailingAction) {
                    if let trailingActionSystemImage {
                        Label(trailingActionLabel, systemImage: trailingActionSystemImage)
                    } else {
                        Text(trailingActionLabel)
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            } else {
                HStack(spacing: 6) {
                    Button(action: onMoveUp) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(canMoveUp == false)
                    .help("Move up")

                    Button(action: onMoveDown) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(canMoveDown == false)
                    .help("Move down")

                    Button(role: .destructive, action: onRemove) {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(canRemove == false)
                    .help("Remove tab")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
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
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Text(account.primaryEmail)
                        .font(.system(size: 12))
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
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .leading)
            }

            Button(role: .destructive, action: onDisconnect) {
                Label("Disconnect", systemImage: "person.crop.circle.badge.xmark")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: 44)
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
