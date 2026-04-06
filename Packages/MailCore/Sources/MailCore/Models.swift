import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Sendable {
    case gmail
    case microsoft
}

public struct MailAccountCapabilities: Codable, Hashable, Sendable {
    public var supportsArchive: Bool
    public var supportsLabels: Bool
    public var supportsFolders: Bool
    public var supportsCategories: Bool
    public var supportsCompose: Bool

    public init(
        supportsArchive: Bool = true,
        supportsLabels: Bool = false,
        supportsFolders: Bool = false,
        supportsCategories: Bool = false,
        supportsCompose: Bool = true
    ) {
        self.supportsArchive = supportsArchive
        self.supportsLabels = supportsLabels
        self.supportsFolders = supportsFolders
        self.supportsCategories = supportsCategories
        self.supportsCompose = supportsCompose
    }
}

public enum MailAccountSyncPhase: String, Codable, Hashable, Sendable {
    case idle
    case syncing
    case reauthRequired
    case error
}

public struct MailAccountSyncState: Codable, Hashable, Sendable {
    public var phase: MailAccountSyncPhase
    public var lastSuccessfulSyncAt: Date?
    public var lastErrorDescription: String?

    public init(
        phase: MailAccountSyncPhase = .idle,
        lastSuccessfulSyncAt: Date? = nil,
        lastErrorDescription: String? = nil
    ) {
        self.phase = phase
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
        self.lastErrorDescription = lastErrorDescription
    }

    public var requiresReconnect: Bool {
        phase == .reauthRequired
    }

    public var isErrorState: Bool {
        requiresReconnect || phase == .error
    }
}

public struct MailAccount: Identifiable, Codable, Hashable, Sendable {
    public var id: MailAccountID
    public var providerKind: ProviderKind
    public var providerAccountID: String
    public var primaryEmail: String
    public var displayName: String
    public var syncState: MailAccountSyncState
    public var capabilities: MailAccountCapabilities

    public init(
        id: MailAccountID,
        providerKind: ProviderKind,
        providerAccountID: String,
        primaryEmail: String,
        displayName: String,
        syncState: MailAccountSyncState = .init(),
        capabilities: MailAccountCapabilities
    ) {
        self.id = id
        self.providerKind = providerKind
        self.providerAccountID = providerAccountID
        self.primaryEmail = primaryEmail
        self.displayName = displayName
        self.syncState = syncState
        self.capabilities = capabilities
    }
}

public struct MailParticipant: Codable, Hashable, Sendable {
    public var name: String?
    public var emailAddress: String

    public init(name: String? = nil, emailAddress: String) {
        self.name = name
        self.emailAddress = emailAddress
    }

    public var displayName: String {
        name.flatMap { $0.isEmpty ? nil : $0 } ?? emailAddress
    }
}

public enum MailboxKind: String, Codable, Hashable, Sendable {
    case label
    case folder
    case category
    case system
}

public enum MailboxSystemRole: String, Codable, Hashable, Sendable {
    case inbox
    case unread
    case starred
    case sent
    case draft
    case archive
    case trash
    case spam
    case important
    case custom
}

public struct MailboxRef: Identifiable, Codable, Hashable, Sendable {
    public var id: MailboxID
    public var accountID: MailAccountID
    public var providerMailboxID: String
    public var displayName: String
    public var kind: MailboxKind
    public var systemRole: MailboxSystemRole?
    public var colorHex: String?
    public var textColorHex: String?
    public var isHiddenInLabelList: Bool

