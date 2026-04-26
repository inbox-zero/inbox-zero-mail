import Foundation
import MailCore

enum DemoDataFactory {
    static func makeAccounts() throws -> [MailAccount] {
        try loadSeed().accounts.map { account in
            MailAccount(
                id: MailAccountID(rawValue: account.id),
                providerKind: account.providerKind,
                providerAccountID: account.providerAccountID,
                primaryEmail: account.primaryEmail,
                displayName: account.displayName,
                capabilities: MailAccountCapabilities(
                    supportsArchive: account.capabilities.supportsArchive,
                    supportsLabels: account.capabilities.supportsLabels,
                    supportsFolders: account.capabilities.supportsFolders,
                    supportsCategories: account.capabilities.supportsCategories,
                    supportsCompose: account.capabilities.supportsCompose
                )
            )
        }
    }

    static func makeMailboxes(for accounts: [MailAccount]) throws -> [MailboxRef] {
        let seed = try loadSeed()
        let accountsByEmail = Dictionary(uniqueKeysWithValues: accounts.map { ($0.primaryEmail, $0) })

        return try seed.mailboxes.map { mailbox in
            guard let account = accountsByEmail[mailbox.accountEmail] else {
                throw DemoSeedError.unknownAccount(mailbox.accountEmail)
            }

            return MailboxRef(
                id: MailboxID(accountID: account.id, providerMailboxID: mailbox.providerMailboxID),
                accountID: account.id,
                providerMailboxID: mailbox.providerMailboxID,
                displayName: mailbox.displayName,
                kind: mailbox.kind,
                systemRole: mailbox.systemRole,
                colorHex: mailbox.colorHex,
                textColorHex: mailbox.textColorHex
            )
        }
    }

    static func makeThreads(for accounts: [MailAccount], now: Date) throws -> [MailThreadDetail] {
        let seed = try loadSeed()
        let accountsByEmail = Dictionary(uniqueKeysWithValues: accounts.map { ($0.primaryEmail, $0) })
        let mailboxes = try makeMailboxes(for: accounts)
        let mailboxLookup = Dictionary(uniqueKeysWithValues: mailboxes.map { ($0.id.rawValue, $0) })

        return try seed.threads.map { threadSeed in
            guard let account = accountsByEmail[threadSeed.accountEmail] else {
                throw DemoSeedError.unknownAccount(threadSeed.accountEmail)
            }

            let mailboxRefs = try threadSeed.mailboxProviderIDs.map { providerMailboxID in
                let mailboxID = MailboxID(accountID: account.id, providerMailboxID: providerMailboxID)
                guard let mailbox = mailboxLookup[mailboxID.rawValue] else {
                    throw DemoSeedError.unknownMailbox(account.primaryEmail, providerMailboxID)
                }
                return mailbox
            }

            let threadID = MailThreadID(accountID: account.id, providerThreadID: threadSeed.id)
            let messages = threadSeed.messages.enumerated().map { index, messageSeed in
                makeMessage(
                    seed: messageSeed,
                    index: index,
                    account: account,
                    threadID: threadID,
                    subject: threadSeed.subject,
                    mailboxRefs: mailboxRefs,
                    now: now
                )
            }

            guard let latestMessage = messages.max(by: { messageDate($0) < messageDate($1) }) else {
                throw DemoSeedError.emptyThread(threadSeed.id)
            }

            return MailThreadDetail(
                thread: MailThread(
                    id: threadID,
                    accountID: account.id,
                    providerThreadID: threadSeed.id,
                    subject: threadSeed.subject,
                    participantSummary: threadSeed.participantSummary,
                    snippet: latestMessage.snippet,
                    lastActivityAt: messageDate(latestMessage),
                    hasUnread: messages.contains { !$0.isRead },
                    isStarred: mailboxRefs.contains { $0.systemRole == .starred },
                    isInInbox: threadSeed.isInInbox ?? true,
                    mailboxRefs: mailboxRefs,
                    latestMessageID: latestMessage.id,
                    attachmentCount: messages.reduce(0) { $0 + $1.attachments.count },
                    snoozedUntil: threadSeed.snoozedForMinutes.map { now.addingTimeInterval(TimeInterval($0 * 60)) },
                    syncRevision: "demo-\(threadSeed.id)"
                ),
                messages: messages
            )
        }
    }

