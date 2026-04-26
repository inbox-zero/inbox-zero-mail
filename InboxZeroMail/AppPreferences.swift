import Foundation
import DesignSystem
import MailCore

enum AppPreferences {
    struct AccountAvatarColorOption: Identifiable, Hashable {
        let name: String
        let hex: String

        var id: String { hex }
    }

    static let loadRemoteImagesKey = "preferences.loadRemoteImagesAutomatically"
    static let loadRemoteImagesByDefault = true
    static let imageProxyBaseURLKey = "preferences.imageProxyBaseURL"

    static let splitInboxTabsKey = "preferences.splitInboxTabs"
    static let splitInboxItemsKey = "preferences.splitInboxItems"
    static let splitInboxTabsVersionKey = "preferences.splitInboxTabs.version"
    static let defaultSplitInboxItems: [SplitInboxItem] = SplitInboxItem.defaultItems
    static let threadRowDensityKey = "preferences.threadRowDensity"
    static let defaultThreadRowDensity: ThreadRowDensity = .comfortable

    static let accountAvatarColorsVersionKey = "preferences.accountAvatarColors.version"
    static let accountAvatarColorOptions = [
        AccountAvatarColorOption(name: "Blue", hex: "#4C78FF"),
        AccountAvatarColorOption(name: "Green", hex: "#1F8F5F"),
        AccountAvatarColorOption(name: "Amber", hex: "#D97706"),
        AccountAvatarColorOption(name: "Berry", hex: "#B83280"),
        AccountAvatarColorOption(name: "Orange", hex: "#C2410C"),
        AccountAvatarColorOption(name: "Teal", hex: "#0F766E"),
        AccountAvatarColorOption(name: "Violet", hex: "#7C3AED"),
        AccountAvatarColorOption(name: "Rose", hex: "#BE123C"),
    ]
    static let accountAvatarPalette = accountAvatarColorOptions.map(\.hex)

    static func storedAccountAvatarColorHex(
        for accountID: MailAccountID,
        defaults: UserDefaults = .standard
    ) -> String? {
        guard let value = defaults.string(forKey: accountAvatarColorKey(for: accountID))?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isEmpty == false else {
            return nil
        }
        return value.uppercased()
    }

