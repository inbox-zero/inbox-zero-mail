import Foundation
import MailCore

enum DemoDataFactory {
    static func makeAccounts() -> [MailAccount] {
        [
            MailAccount(
                id: MailAccountID(rawValue: "gmail:alpha.inbox@example.com"),
                providerKind: .gmail,
                providerAccountID: "alpha.inbox@example.com",
                primaryEmail: "alpha.inbox@example.com",
                displayName: "Alpha Inbox",
                capabilities: .init(supportsArchive: true, supportsLabels: true, supportsCompose: true)
            ),
            MailAccount(
                id: MailAccountID(rawValue: "gmail:beta.inbox@example.com"),
                providerKind: .gmail,
                providerAccountID: "beta.inbox@example.com",
                primaryEmail: "beta.inbox@example.com",
                displayName: "Beta Inbox",
                capabilities: .init(supportsArchive: true, supportsLabels: true, supportsCompose: true)
            ),
            MailAccount(
                id: MailAccountID(rawValue: "microsoft:gamma.outlook@example.com"),
                providerKind: .microsoft,
                providerAccountID: "gamma.outlook@example.com",
                primaryEmail: "gamma.outlook@example.com",
                displayName: "Gamma Outlook",
                capabilities: .init(
                    supportsArchive: true,
                    supportsFolders: true,
                    supportsCategories: true,
                    supportsCompose: true
                )
            ),
        ]
    }

    static func makeMailboxes(for accounts: [MailAccount]) -> [MailboxRef] {
        accounts.flatMap { account in
            switch account.providerKind {
            case .gmail:
                return [
                    mailbox("INBOX", "Inbox", account: account, kind: .system, systemRole: .inbox),
                    mailbox("STARRED", "Starred", account: account, kind: .system, systemRole: .starred),
                    mailbox("SENT", "Sent", account: account, kind: .system, systemRole: .sent),
                    mailbox("ARCHIVE", "Archive", account: account, kind: .system, systemRole: .archive),
                    mailbox("Label_ops", "Ops/Review", account: account, kind: .label, colorHex: "#DDEEFF", textColorHex: "#111111"),
                    mailbox("Label_customers", "Customers", account: account, kind: .label, colorHex: "#E0F7EC", textColorHex: "#0F3D2E"),
                    mailbox("Label_newsletters", "Newsletters", account: account, kind: .label, colorHex: "#F3E8FF", textColorHex: "#3D2463"),
                    mailbox("Label_marketing", "Marketing", account: account, kind: .label, colorHex: "#FFE8D6", textColorHex: "#5A2B0C"),
                    mailbox("Label_receipts", "Receipts", account: account, kind: .label, colorHex: "#E7F0FF", textColorHex: "#17345C"),
                    mailbox("Label_travel", "Travel", account: account, kind: .label, colorHex: "#FFF7CC", textColorHex: "#4D3B00"),
                ]
            case .microsoft:
                return [
                    mailbox("inbox", "Inbox", account: account, kind: .system, systemRole: .inbox),
                    mailbox("sentitems", "Sent", account: account, kind: .system, systemRole: .sent),
                    mailbox("archive", "Archive", account: account, kind: .system, systemRole: .archive),
                    mailbox("Category_follow_up", "Follow Up", account: account, kind: .category, colorHex: "#DDEEFF", textColorHex: "#111111"),
                    mailbox("Category_legal", "Legal", account: account, kind: .category, colorHex: "#FCE7F3", textColorHex: "#5B173E"),
                    mailbox("Category_product", "Product", account: account, kind: .category, colorHex: "#E0F2FE", textColorHex: "#12344D"),
                    mailbox("Category_finance", "Finance", account: account, kind: .category, colorHex: "#DCFCE7", textColorHex: "#14532D"),
                    mailbox("Category_newsletters", "Newsletters", account: account, kind: .category, colorHex: "#F3E8FF", textColorHex: "#3D2463"),
                ]
            }
        }
    }

