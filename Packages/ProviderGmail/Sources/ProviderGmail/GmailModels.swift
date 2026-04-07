import Foundation
import MailCore
import ProviderCore

enum GmailHistoryThreadFetchPlan: Sendable, Hashable {
    case full
    case metadata
    case incrementalMessageIDs([String])
}

struct GmailProfileResponse: Decodable {
    let emailAddress: String
    let historyId: String?
}

struct GmailUserInfoResponse: Decodable {
    let sub: String?
    let email: String
    let name: String?
}

struct GmailLabelListResponse: Decodable {
    let labels: [GmailLabel]
}

struct GmailLabel: Decodable {
    struct Color: Decodable {
        let backgroundColor: String?
        let textColor: String?
    }

    let id: String
    let name: String
    let type: String?
    let color: Color?
    let labelListVisibility: String?

    func asMailbox(accountID: MailAccountID) -> MailboxRef {
        MailboxRef(
            id: MailboxID(accountID: accountID, providerMailboxID: id),
            accountID: accountID,
            providerMailboxID: id,
            displayName: name,
            kind: type == "system" ? .system : .label,
            systemRole: GmailMailboxRoleMapper.role(for: id),
            colorHex: color?.backgroundColor,
            textColorHex: color?.textColor,
            isHiddenInLabelList: labelListVisibility == "labelHide" || labelListVisibility == "labelShowIfUnread"
        )
    }
}

struct GmailThreadListResponse: Decodable {
    struct ThreadReference: Decodable {
        let id: String
    }

    let threads: [ThreadReference]?
    let nextPageToken: String?
    let resultSizeEstimate: Int
    let historyId: String?
}

struct GmailHistoryResponse: Decodable {
    struct Entry: Decodable {
        struct ChangedMessage: Decodable {
            let message: GmailHistoryMessage?
        }

        struct LabelChange: Decodable {
            let message: GmailHistoryMessage?
            let labelIds: [String]?
        }

        struct GmailHistoryMessage: Decodable {
            let id: String?
            let threadId: String?
        }

        let messagesAdded: [ChangedMessage]?
        let messagesDeleted: [ChangedMessage]?
        let labelsAdded: [LabelChange]?
        let labelsRemoved: [LabelChange]?

        var threadIDs: [String] {
            let full = (messagesAdded ?? []).compactMap { $0.message?.threadId }
            let deleted = (messagesDeleted ?? []).compactMap { $0.message?.threadId }
            let addedLabels = (labelsAdded ?? []).compactMap { $0.message?.threadId }
            let removedLabels = (labelsRemoved ?? []).compactMap { $0.message?.threadId }
            let all = full + deleted + addedLabels + removedLabels
            return Array(Set(all))
        }

        var threadFetchPlans: [String: GmailHistoryThreadFetchPlan] {
            let addedByThread = Dictionary(grouping: messagesAdded ?? [], by: { $0.message?.threadId ?? "" })
            let deletedThreads = Set((messagesDeleted ?? []).compactMap { $0.message?.threadId })
            let labelChangesByThread = Dictionary(
                grouping: (labelsAdded ?? []) + (labelsRemoved ?? []),
                by: { $0.message?.threadId ?? "" }
            )
            let threadIDs = Set(threadIDs)

            return threadIDs.reduce(into: [:]) { plans, threadID in
                let addedMessageIDs = Set(addedByThread[threadID, default: []].compactMap { $0.message?.id })
                let changedLabelMessageIDs = Set(labelChangesByThread[threadID, default: []].compactMap { $0.message?.id })

                if deletedThreads.contains(threadID) {
                    plans[threadID] = .full
                } else if addedMessageIDs.isEmpty == false {
                    if changedLabelMessageIDs.subtracting(addedMessageIDs).isEmpty {
                        plans[threadID] = .incrementalMessageIDs(Array(addedMessageIDs).sorted())
                    } else {
                        plans[threadID] = .full
                    }
                } else {
                    plans[threadID] = .metadata
                }
            }
        }
    }

    let history: [Entry]
    let historyId: String?
    let nextPageToken: String?
}

extension GmailHistoryResponse {
    var historyID: String? { historyId }

    var threadFetchPlans: [String: GmailHistoryThreadFetchPlan] {
        history.reduce(into: [:]) { plans, entry in
            for (threadID, plan) in entry.threadFetchPlans {
                if plans[threadID] == .full {
                    continue
                }
                if case .full = plan {
                    plans[threadID] = .full
                } else if case let .incrementalMessageIDs(messageIDs) = plan {
                    if case let .incrementalMessageIDs(existingIDs) = plans[threadID] {
                        plans[threadID] = .incrementalMessageIDs(Array(Set(existingIDs).union(messageIDs)).sorted())
                    } else {
                        plans[threadID] = .incrementalMessageIDs(messageIDs)
                    }
                } else if plans[threadID] == nil {
                    plans[threadID] = .metadata
                }
            }
        }
    }
}

struct GmailThreadResponse: Decodable {
    let id: String
    let snippet: String?
    let historyId: String?
    let messages: [GmailMessage]