    public init(
        id: MailboxID,
        accountID: MailAccountID,
        providerMailboxID: String,
        displayName: String,
        kind: MailboxKind,
        systemRole: MailboxSystemRole? = nil,
        colorHex: String? = nil,
        textColorHex: String? = nil,
        isHiddenInLabelList: Bool = false
    ) {
        self.id = id
        self.accountID = accountID
        self.providerMailboxID = providerMailboxID
        self.kind = kind
        self.systemRole = systemRole
        self.colorHex = colorHex
        self.textColorHex = textColorHex
        self.isHiddenInLabelList = isHiddenInLabelList
        self.displayName = MailboxNameFormatter.displayName(
            preferred: displayName,
            providerMailboxID: providerMailboxID,
            kind: kind,
            systemRole: systemRole
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case accountID
        case providerMailboxID
        case displayName
        case kind
        case systemRole
        case colorHex
        case textColorHex
        case isHiddenInLabelList
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(MailboxID.self, forKey: .id),
            accountID: try container.decode(MailAccountID.self, forKey: .accountID),
            providerMailboxID: try container.decode(String.self, forKey: .providerMailboxID),
            displayName: try container.decode(String.self, forKey: .displayName),
            kind: try container.decode(MailboxKind.self, forKey: .kind),
            systemRole: try container.decodeIfPresent(MailboxSystemRole.self, forKey: .systemRole),
            colorHex: try container.decodeIfPresent(String.self, forKey: .colorHex),
            textColorHex: try container.decodeIfPresent(String.self, forKey: .textColorHex),
            isHiddenInLabelList: try container.decodeIfPresent(Bool.self, forKey: .isHiddenInLabelList) ?? false
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(accountID, forKey: .accountID)
        try container.encode(providerMailboxID, forKey: .providerMailboxID)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(systemRole, forKey: .systemRole)
        try container.encodeIfPresent(colorHex, forKey: .colorHex)
        try container.encodeIfPresent(textColorHex, forKey: .textColorHex)
        try container.encode(isHiddenInLabelList, forKey: .isHiddenInLabelList)
    }
}

private enum MailboxNameFormatter {
    static func displayName(
        preferred: String,
        providerMailboxID: String,
        kind: MailboxKind,
        systemRole: MailboxSystemRole?
    ) -> String {
        if let systemRole {
            return title(for: systemRole)
        }

        let raw = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = providerMailboxID.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = raw.isEmpty ? fallback : raw

        let dePrefixed = stripKnownPrefix(from: candidate, kind: kind)
        let separated = dePrefixed
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = separated.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard collapsed.isEmpty == false else {
            return raw.isEmpty ? fallback : raw
        }

        let looksRaw = candidate.contains("_")
            || candidate.contains("-")
            || candidate == candidate.uppercased()
            || hasKnownPrefix(candidate, kind: kind)
        guard looksRaw else { return collapsed }

        return collapsed
            .split(separator: " ")
            .map { token in
                let word = String(token)
                if word == word.uppercased(), word.count <= 3 {
                    return word
                }
                return word.lowercased().capitalized
            }
            .joined(separator: " ")
    }

    private static func title(for role: MailboxSystemRole) -> String {
        switch role {
        case .inbox: return "Inbox"
        case .unread: return "Unread"
        case .starred: return "Starred"
        case .sent: return "Sent"
        case .draft: return "Drafts"
        case .archive: return "Archive"
        case .trash: return "Trash"
        case .spam: return "Spam"
        case .important: return "Important"
        case .custom: return "Custom"
        }
    }

    private static func stripKnownPrefix(from value: String, kind: MailboxKind) -> String {
        let prefixes: [String]
        switch kind {
        case .category:
            prefixes = ["CATEGORY_"]
        case .label:
            prefixes = ["LABEL_", "Label_"]
        case .folder:
            prefixes = ["FOLDER_", "Folder_"]
        case .system:
            prefixes = []
        }

        for prefix in prefixes where value.hasPrefix(prefix) {
            return String(value.dropFirst(prefix.count))
        }
        return value
    }

    private static func hasKnownPrefix(_ value: String, kind: MailboxKind) -> Bool {
        stripKnownPrefix(from: value, kind: kind) != value
    }
}

public struct MessageHeader: Codable, Hashable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public enum MailBodyCacheState: String, Codable, Hashable, Sendable {
    case missing
    case hot
    case cold
}

public struct MailMessage: Identifiable, Codable, Hashable, Sendable {
    public var id: MailMessageID
    public var threadID: MailThreadID
    public var accountID: MailAccountID
    public var providerMessageID: String
    public var sender: MailParticipant
    public var toRecipients: [MailParticipant]
    public var ccRecipients: [MailParticipant]
    public var bccRecipients: [MailParticipant]
    public var sentAt: Date?
    public var receivedAt: Date?
    public var snippet: String
    public var plainBody: String?
    public var htmlBody: String?
    public var bodyCacheState: MailBodyCacheState
    public var headers: [MessageHeader]
    public var mailboxRefs: [MailboxRef]
    public var attachments: [MailAttachment]
    public var isRead: Bool
    public var isOutgoing: Bool