    static func makeThreads(for accounts: [MailAccount], now: Date) -> [MailThreadDetail] {
        let mailboxes = makeMailboxes(for: accounts)
        let mailboxLookup = Dictionary(uniqueKeysWithValues: mailboxes.map { ($0.id.rawValue, $0) })

        return threadSeeds().compactMap { seed in
            guard let account = accounts.first(where: { $0.primaryEmail == seed.accountEmail }) else {
                return nil
            }

            let threadID = MailThreadID(accountID: account.id, providerThreadID: seed.id)
            let mailboxRefs = seed.mailboxProviderIDs.compactMap { providerMailboxID in
                mailboxLookup[MailboxID(accountID: account.id, providerMailboxID: providerMailboxID).rawValue]
            }

            let messages = seed.messages.enumerated().map { index, messageSeed in
                let providerMessageID = "\(seed.id)-message-\(index + 1)"
                let messageID = MailMessageID(accountID: account.id, providerMessageID: providerMessageID)
                let sentAt = now.addingTimeInterval(TimeInterval(-messageSeed.minutesAgo * 60))
                let sender = messageSeed.isOutgoing
                    ? MailParticipant(name: account.displayName, emailAddress: account.primaryEmail)
                    : MailParticipant(name: messageSeed.senderName, emailAddress: messageSeed.senderEmail)
                let toRecipients = messageSeed.isOutgoing
                    ? [MailParticipant(name: messageSeed.senderName, emailAddress: messageSeed.senderEmail)]
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
                    snippet: messageSeed.snippet,
                    plainBody: messageSeed.plainBody,
                    htmlBody: messageSeed.htmlBody,
                    bodyCacheState: .hot,
                    headers: messageSeed.headers + [MessageHeader(name: "Subject", value: seed.subject)],
                    mailboxRefs: mailboxRefs,
                    attachments: messageSeed.attachments.map { attachment in
                        MailAttachment(
                            id: "\(providerMessageID)-\(attachment.id)",
                            messageID: messageID,
                            filename: attachment.filename,
                            mimeType: attachment.mimeType,
                            size: attachment.size
                        )
                    },
                    isRead: messageSeed.isRead,
                    isOutgoing: messageSeed.isOutgoing
                )
            }

            guard let latestMessage = messages.max(by: { messageDate($0) < messageDate($1) }) else {
                return nil
            }

            return MailThreadDetail(
                thread: MailThread(
                    id: threadID,
                    accountID: account.id,
                    providerThreadID: seed.id,
                    subject: seed.subject,
                    participantSummary: seed.participantSummary,
                    snippet: latestMessage.snippet,
                    lastActivityAt: messageDate(latestMessage),
                    hasUnread: messages.contains { !$0.isRead },
                    isStarred: seed.mailboxProviderIDs.contains("STARRED"),
                    isInInbox: seed.isInInbox,
                    mailboxRefs: mailboxRefs,
                    latestMessageID: latestMessage.id,
                    attachmentCount: messages.reduce(0) { $0 + $1.attachments.count },
                    snoozedUntil: seed.snoozedForMinutes.map { now.addingTimeInterval(TimeInterval($0 * 60)) },
                    syncRevision: "demo-\(seed.id)"
                ),
                messages: messages
            )
        }
    }

    private static func mailbox(
        _ providerMailboxID: String,
        _ displayName: String,
        account: MailAccount,
        kind: MailboxKind,
        systemRole: MailboxSystemRole? = nil,
        colorHex: String? = nil,
        textColorHex: String? = nil
    ) -> MailboxRef {
        MailboxRef(
            id: MailboxID(accountID: account.id, providerMailboxID: providerMailboxID),
            accountID: account.id,
            providerMailboxID: providerMailboxID,
            displayName: displayName,
            kind: kind,
            systemRole: systemRole,
            colorHex: colorHex,
            textColorHex: textColorHex
        )
    }

    private static func messageDate(_ message: MailMessage) -> Date {
        message.receivedAt ?? message.sentAt ?? .distantPast
    }
}

private extension DemoDataFactory {
    struct ThreadSeed {
        var id: String
        var accountEmail: String
        var subject: String
        var participantSummary: String
        var mailboxProviderIDs: [String]
        var isInInbox: Bool = true
        var snoozedForMinutes: Int?
        var messages: [MessageSeed]
    }

    struct MessageSeed {
        var senderName: String
        var senderEmail: String
        var minutesAgo: Int
        var snippet: String
        var plainBody: String
        var htmlBody: String?
        var isRead: Bool = true
        var isOutgoing: Bool = false
        var headers: [MessageHeader] = []
        var attachments: [AttachmentSeed] = []
    }

    struct AttachmentSeed {
        var id: String
        var filename: String
        var mimeType: String
        var size: Int
    }