    static func setAccountAvatarColorHex(
        _ hex: String?,
        for accountID: MailAccountID,
        defaults: UserDefaults = .standard
    ) {
        let key = accountAvatarColorKey(for: accountID)
        if let normalized = hex?.trimmingCharacters(in: .whitespacesAndNewlines), normalized.isEmpty == false {
            defaults.set(normalized.uppercased(), forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        defaults.set(defaults.integer(forKey: accountAvatarColorsVersionKey) + 1, forKey: accountAvatarColorsVersionKey)
    }

    static func effectiveAccountAvatarColorHex(
        for account: MailAccount,
        accounts: [MailAccount],
        defaults: UserDefaults = .standard
    ) -> String {
        if let stored = storedAccountAvatarColorHex(for: account.id, defaults: defaults) {
            return stored
        }
        return defaultAccountAvatarColorHex(for: account, accounts: accounts, defaults: defaults)
    }

    static func defaultAccountAvatarColorHex(
        for account: MailAccount,
        accounts: [MailAccount],
        defaults: UserDefaults = .standard
    ) -> String {
        let automaticAccounts = accounts
            .filter { storedAccountAvatarColorHex(for: $0.id, defaults: defaults) == nil }
            .sorted { $0.id.rawValue < $1.id.rawValue }

        guard automaticAccounts.isEmpty == false else {
            return accountAvatarPalette[stablePaletteIndex(for: account.id)]
        }

        var assignments: [MailAccountID: Int] = [:]
        var usedIndices: Set<Int> = []

        for candidate in automaticAccounts {
            let preferredIndex = stablePaletteIndex(for: candidate.id)
            let chosenIndex = firstAvailablePaletteIndex(startingAt: preferredIndex, excluding: usedIndices)
            assignments[candidate.id] = chosenIndex
            usedIndices.insert(chosenIndex)
        }

        let fallbackIndex = stablePaletteIndex(for: account.id)
        return accountAvatarPalette[assignments[account.id] ?? fallbackIndex]
    }

    static func accountAvatarColorName(for hex: String) -> String {
        accountAvatarColorOptions.first(where: { $0.hex == hex.uppercased() })?.name ?? "Custom"
    }

    static func threadRowDensity(defaults: UserDefaults = .standard) -> ThreadRowDensity {
        guard let rawValue = defaults.string(forKey: threadRowDensityKey),
              let density = ThreadRowDensity(rawValue: rawValue) else {
            return defaultThreadRowDensity
        }
        return density
    }

    static func imageProxyBaseURL(defaults: UserDefaults = .standard) -> String? {
        guard let value = defaults.string(forKey: imageProxyBaseURLKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isEmpty == false else {
            return nil
        }
        return value
    }

    static func setImageProxyBaseURL(_ rawValue: String?, defaults: UserDefaults = .standard) {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isEmpty == false else {
            defaults.removeObject(forKey: imageProxyBaseURLKey)
            return
        }
        defaults.set(value, forKey: imageProxyBaseURLKey)
    }

    static func configuredSplitInboxItems(defaults: UserDefaults = .standard) -> [SplitInboxItem] {
        if let data = defaults.data(forKey: splitInboxItemsKey),
           let decoded = try? JSONDecoder().decode([SplitInboxItem].self, from: data) {
            let normalizedItems = normalizedSplitInboxItems(decoded)
            return normalizedItems.isEmpty ? defaultSplitInboxItems : normalizedItems
        }

        let legacyTabs = defaults.stringArray(forKey: splitInboxTabsKey) ?? []
        let resolvedLegacyTabs = uniqueTabs(in: legacyTabs.compactMap(UnifiedTab.init(rawValue:)))
        if resolvedLegacyTabs.isEmpty == false {
            return resolvedLegacyTabs.map(SplitInboxItem.builtIn)
        }

        return defaultSplitInboxItems
    }

    static func setConfiguredSplitInboxItems(_ items: [SplitInboxItem], defaults: UserDefaults = .standard) {
        let normalizedItems = normalizedSplitInboxItems(items)
        let finalItems = normalizedItems.isEmpty ? defaultSplitInboxItems : normalizedItems
        if let data = try? JSONEncoder().encode(finalItems) {
            defaults.set(data, forKey: splitInboxItemsKey)
        }
        defaults.set(defaults.integer(forKey: splitInboxTabsVersionKey) + 1, forKey: splitInboxTabsVersionKey)
    }

    private static func accountAvatarColorKey(for accountID: MailAccountID) -> String {
        "preferences.accountAvatarColor.\(accountID.rawValue)"
    }

    private static func stablePaletteIndex(for accountID: MailAccountID) -> Int {
        let scalarHash = accountID.rawValue.unicodeScalars.reduce(0) { partial, scalar in
            (partial * 31 + Int(scalar.value)) % accountAvatarPalette.count
        }
        return scalarHash % accountAvatarPalette.count
    }

    private static func uniqueTabs(in tabs: [UnifiedTab]) -> [UnifiedTab] {
        var seen: Set<UnifiedTab> = []
        return tabs.filter { seen.insert($0).inserted }
    }

    private static func normalizedSplitInboxItems(_ items: [SplitInboxItem]) -> [SplitInboxItem] {
        var seenIDs: Set<String> = []
        var normalized: [SplitInboxItem] = []

        for item in items {
            let normalizedItem = SplitInboxItem(
                id: item.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? UUID().uuidString : item.id,
                title: item.normalizedTitle,
                tab: item.tab,
                queryText: item.normalizedQueryText
            )

            guard seenIDs.insert(normalizedItem.id).inserted else { continue }
            normalized.append(normalizedItem)
        }

        return normalized
    }

    private static func firstAvailablePaletteIndex(startingAt start: Int, excluding usedIndices: Set<Int>) -> Int {
        for offset in 0..<accountAvatarPalette.count {
            let candidate = (start + offset) % accountAvatarPalette.count
            if usedIndices.contains(candidate) == false {
                return candidate
            }
        }
        return start % accountAvatarPalette.count
    }
}