    func asThreadDetail(accountID: MailAccountID, mailboxLookup: [String: MailboxRef], primaryEmail: String) -> MailThreadDetail {
        let threadID = MailThreadID(accountID: accountID, providerThreadID: id)
        let mappedMessages = messages.map { $0.asMailMessage(accountID: accountID, threadID: threadID, mailboxLookup: mailboxLookup, primaryEmail: primaryEmail) }
            .sorted { ($0.receivedAt ?? .distantPast) < ($1.receivedAt ?? .distantPast) }

        let newestMessage = mappedMessages.max(by: { ($0.receivedAt ?? .distantPast) < ($1.receivedAt ?? .distantPast) })
        let threadMailboxRefs = Array(Set(mappedMessages.flatMap(\.mailboxRefs))).sorted { $0.displayName < $1.displayName }
        let subject = newestMessage?.headers.first(where: { $0.name.caseInsensitiveCompare("Subject") == .orderedSame })?.value ?? "(No subject)"
        let senderNames = Array(NSOrderedSet(array: mappedMessages.map(\.sender.displayName))) as? [String] ?? []
        let participantSummary = senderNames.prefix(2).joined(separator: ", ")
        let snippet = mappedMessages.last?.snippet.isEmpty == false ? mappedMessages.last?.snippet ?? "" : (self.snippet ?? "")
        let lastActivityAt = newestMessage?.receivedAt ?? newestMessage?.sentAt ?? .distantPast
        let hasUnread = mappedMessages.contains(where: { !$0.isRead })
        let isStarred = mappedMessages.contains { $0.mailboxRefs.contains(where: { $0.systemRole == .starred }) }
        let isInInbox = mappedMessages.contains { $0.mailboxRefs.contains(where: { $0.systemRole == .inbox }) }

        let thread = MailThread(
            id: threadID,
            accountID: accountID,
            providerThreadID: id,
            subject: subject,
            participantSummary: participantSummary.isEmpty ? newestMessage?.sender.displayName ?? primaryEmail : participantSummary,
            snippet: snippet,
            lastActivityAt: lastActivityAt,
            hasUnread: hasUnread,
            isStarred: isStarred,
            isInInbox: isInInbox,
            mailboxRefs: threadMailboxRefs,
            latestMessageID: newestMessage?.id,
            attachmentCount: mappedMessages.reduce(0) { $0 + $1.attachments.count },
            syncRevision: historyId ?? id
        )

        return MailThreadDetail(thread: thread, messages: mappedMessages)
    }
}

struct GmailAttachmentResponse: Decodable {
    let data: String?
    let size: Int?
}

struct GmailMessage: Decodable {
    struct Payload: Decodable {
        struct Body: Decodable {
            let attachmentId: String?
            let size: Int?
            let data: String?
        }

        struct Header: Decodable {
            let name: String
            let value: String
        }

        let partId: String?
        let mimeType: String?
        let filename: String?
        let headers: [Header]?
        let body: Body?
        let parts: [Payload]?
    }

    let id: String
    let threadId: String
    let historyId: String?
    let labelIds: [String]?
    let snippet: String?
    let internalDate: String?
    let payload: Payload
}

extension GmailMessage {
    func asMailMessage(accountID: MailAccountID, threadID: MailThreadID, mailboxLookup: [String: MailboxRef], primaryEmail: String) -> MailMessage {
        let bodies = GmailBodyExtractor.extract(from: payload)
        let headers = (payload.headers ?? []).map { MessageHeader(name: $0.name, value: $0.value) }
        let headerLookup = Dictionary(headers.map { ($0.name.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        let sender = MailParticipant(string: headerLookup["from"] ?? primaryEmail)
        let to = MailParticipant.list(from: headerLookup["to"])
        let cc = MailParticipant.list(from: headerLookup["cc"])
        let bcc = MailParticipant.list(from: headerLookup["bcc"])
        let receivedAt = internalDate.flatMap { TimeInterval($0).map { Date(timeIntervalSince1970: $0 / 1_000) } }
        let mailboxes = (labelIds ?? []).compactMap { mailboxLookup[$0] }
        let isRead = !(labelIds ?? []).contains("UNREAD")
        let isOutgoing = sender.emailAddress.caseInsensitiveCompare(primaryEmail) == .orderedSame
        let messageID = MailMessageID(accountID: accountID, providerMessageID: id)
        let attachments = GmailAttachmentExtractor.extract(from: payload, messageID: messageID)

        return MailMessage(
            id: messageID,
            threadID: threadID,
            accountID: accountID,
            providerMessageID: id,
            sender: sender,
            toRecipients: to,
            ccRecipients: cc,
            bccRecipients: bcc,
            sentAt: MailDateParser.messageDate(from: headerLookup["date"]),
            receivedAt: receivedAt,
            snippet: snippet ?? "",
            plainBody: bodies.plain,
            htmlBody: bodies.html,
            bodyCacheState: bodies.plain == nil && bodies.html == nil ? .missing : .hot,
            headers: headers,
            mailboxRefs: mailboxes,
            attachments: attachments,
            isRead: isRead,
            isOutgoing: isOutgoing
        )
    }
}

struct GmailModifyRequest: Encodable {
    let addLabelIds: [String]
    let removeLabelIds: [String]
}

struct GmailSendRequest: Encodable {
    let raw: String
    let threadId: String?
}

struct GmailSendResponse: Decodable {
    let id: String
    let threadId: String?
}

struct GmailDraftListResponse: Decodable {
    struct DraftReference: Decodable {
        let id: String
    }

    let drafts: [DraftReference]?
    let nextPageToken: String?
}

struct GmailDraftMessageRequest: Encodable {
    let raw: String
    let threadId: String?
}

struct GmailDraftUpsertRequest: Encodable {
    let message: GmailDraftMessageRequest
}

struct GmailDraftSendRequest: Encodable {
    let id: String
}

struct GmailDraftResponse: Decodable {
    let id: String
    let message: GmailMessage
}