    static func threadSeeds() -> [ThreadSeed] {
        alphaThreads() + betaThreads() + gammaThreads()
    }

    static func alphaThreads() -> [ThreadSeed] {
        [
            ThreadSeed(
                id: "alpha-release-checklist",
                accountEmail: "alpha.inbox@example.com",
                subject: "Release checklist",
                participantSummary: "Ops Desk, Alpha Inbox",
                mailboxProviderIDs: ["INBOX", "STARRED", "Label_ops"],
                messages: [
                    MessageSeed(
                        senderName: "Ops Desk",
                        senderEmail: "ops@example.com",
                        minutesAgo: 8,
                        snippet: "Action needed on the release checklist before the screenshot build.",
                        plainBody: "Please confirm the archive, star, reply, snooze, and account switching flows before we capture screenshots.",
                        isRead: false,
                        attachments: [AttachmentSeed(id: "pdf", filename: "release-readiness.pdf", mimeType: "application/pdf", size: 482_000)]
                    ),
                    MessageSeed(
                        senderName: "Ops Desk",
                        senderEmail: "ops@example.com",
                        minutesAgo: 42,
                        snippet: "The release checklist is ready for final review.",
                        plainBody: "The release checklist now covers screenshots, test accounts, QA notes, and customer-facing copy.",
                        isRead: true
                    ),
                ]
            ),
            ThreadSeed(
                id: "alpha-support-escalations",
                accountEmail: "alpha.inbox@example.com",
                subject: "Escalation queue for Monday",
                participantSummary: "Support",
                mailboxProviderIDs: ["INBOX", "Label_ops", "Label_customers"],
                messages: [
                    MessageSeed(
                        senderName: "Support",
                        senderEmail: "support@example.com",
                        minutesAgo: 24,
                        snippet: "Six customer escalations are waiting for triage in the ops queue.",
                        plainBody: "We have six customer escalations waiting for triage. Two mention sync delays, three ask about account switching, and one needs a billing review.",
                        isRead: false
                    ),
                ]
            ),
            ThreadSeed(
                id: "alpha-design-polish",
                accountEmail: "alpha.inbox@example.com",
                subject: "List view polish review",
                participantSummary: "Design",
                mailboxProviderIDs: ["INBOX", "Label_ops"],
                messages: [
                    MessageSeed(
                        senderName: "Design",
                        senderEmail: "design@example.com",
                        minutesAgo: 61,
                        snippet: "Keyboard focus states and empty states are ready for a final pass.",
                        plainBody: "The new list view needs a stronger selected row state, a clearer empty archive view, and a denser account filter menu before sign-off.",
                        isRead: true
                    ),
                ]
            ),
            ThreadSeed(
                id: "alpha-infrastructure-invoice",
                accountEmail: "alpha.inbox@example.com",
                subject: "April infrastructure invoice",
                participantSummary: "Cloud Billing",
                mailboxProviderIDs: ["INBOX", "Label_receipts"],
                messages: [
                    MessageSeed(
                        senderName: "Cloud Billing",
                        senderEmail: "billing@example.com",
                        minutesAgo: 95,
                        snippet: "The draft infrastructure invoice is attached and ready for review.",
                        plainBody: "Your April infrastructure invoice includes compute, storage, email emulator, and observability usage.",
                        isRead: true,
                        attachments: [AttachmentSeed(id: "invoice", filename: "invoice-april.csv", mimeType: "text/csv", size: 74_000)]
                    ),
                ]
            ),
            ThreadSeed(
                id: "alpha-product-digest",
                accountEmail: "alpha.inbox@example.com",
                subject: "Weekly product digest",
                participantSummary: "Product Digest",
                mailboxProviderIDs: ["INBOX", "Label_newsletters"],
                messages: [
                    MessageSeed(
                        senderName: "Product Digest",
                        senderEmail: "digest@example.com",
                        minutesAgo: 132,
                        snippet: "This week: faster search, quieter notifications, and better keyboard navigation.",
                        plainBody: "This week covers faster search, quieter notifications, keyboard navigation updates, and links to the most useful product teardown notes.",
                        htmlBody: "<h1>Weekly product digest</h1><p>This week: faster search, quieter notifications, and better keyboard navigation.</p>",
                        isRead: true,
                        headers: [MessageHeader(name: "List-Unsubscribe", value: "<mailto:unsubscribe@example.com>")]
                    ),
                ]
            ),
            ThreadSeed(
                id: "alpha-launch-assets",
                accountEmail: "alpha.inbox@example.com",
                subject: "Screenshot launch assets approved",
                participantSummary: "Marketing",
                mailboxProviderIDs: ["INBOX", "Label_marketing"],
                messages: [
                    MessageSeed(
                        senderName: "Marketing",
                        senderEmail: "marketing@example.com",
                        minutesAgo: 180,
                        snippet: "Final app screenshots, newsletter copy, and launch timing are approved.",
                        plainBody: "The final screenshots should show unified inbox, split inbox, snoozed, and account filter states. Please capture both light and dark appearances.",
                        isRead: false,
                        attachments: [AttachmentSeed(id: "deck", filename: "launch-screenshots.pptx", mimeType: "application/vnd.openxmlformats-officedocument.presentationml.presentation", size: 1_540_000)]
                    ),
                ]
            ),
            ThreadSeed(
                id: "alpha-board-travel",
                accountEmail: "alpha.inbox@example.com",
                subject: "Board meeting travel receipt",
                participantSummary: "Travel Desk",
                mailboxProviderIDs: ["INBOX", "Label_travel", "Label_receipts"],
                messages: [
                    MessageSeed(
                        senderName: "Travel Desk",
                        senderEmail: "travel@example.com",
                        minutesAgo: 260,
                        snippet: "Your receipt and itinerary for the board meeting trip are attached.",
                        plainBody: "Your hotel receipt, flight itinerary, and calendar details for the board meeting trip are attached for reimbursement.",
                        isRead: true,
                        attachments: [
                            AttachmentSeed(id: "receipt", filename: "hotel-receipt.pdf", mimeType: "application/pdf", size: 238_000),
                            AttachmentSeed(id: "itinerary", filename: "itinerary.ics", mimeType: "text/calendar", size: 12_000),
                        ]
                    ),
                ]
            ),
            ThreadSeed(
                id: "alpha-customer-rollout",
                accountEmail: "alpha.inbox@example.com",
                subject: "Customer rollout window",
                participantSummary: "Customer Team, Alpha Inbox",
                mailboxProviderIDs: ["INBOX", "Label_customers"],
                messages: [
                    MessageSeed(
                        senderName: "Customer Team",
                        senderEmail: "customer@example.com",
                        minutesAgo: 350,
                        snippet: "Please confirm the rollout window and owner list.",
                        plainBody: "Can you confirm the rollout window, owner list, and rollback contact before tomorrow morning?",
                        isRead: true
                    ),
                    MessageSeed(
                        senderName: "Customer Team",
                        senderEmail: "customer@example.com",
                        minutesAgo: 320,
                        snippet: "I added the migration notes to the shared doc.",
                        plainBody: "I added the migration notes to the shared doc and highlighted the two accounts that need manual verification.",
                        isRead: true
                    ),
                    MessageSeed(
                        senderName: "Customer Team",
                        senderEmail: "customer@example.com",
                        minutesAgo: 310,
                        snippet: "Thanks, the revised window works for us.",
                        plainBody: "Thanks, the revised rollout window works for us. Please send the final owner list when it is ready.",
                        isRead: true,
                        isOutgoing: true
                    ),
                ]
            ),
            ThreadSeed(
                id: "alpha-renewal-snoozed",
                accountEmail: "alpha.inbox@example.com",
                subject: "Renewal negotiation notes",
                participantSummary: "Procurement",
                mailboxProviderIDs: ["INBOX", "Label_customers"],
                snoozedForMinutes: 1_440,
                messages: [
                    MessageSeed(
                        senderName: "Procurement",
                        senderEmail: "procurement@example.com",
                        minutesAgo: 560,
                        snippet: "Let's revisit the renewal terms after the stakeholder meeting.",
                        plainBody: "Let's revisit the renewal terms after the stakeholder meeting. The security questionnaire and pricing notes are attached.",
                        isRead: true,
                        attachments: [AttachmentSeed(id: "zip", filename: "renewal-pack.zip", mimeType: "application/zip", size: 2_800_000)]
                    ),
                ]
            ),
            ThreadSeed(
                id: "alpha-security-report-archived",
                accountEmail: "alpha.inbox@example.com",
                subject: "Security report closed",
                participantSummary: "Security",
                mailboxProviderIDs: ["ARCHIVE", "Label_ops"],
                isInInbox: false,
                messages: [
                    MessageSeed(
                        senderName: "Security",
                        senderEmail: "security@example.com",
                        minutesAgo: 1_380,
                        snippet: "The quarterly security report is closed with no blocking issues.",
                        plainBody: "The quarterly security report is closed. Two informational findings were logged and neither blocks the release.",
                        isRead: true
                    ),
                ]
            ),
        ]
    }