    public init(
        id: MailMessageID,
        threadID: MailThreadID,
        accountID: MailAccountID,
        providerMessageID: String,
        sender: MailParticipant,
        toRecipients: [MailParticipant] = [],
        ccRecipients: [MailParticipant] = [],
        bccRecipients: [MailParticipant] = [],
        sentAt: Date? = nil,
        receivedAt: Date? = nil,
        snippet: String,
        plainBody: String? = nil,
        htmlBody: String? = nil,
        bodyCacheState: MailBodyCacheState = .missing,
        headers: [MessageHeader] = [],
        mailboxRefs: [MailboxRef] = [],
        attachments: [MailAttachment] = [],
        isRead: Bool,
        isOutgoing: Bool
    ) {
        self.id = id
        self.threadID = threadID
        self.accountID = accountID
        self.providerMessageID = providerMessageID
        self.sender = sender
        self.toRecipients = toRecipients
        self.ccRecipients = ccRecipients
        self.bccRecipients = bccRecipients
        self.sentAt = sentAt
        self.receivedAt = receivedAt
        self.snippet = snippet
        self.plainBody = plainBody
        self.htmlBody = htmlBody
        self.bodyCacheState = bodyCacheState
        self.headers = headers
        self.mailboxRefs = mailboxRefs
        self.attachments = attachments
        self.isRead = isRead
        self.isOutgoing = isOutgoing
    }
}

public struct MailAttachment: Codable, Hashable, Sendable, Identifiable {
    public var id: String  // provider attachment ID (e.g. Gmail attachmentId)
    public var messageID: MailMessageID
    public var filename: String
    public var mimeType: String
    public var size: Int  // bytes

    public init(id: String, messageID: MailMessageID, filename: String, mimeType: String, size: Int) {
        self.id = id
        self.messageID = messageID
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
    }

    public var formattedSize: String {
        if size < 1024 { return "\(size) B" }
        if size < 1024 * 1024 { return "\(size / 1024) KB" }
        return String(format: "%.1f MB", Double(size) / (1024.0 * 1024.0))
    }

    public var systemImage: String {
        switch mimeType.lowercased() {
        case let m where m.hasPrefix("image/"): return "photo"
        case let m where m.contains("pdf"): return "doc.text"
        case let m where m.contains("zip") || m.contains("archive"): return "archivebox"
        case let m where m.contains("spreadsheet") || m.contains("csv"): return "tablecells"
        case let m where m.contains("presentation"): return "play.rectangle"
        default: return "paperclip"
        }
    }
}

public struct MailThread: Identifiable, Codable, Hashable, Sendable {
    public var id: MailThreadID
    public var accountID: MailAccountID
    public var providerThreadID: String
    public var subject: String
    public var participantSummary: String
    public var snippet: String
    public var lastActivityAt: Date
    public var hasUnread: Bool
    public var isStarred: Bool
    public var isInInbox: Bool
    public var mailboxRefs: [MailboxRef]
    public var latestMessageID: MailMessageID?
    public var attachmentCount: Int
    public var snoozedUntil: Date?
    public var syncRevision: String

    public var isSnoozed: Bool {
        guard let snoozedUntil else { return false }
        return snoozedUntil > Date()
    }

    public init(
        id: MailThreadID,
        accountID: MailAccountID,
        providerThreadID: String,
        subject: String,
        participantSummary: String,
        snippet: String,
        lastActivityAt: Date,
        hasUnread: Bool,
        isStarred: Bool,
        isInInbox: Bool,
        mailboxRefs: [MailboxRef] = [],
        latestMessageID: MailMessageID? = nil,
        attachmentCount: Int = 0,
        snoozedUntil: Date? = nil,
        syncRevision: String
    ) {
        self.id = id
        self.accountID = accountID
        self.providerThreadID = providerThreadID
        self.subject = subject
        self.participantSummary = participantSummary
        self.snippet = snippet
        self.lastActivityAt = lastActivityAt
        self.hasUnread = hasUnread
        self.isStarred = isStarred
        self.isInInbox = isInInbox
        self.mailboxRefs = mailboxRefs
        self.latestMessageID = latestMessageID
        self.attachmentCount = attachmentCount
        self.snoozedUntil = snoozedUntil
        self.syncRevision = syncRevision
    }
}

public struct MailThreadDetail: Codable, Hashable, Sendable {
    public var thread: MailThread
    public var messages: [MailMessage]

    public init(thread: MailThread, messages: [MailMessage]) {
        self.thread = thread
        self.messages = messages
    }
}

public enum UnifiedTab: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case all
    case unread
    case starred
    case snoozed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all:
            "All"
        case .unread:
            "Unread"
        case .starred:
            "Starred"
        case .snoozed:
            "Snoozed"
        }
    }
}