    private static func makeMessage(
        seed: DemoMessageSeed,
        index: Int,
        account: MailAccount,
        threadID: MailThreadID,
        subject: String,
        mailboxRefs: [MailboxRef],
        now: Date
    ) -> MailMessage {
        let providerMessageID = "\(threadID.providerThreadID)-message-\(index + 1)"
        let messageID = MailMessageID(accountID: account.id, providerMessageID: providerMessageID)
        let sentAt = now.addingTimeInterval(TimeInterval(-seed.minutesAgo * 60))
        let isOutgoing = seed.isOutgoing ?? false
        let sender = isOutgoing
            ? MailParticipant(name: account.displayName, emailAddress: account.primaryEmail)
            : MailParticipant(name: seed.senderName, emailAddress: seed.senderEmail)
        let toRecipients = isOutgoing
            ? [MailParticipant(name: seed.senderName, emailAddress: seed.senderEmail)]
            : [MailParticipant(name: account.displayName, emailAddress: account.primaryEmail)]

        return MailMessage(
            id: messageID,
            threadID: threadID,
            accountID: account.id,
            providerMessageID: providerMessageID,
            sender: sender,
            toRecipients: toRecipients,
            sentAt: sentAt,
            receivedAt: sentAt,
            snippet: seed.snippet,
            plainBody: seed.plainBody,
            htmlBody: seed.htmlBody,
            bodyCacheState: .hot,
            headers: (seed.headers ?? []) + [MessageHeader(name: "Subject", value: subject)],
            mailboxRefs: mailboxRefs,
            attachments: (seed.attachments ?? []).map { attachment in
                MailAttachment(
                    id: "\(providerMessageID)-\(attachment.id)",
                    messageID: messageID,
                    filename: attachment.filename,
                    mimeType: attachment.mimeType,
                    size: attachment.size
                )
            },
            isRead: seed.isRead ?? true,
            isOutgoing: isOutgoing
        )
    }

    private static func messageDate(_ message: MailMessage) -> Date {
        message.receivedAt ?? message.sentAt ?? .distantPast
    }

    private static func loadSeed() throws -> DemoSeed {
        guard let url = Bundle.module.url(forResource: "demo-seed", withExtension: "json") else {
            throw DemoSeedError.missingResource
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(DemoSeed.self, from: data)
    }
}

private enum DemoSeedError: Error, CustomStringConvertible {
    case missingResource
    case unknownAccount(String)
    case unknownMailbox(String, String)
    case emptyThread(String)

    var description: String {
        switch self {
        case .missingResource:
            "Missing demo-seed.json resource."
        case let .unknownAccount(email):
            "Demo seed references unknown account \(email)."
        case let .unknownMailbox(email, providerMailboxID):
            "Demo seed references unknown mailbox \(providerMailboxID) for \(email)."
        case let .emptyThread(id):
            "Demo seed thread \(id) must include at least one message."
        }
    }
}

private struct DemoSeed: Decodable {
    var accounts: [DemoAccountSeed]
    var mailboxes: [DemoMailboxSeed]
    var threads: [DemoThreadSeed]
}

private struct DemoAccountSeed: Decodable {
    var id: String
    var providerKind: ProviderKind
    var providerAccountID: String
    var primaryEmail: String
    var displayName: String
    var capabilities: DemoAccountCapabilitiesSeed
}

private struct DemoAccountCapabilitiesSeed: Decodable {
    var supportsArchive: Bool
    var supportsLabels: Bool
    var supportsFolders: Bool
    var supportsCategories: Bool
    var supportsCompose: Bool
}

private struct DemoMailboxSeed: Decodable {
    var accountEmail: String
    var providerMailboxID: String
    var displayName: String
    var kind: MailboxKind
    var systemRole: MailboxSystemRole?
    var colorHex: String?
    var textColorHex: String?
}

private struct DemoThreadSeed: Decodable {
    var id: String
    var accountEmail: String
    var subject: String
    var participantSummary: String
    var mailboxProviderIDs: [String]
    var isInInbox: Bool?
    var snoozedForMinutes: Int?
    var messages: [DemoMessageSeed]
}

private struct DemoMessageSeed: Decodable {
    var senderName: String
    var senderEmail: String
    var minutesAgo: Int
    var snippet: String
    var plainBody: String
    var htmlBody: String?
    var isRead: Bool?
    var isOutgoing: Bool?
    var headers: [MessageHeader]?
    var attachments: [DemoAttachmentSeed]?
}

private struct DemoAttachmentSeed: Decodable {
    var id: String
    var filename: String
    var mimeType: String
    var size: Int
}