    static func betaThreads() -> [ThreadSeed] {
        [
            ThreadSeed(
                id: "beta-vip-migration",
                accountEmail: "beta.inbox@example.com",
                subject: "VIP migration timeline",
                participantSummary: "VIP Customer",
                mailboxProviderIDs: ["INBOX", "STARRED", "Label_customers"],
                messages: [
                    MessageSeed(
                        senderName: "VIP Customer",
                        senderEmail: "vip.customer@example.com",
                        minutesAgo: 16,
                        snippet: "Please send the final migration timeline and owner list.",
                        plainBody: "Please send the final migration timeline, owner list, and escalation path so our support team can prepare the announcement.",
                        isRead: false
                    ),
                ]
            ),
            ThreadSeed(
                id: "beta-hiring-debrief",
                accountEmail: "beta.inbox@example.com",
                subject: "Hiring debrief",
                participantSummary: "Recruiting",
                mailboxProviderIDs: ["INBOX", "Label_ops"],
                messages: [
                    MessageSeed(
                        senderName: "Recruiting",
                        senderEmail: "recruiting@example.com",
                        minutesAgo: 74,
                        snippet: "Candidate feedback is in and we need a decision by end of day.",
                        plainBody: "Candidate feedback is in. Product recommends a final systems interview, engineering is a hire, and design wants one more portfolio pass.",
                        isRead: false
                    ),
                ]
            ),
            ThreadSeed(
                id: "beta-investor-update",
                accountEmail: "beta.inbox@example.com",
                subject: "Investor update draft",
                participantSummary: "Founders",
                mailboxProviderIDs: ["INBOX", "STARRED", "Label_marketing"],
                messages: [
                    MessageSeed(
                        senderName: "Founders",
                        senderEmail: "founders@example.com",
                        minutesAgo: 118,
                        snippet: "Can you tighten the product metrics section before tonight?",
                        plainBody: "Can you tighten the product metrics section before tonight? The screenshot captions and customer quotes are already in the draft.",
                        isRead: false,
                        attachments: [AttachmentSeed(id: "doc", filename: "investor-update-draft.pdf", mimeType: "application/pdf", size: 690_000)]
                    ),
                ]
            ),
            ThreadSeed(
                id: "beta-campaign-performance",
                accountEmail: "beta.inbox@example.com",
                subject: "Campaign performance snapshot",
                participantSummary: "Growth",
                mailboxProviderIDs: ["INBOX", "Label_marketing"],
                messages: [
                    MessageSeed(
                        senderName: "Growth",
                        senderEmail: "growth@example.com",
                        minutesAgo: 205,
                        snippet: "The screenshot campaign outperformed the benchmark by 18 percent.",
                        plainBody: "The screenshot campaign outperformed the benchmark by 18 percent. The best performing creative shows account filtering and snoozed mail.",
                        isRead: true,
                        attachments: [AttachmentSeed(id: "sheet", filename: "campaign-performance.xlsx", mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", size: 420_000)]
                    ),
                ]
            ),
            ThreadSeed(
                id: "beta-leadership-digest",
                accountEmail: "beta.inbox@example.com",
                subject: "Engineering leadership digest",
                participantSummary: "Leadership Weekly",
                mailboxProviderIDs: ["INBOX", "Label_newsletters"],
                messages: [
                    MessageSeed(
                        senderName: "Leadership Weekly",
                        senderEmail: "newsletter@example.com",
                        minutesAgo: 300,
                        snippet: "Decision logs, product strategy notes, and hiring benchmarks for the week.",
                        plainBody: "This issue covers decision logs, product strategy notes, hiring benchmarks, and a teardown of high-signal email triage workflows.",
                        htmlBody: "<h1>Engineering leadership digest</h1><p>Decision logs, product strategy notes, and hiring benchmarks.</p>",
                        isRead: true,
                        headers: [MessageHeader(name: "List-Unsubscribe", value: "<mailto:unsubscribe-newsletter@example.com>")]
                    ),
                ]
            ),
            ThreadSeed(
                id: "beta-figma-receipt",
                accountEmail: "beta.inbox@example.com",
                subject: "Figma invoice for April",
                participantSummary: "Figma",
                mailboxProviderIDs: ["INBOX", "Label_receipts"],
                messages: [
                    MessageSeed(
                        senderName: "Figma",
                        senderEmail: "billing@figma.example.com",
                        minutesAgo: 420,
                        snippet: "Your Figma invoice for April is available.",
                        plainBody: "Your April invoice is available. The team plan includes designers, editors, and prototype review seats.",
                        isRead: true,
                        attachments: [AttachmentSeed(id: "pdf", filename: "figma-invoice-april.pdf", mimeType: "application/pdf", size: 154_000)]
                    ),
                ]
            ),
            ThreadSeed(
                id: "beta-community-mention",
                accountEmail: "beta.inbox@example.com",
                subject: "Community mention: keyboard shortcuts",
                participantSummary: "Community",
                mailboxProviderIDs: ["INBOX", "Label_customers"],
                messages: [
                    MessageSeed(
                        senderName: "Community",
                        senderEmail: "community@example.com",
                        minutesAgo: 510,
                        snippet: "A customer thread called out the new keyboard shortcuts.",
                        plainBody: "A customer thread called out the new keyboard shortcuts and asked whether the account switcher can be controlled without the mouse.",
                        isRead: true
                    ),
                ]
            ),
            ThreadSeed(
                id: "beta-board-packet-snoozed",
                accountEmail: "beta.inbox@example.com",
                subject: "Board packet edits",
                participantSummary: "Board Assistant",
                mailboxProviderIDs: ["INBOX", "Label_ops"],
                snoozedForMinutes: 2_880,
                messages: [
                    MessageSeed(
                        senderName: "Board Assistant",
                        senderEmail: "board@example.com",
                        minutesAgo: 740,
                        snippet: "The board packet edits can wait until the finance section lands.",
                        plainBody: "The board packet edits can wait until the finance section lands. Please review the hiring plan before the next reminder.",
                        isRead: true
                    ),
                ]
            ),
            ThreadSeed(
                id: "beta-onboarding-archived",
                accountEmail: "beta.inbox@example.com",
                subject: "Onboarding checklist completed",
                participantSummary: "People Ops",
                mailboxProviderIDs: ["ARCHIVE", "Label_ops"],
                isInInbox: false,
                messages: [
                    MessageSeed(
                        senderName: "People Ops",
                        senderEmail: "people@example.com",
                        minutesAgo: 1_680,
                        snippet: "The onboarding checklist is complete and has been archived.",
                        plainBody: "The onboarding checklist is complete. Device setup, policy review, and manager syncs are all marked done.",
                        isRead: true
                    ),
                ]
            ),
        ]
    }

    static func gammaThreads() -> [ThreadSeed] {
        [
            ThreadSeed(
                id: "gamma-contract-redlines",
                accountEmail: "gamma.outlook@example.com",
                subject: "Contract redlines",
                participantSummary: "Legal",
                mailboxProviderIDs: ["inbox", "Category_legal", "Category_follow_up"],
                messages: [
                    MessageSeed(
                        senderName: "Legal",
                        senderEmail: "legal@example.com",
                        minutesAgo: 33,
                        snippet: "Enterprise redlines are attached and need review before Friday.",
                        plainBody: "The enterprise redlines are attached and need review before Friday. The only open points are data retention and notice periods.",
                        isRead: false,
                        attachments: [AttachmentSeed(id: "docx", filename: "enterprise-redlines.docx", mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", size: 356_000)]
                    ),
                ]
            ),
            ThreadSeed(
                id: "gamma-enterprise-onboarding",
                accountEmail: "gamma.outlook@example.com",
                subject: "Enterprise onboarding queue",
                participantSummary: "Support",
                mailboxProviderIDs: ["inbox", "Category_follow_up"],
                messages: [
                    MessageSeed(
                        senderName: "Support",
                        senderEmail: "support@example.com",
                        minutesAgo: 88,
                        snippet: "Three enterprise customers are waiting on onboarding steps.",
                        plainBody: "Three enterprise customers are waiting on onboarding steps. One needs Microsoft OAuth help and two need shared inbox import checks.",
                        isRead: false
                    ),
                ]
            ),
            ThreadSeed(
                id: "gamma-outlook-parity",
                accountEmail: "gamma.outlook@example.com",
                subject: "Outlook parity review",
                participantSummary: "Product",
                mailboxProviderIDs: ["inbox", "Category_product"],
                messages: [
                    MessageSeed(
                        senderName: "Product",
                        senderEmail: "product@example.com",
                        minutesAgo: 150,
                        snippet: "We need a final pass on Outlook parity before the next demo.",
                        plainBody: "We need a final pass on Outlook parity before the next demo. Please verify categories, folders, attachments, and account switching.",
                        isRead: true
                    ),
                ]
            ),
            ThreadSeed(
                id: "gamma-finance-export",
                accountEmail: "gamma.outlook@example.com",
                subject: "Finance export ready",
                participantSummary: "Finance",
                mailboxProviderIDs: ["inbox", "Category_finance"],
                messages: [
                    MessageSeed(
                        senderName: "Finance",
                        senderEmail: "finance@example.com",
                        minutesAgo: 240,
                        snippet: "The revised cloud budget export is ready for review.",
                        plainBody: "The revised cloud budget export is ready for review. The sheet separates emulator, CI, and production usage.",
                        isRead: true,
                        attachments: [AttachmentSeed(id: "csv", filename: "cloud-budget.csv", mimeType: "text/csv", size: 88_000)]
                    ),
                ]
            ),
            ThreadSeed(
                id: "gamma-microsoft-digest",
                accountEmail: "gamma.outlook@example.com",
                subject: "Microsoft partner newsletter",
                participantSummary: "Partner Digest",
                mailboxProviderIDs: ["inbox", "Category_newsletters"],
                messages: [
                    MessageSeed(
                        senderName: "Partner Digest",
                        senderEmail: "partners@example.com",
                        minutesAgo: 360,
                        snippet: "Updates on Graph APIs, Teams workflows, and admin consent changes.",
                        plainBody: "This partner newsletter covers Graph APIs, Teams workflows, admin consent changes, and productivity app launch examples.",
                        htmlBody: "<h1>Microsoft partner newsletter</h1><p>Graph APIs, Teams workflows, and admin consent changes.</p>",
                        isRead: true,
                        headers: [MessageHeader(name: "List-Unsubscribe", value: "<mailto:unsubscribe-partner@example.com>")]
                    ),
                ]
            ),
            ThreadSeed(
                id: "gamma-partner-cosell",
                accountEmail: "gamma.outlook@example.com",
                subject: "Partner co-sell launch",
                participantSummary: "Partner Team",
                mailboxProviderIDs: ["inbox", "Category_product", "Category_follow_up"],
                messages: [
                    MessageSeed(
                        senderName: "Partner Team",
                        senderEmail: "partner@example.com",
                        minutesAgo: 470,
                        snippet: "The co-sell launch package needs app screenshots and security copy.",
                        plainBody: "The co-sell launch package needs app screenshots, security copy, and a short paragraph explaining multi-account triage.",
                        isRead: true
                    ),
                ]
            ),
            ThreadSeed(
                id: "gamma-security-alert",
                accountEmail: "gamma.outlook@example.com",
                subject: "Security alert policy update",
                participantSummary: "Security",
                mailboxProviderIDs: ["inbox", "Category_follow_up"],
                messages: [
                    MessageSeed(
                        senderName: "Security",
                        senderEmail: "security@example.com",
                        minutesAgo: 610,
                        snippet: "Please approve the updated security alert policy.",
                        plainBody: "Please approve the updated security alert policy. The new policy lowers severity for expected emulator login attempts.",
                        isRead: false
                    ),
                ]
            ),
            ThreadSeed(
                id: "gamma-travel-archived",
                accountEmail: "gamma.outlook@example.com",
                subject: "Conference travel completed",
                participantSummary: "Travel Desk",
                mailboxProviderIDs: ["archive"],
                isInInbox: false,
                messages: [
                    MessageSeed(
                        senderName: "Travel Desk",
                        senderEmail: "travel@example.com",
                        minutesAgo: 1_920,
                        snippet: "Conference travel is complete and the reimbursement packet was filed.",
                        plainBody: "Conference travel is complete and the reimbursement packet was filed. The receipts are stored in the finance folder.",
                        isRead: true
                    ),
                ]
            ),
        ]
    }
}