public struct SplitInboxItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var tab: UnifiedTab
    public var queryText: String?

    public init(
        id: String = UUID().uuidString,
        title: String,
        tab: UnifiedTab = .all,
        queryText: String? = nil
    ) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tab = tab
        self.queryText = queryText?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func builtIn(_ tab: UnifiedTab) -> SplitInboxItem {
        SplitInboxItem(id: "builtin.\(tab.rawValue)", title: tab.title, tab: tab)
    }

    public static var defaultItems: [SplitInboxItem] {
        UnifiedTab.allCases.map(Self.builtIn)
    }

    public var normalizedTitle: String {
        title.isEmpty ? tab.title : title
    }

    public var normalizedQueryText: String? {
        guard let queryText, queryText.isEmpty == false else { return nil }
        return queryText
    }

    public var isBuiltIn: Bool {
        id == Self.builtIn(tab).id && normalizedQueryText == nil
    }
}

public enum ThreadListSortOrder: String, Codable, Hashable, Sendable {
    case newestFirst
}

public enum MailboxScope: Codable, Hashable, Sendable {
    case inboxOnly
    case specific(MailboxID)
    case allMail
}

public struct ThreadListQuery: Codable, Hashable, Sendable {
    public var tab: UnifiedTab
    public var accountFilter: MailAccountID?
    public var mailboxScope: MailboxScope
    public var searchText: String?
    public var splitInboxQueryText: String?
    public var limit: Int
    public var cursor: String?
    public var sortOrder: ThreadListSortOrder

    public init(
        tab: UnifiedTab,
        accountFilter: MailAccountID? = nil,
        mailboxScope: MailboxScope = .inboxOnly,
        searchText: String? = nil,
        splitInboxQueryText: String? = nil,
        limit: Int = 100,
        cursor: String? = nil,
        sortOrder: ThreadListSortOrder = .newestFirst
    ) {
        self.tab = tab
        self.accountFilter = accountFilter
        self.mailboxScope = mailboxScope
        self.searchText = searchText
        self.splitInboxQueryText = splitInboxQueryText
        self.limit = limit
        self.cursor = cursor
        self.sortOrder = sortOrder
    }

    public var isSearching: Bool {
        guard let searchText else { return false }
        return !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum ReplyMode: String, Codable, Hashable, Sendable {
    case new
    case reply
    case replyAll
    case forward
}

public struct DraftQuotedReply: Codable, Hashable, Sendable {
    public var subject: String
    public var sender: MailParticipant
    public var sentAt: Date?
    public var plainBody: String?
    public var htmlBody: String?

    public init(
        subject: String,
        sender: MailParticipant,
        sentAt: Date? = nil,
        plainBody: String? = nil,
        htmlBody: String? = nil
    ) {
        self.subject = subject
        self.sender = sender
        self.sentAt = sentAt
        self.plainBody = plainBody
        self.htmlBody = htmlBody
    }
}

public struct OutgoingDraft: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var accountID: MailAccountID
    public var providerDraftID: String?
    public var providerMessageID: String?
    public var replyMode: ReplyMode
    public var threadID: MailThreadID?
    public var toRecipients: [MailParticipant]
    public var ccRecipients: [MailParticipant]
    public var bccRecipients: [MailParticipant]
    public var subject: String
    public var plainBody: String
    public var htmlBody: String?
    public var quotedReply: DraftQuotedReply?
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        accountID: MailAccountID,
        providerDraftID: String? = nil,
        providerMessageID: String? = nil,
        replyMode: ReplyMode = .new,
        threadID: MailThreadID? = nil,
        toRecipients: [MailParticipant] = [],
        ccRecipients: [MailParticipant] = [],
        bccRecipients: [MailParticipant] = [],
        subject: String = "",
        plainBody: String = "",
        htmlBody: String? = nil,
        quotedReply: DraftQuotedReply? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.accountID = accountID
        self.providerDraftID = providerDraftID
        self.providerMessageID = providerMessageID
        self.replyMode = replyMode
        self.threadID = threadID
        self.toRecipients = toRecipients
        self.ccRecipients = ccRecipients
        self.bccRecipients = bccRecipients
        self.subject = subject
        self.plainBody = plainBody
        self.htmlBody = htmlBody
        self.quotedReply = quotedReply
        self.updatedAt = updatedAt
    }
}

public struct SyncCheckpoint: Codable, Hashable, Sendable {
    public var accountID: MailAccountID
    public var payload: String
    public var lastSuccessfulSyncAt: Date?
    public var lastBackfillAt: Date?

    public init(
        accountID: MailAccountID,
        payload: String,
        lastSuccessfulSyncAt: Date? = nil,
        lastBackfillAt: Date? = nil
    ) {
        self.accountID = accountID
        self.payload = payload
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
        self.lastBackfillAt = lastBackfillAt
    }
}
