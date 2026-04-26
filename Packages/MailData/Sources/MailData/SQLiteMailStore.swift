import Foundation
import GRDB
import MailCore

public actor SQLiteMailStore: MailStore {
    private let dbQueue: DatabaseQueue
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try Self.migrate(dbQueue)
    }

    public func listAccounts() async throws -> [MailAccount] {
        try await dbQueue.read { db in
            try AccountRecord
                .order(Column("primaryEmail"))
                .fetchAll(db)
                .map { try $0.asDomain(decoder: decoder) }
        }
    }

    public func listThreads(query: ThreadListQuery) async throws -> [MailThread] {
        try await dbQueue.read { db in
            let request = Self.filteredThreadRequest(for: query, limit: query.limit)
            return try request.fetchAll(db).map { try $0.asDomain(decoder: decoder) }
        }
    }

    public func countThreads(query: ThreadListQuery) async throws -> Int {
        try await dbQueue.read { db in
            let request = Self.filteredThreadRequest(for: query, limit: nil)
            return try request.fetchCount(db)
        }
    }

    public func loadThread(id: MailThreadID) async throws -> MailThreadDetail? {
        try await dbQueue.write { db in
            guard let threadRecord = try ThreadRecord.fetchOne(db, key: id.rawValue) else {
                return nil
            }

            let messages = try MessageRecord
                .filter(Column("threadID") == id.rawValue)
                .order(Column("receivedAt"))
                .fetchAll(db)
                .map { try $0.asDomain(decoder: decoder) }

            try MessageRecord
                .filter(Column("threadID") == id.rawValue)
                .updateAll(db, Column("touchedAt").set(to: Date().timeIntervalSince1970))

            return MailThreadDetail(thread: try threadRecord.asDomain(decoder: decoder), messages: messages)
        }
    }

    public func loadCheckpoint(accountID: MailAccountID) async throws -> SyncCheckpoint? {
        try await dbQueue.read { db in
            try SyncCheckpointRecord.fetchOne(db, key: accountID.rawValue)?.asDomain()
        }
    }

    public func saveAccount(_ account: MailAccount) async throws {
        try await dbQueue.write { db in
            try AccountRecord(account: account, encoder: encoder).save(db)
        }
    }

    public func listMailboxes(accountID: MailAccountID?) async throws -> [MailboxRef] {
        try await dbQueue.read { db in
            var request = MailboxRecord.order(Column("displayName"))
            if let accountID {
                request = request.filter(Column("accountID") == accountID.rawValue)
            }
            return try request.fetchAll(db).map { $0.asDomain() }
        }
    }

    public func saveMailboxes(_ mailboxes: [MailboxRef]) async throws {
        try await dbQueue.write { db in
            for mailbox in mailboxes {
                var record = MailboxRecord(mailbox: mailbox)
                // Preserve locally-set hidden state when the incoming value is the default (false),
                // so that sync from the API doesn't overwrite user-initiated hide actions.
                if record.isHiddenInLabelList == false,
                   let existing = try MailboxRecord.fetchOne(db, key: record.id) {
                    record.isHiddenInLabelList = existing.isHiddenInLabelList
                }
                try record.save(db)
            }
        }
    }

    public func upsertThreadDetails(_ details: [MailThreadDetail], checkpoint: SyncCheckpoint?) async throws {
        try await dbQueue.write { db in
            for detail in details {
                let existingThreadDetail = try Self.loadThreadDetail(id: detail.thread.id, db: db, decoder: decoder)
                let existingMessages = try MessageRecord
                    .filter(Column("threadID") == detail.thread.id.rawValue)
                    .fetchAll(db)
                let existingByProviderID = Dictionary(uniqueKeysWithValues: existingMessages.map { ($0.providerMessageID, $0) })
                let resolvedDetail = if detail.persistenceMode == .merge, let existingThreadDetail {
                    detail.merged(with: existingThreadDetail)
                } else {
                    detail
                }

                try ThreadRecord(thread: resolvedDetail.thread, encoder: encoder).save(db)
                try MessageRecord.filter(Column("threadID") == resolvedDetail.thread.id.rawValue).deleteAll(db)
                for message in resolvedDetail.messages {
                    var record = try MessageRecord(message: message, encoder: encoder)
                    if let existing = existingByProviderID[record.providerMessageID] {
                        record.preserveBodyCache(from: existing)
                    }
                    try record.insert(db)
                }
            }

            if let checkpoint {
                try SyncCheckpointRecord(checkpoint: checkpoint).save(db)
            }
        }
    }

    public func enqueue(_ mutation: MailMutation) async throws -> UUID {
        let id = UUID()
        try await dbQueue.write { db in
            try QueuedMutationRecord(
                id: id.uuidString,
                accountID: mutation.accountID.rawValue,
                mutationJSON: String(data: try encoder.encode(mutation), encoding: .utf8) ?? "",
                createdAt: Date().timeIntervalSince1970,
                retryCount: 0,
                nextAttemptAt: nil,
                lastAttemptAt: nil,
                lastErrorDescription: nil,
                status: QueuedMailMutation.Status.pending.rawValue
            ).insert(db)
        }
        return id
    }

    public func queuedMutation(id: UUID) async throws -> QueuedMailMutation? {
        try await dbQueue.read { [decoder] db in
            try QueuedMutationRecord.fetchOne(db, key: id.uuidString)?.asDomain(decoder: decoder)
        }
    }

    public func hasPendingQueuedMutations(accountID: MailAccountID) async throws -> Bool {
        try await dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM queuedMutations
                WHERE accountID = ? AND status = ?
                """,
                arguments: [accountID.rawValue, QueuedMailMutation.Status.pending.rawValue]
            ) ?? 0 > 0
        }
    }

    public func loadReadyQueuedMutations(asOf: Date, limit: Int) async throws -> [QueuedMailMutation] {
        try await dbQueue.read { [decoder] db in
            try QueuedMutationRecord
                .filter(Column("status") == QueuedMailMutation.Status.pending.rawValue)
                .filter(sql: "nextAttemptAt IS NULL OR nextAttemptAt <= ?", arguments: [asOf.timeIntervalSince1970])
                .order(sql: "COALESCE(nextAttemptAt, createdAt) ASC, createdAt ASC")
                .limit(limit)
                .fetchAll(db)
                .map { try $0.asDomain(decoder: decoder) }
        }
    }

    public func nextQueuedMutationAttemptDate() async throws -> Date? {
        try await dbQueue.read { db in
            guard let timestamp = try Double.fetchOne(
                db,
                sql: """
                SELECT MIN(COALESCE(nextAttemptAt, createdAt))
                FROM queuedMutations
                WHERE status = ?
                """,
                arguments: [QueuedMailMutation.Status.pending.rawValue]
            ) else {
                return nil
            }
            return Date(timeIntervalSince1970: timestamp)
        }
    }

    public func completeQueuedMutation(id: UUID) async throws {
        try await dbQueue.write { db in
            _ = try QueuedMutationRecord.deleteOne(db, key: id.uuidString)
        }
    }

    public func markQueuedMutationForRetry(id: UUID, errorDescription: String, retryCount: Int, nextAttemptAt: Date) async throws {
        try await dbQueue.write { db in
            _ = try QueuedMutationRecord
                .filter(Column("id") == id.uuidString)
                .updateAll(
                    db,
                    Column("retryCount").set(to: retryCount),
                    Column("nextAttemptAt").set(to: nextAttemptAt.timeIntervalSince1970),
                    Column("lastAttemptAt").set(to: Date().timeIntervalSince1970),
                    Column("lastErrorDescription").set(to: errorDescription),
                    Column("status").set(to: QueuedMailMutation.Status.pending.rawValue)
                )
        }
    }

    public func failQueuedMutation(id: UUID, errorDescription: String) async throws {
        try await dbQueue.write { db in
            _ = try QueuedMutationRecord
                .filter(Column("id") == id.uuidString)
                .updateAll(
                    db,
                    Column("lastAttemptAt").set(to: Date().timeIntervalSince1970),
                    Column("lastErrorDescription").set(to: errorDescription),
                    Column("status").set(to: QueuedMailMutation.Status.failed.rawValue)
                )
        }
    }

    public func applyOptimistic(_ mutation: MailMutation) async throws {
        try await dbQueue.write { db in
            switch mutation {
            case let .archive(threadID):
                try ThreadRecord.filter(Column("id") == threadID.rawValue).updateAll(db, Column("isInInbox").set(to: false))
            case let .unarchive(threadID):
                try ThreadRecord.filter(Column("id") == threadID.rawValue).updateAll(db, Column("isInInbox").set(to: true))
            case let .markRead(threadID):
                try ThreadRecord.filter(Column("id") == threadID.rawValue).updateAll(db, Column("hasUnread").set(to: false))
                try MessageRecord.filter(Column("threadID") == threadID.rawValue).updateAll(db, Column("isRead").set(to: true))
            case let .markUnread(threadID):
                try ThreadRecord.filter(Column("id") == threadID.rawValue).updateAll(db, Column("hasUnread").set(to: true))
                try MessageRecord.filter(Column("threadID") == threadID.rawValue).updateAll(db, Column("isRead").set(to: false))
            case let .star(threadID):
                try ThreadRecord.filter(Column("id") == threadID.rawValue).updateAll(db, Column("isStarred").set(to: true))
            case let .unstar(threadID):
                try ThreadRecord.filter(Column("id") == threadID.rawValue).updateAll(db, Column("isStarred").set(to: false))
            case let .trash(threadID):
                try ThreadRecord.filter(Column("id") == threadID.rawValue).updateAll(db, Column("isInInbox").set(to: false))
            case let .untrash(threadID):
                try ThreadRecord.filter(Column("id") == threadID.rawValue).updateAll(db, Column("isInInbox").set(to: true))
            case let .snooze(threadID, until):
                try ThreadRecord.filter(Column("id") == threadID.rawValue).updateAll(db, Column("snoozedUntil").set(to: until.timeIntervalSince1970))
            case let .unsnooze(threadID):
                try ThreadRecord.filter(Column("id") == threadID.rawValue).updateAll(db, Column("snoozedUntil").set(to: DatabaseValue.null))
            case let .applyMailbox(threadID, mailboxID):
                try Self.updateThreadMailboxJSON(db: db, threadID: threadID, mailboxID: mailboxID, isAdding: true)
            case let .removeMailbox(threadID, mailboxID):
                try Self.updateThreadMailboxJSON(db: db, threadID: threadID, mailboxID: mailboxID, isAdding: false)
            case .send:
                break
            }
        }
    }

    public func saveSyncState(accountID: MailAccountID, _ state: MailAccountSyncState) async throws {
        try await dbQueue.write { db in
            _ = try AccountRecord
                .filter(Column("id") == accountID.rawValue)
                .updateAll(
                    db,
                    Column("syncPhase").set(to: state.phase.rawValue),
                    Column("lastSuccessfulSyncAt").set(to: state.lastSuccessfulSyncAt?.timeIntervalSince1970),
                    Column("lastErrorDescription").set(to: state.lastErrorDescription)
                )
        }
    }

    public func evictColdBodies(maxHotThreads: Int, maxAge: TimeInterval) async throws {
        try await dbQueue.write { db in
            let hotThreadIDs = try String.fetchAll(
                db,
                sql: """
                SELECT DISTINCT threadID
                FROM messages
                WHERE touchedAt IS NOT NULL
                ORDER BY touchedAt DESC
                LIMIT ?
                """,
                arguments: [maxHotThreads]
            )

            let threshold = Date().addingTimeInterval(-maxAge).timeIntervalSince1970
            if hotThreadIDs.isEmpty {
                try db.execute(
                    sql: "UPDATE messages SET plainBody = NULL, htmlBody = NULL, bodyCacheState = ? WHERE touchedAt IS NULL OR touchedAt < ?",
                    arguments: [MailBodyCacheState.cold.rawValue, threshold]
                )
            } else {
                let placeholders = hotThreadIDs.map { _ in "?" }.joined(separator: ",")
                var arguments: StatementArguments = [MailBodyCacheState.cold.rawValue, threshold]
                for threadID in hotThreadIDs {
                    _ = arguments.append(contentsOf: [threadID])
                }
                try db.execute(
                    sql: "UPDATE messages SET plainBody = NULL, htmlBody = NULL, bodyCacheState = ? WHERE (touchedAt IS NULL OR touchedAt < ?) AND threadID NOT IN (\(placeholders))",
                    arguments: arguments
                )
            }
        }
    }

    // MARK: - Local Drafts

    public func saveDraft(_ draft: OutgoingDraft) async throws {
        try await dbQueue.write { [encoder] db in
            let json = String(data: try encoder.encode(draft), encoding: .utf8) ?? "{}"
            try db.execute(
                sql: "INSERT OR REPLACE INTO localDrafts (id, draftJSON, updatedAt) VALUES (?, ?, ?)",
                arguments: [draft.id.uuidString, json, draft.updatedAt.timeIntervalSince1970]
            )
        }
    }

    public func listDrafts() async throws -> [OutgoingDraft] {
        try await dbQueue.read { [decoder] db in
            let rows = try Row.fetchAll(db, sql: "SELECT draftJSON FROM localDrafts ORDER BY updatedAt DESC")
            return rows.compactMap { row in
                guard let json = row["draftJSON"] as? String else { return nil }
                return try? decoder.decode(OutgoingDraft.self, from: Data(json.utf8))
            }
        }
    }

    public func deleteDraft(id: UUID) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM localDrafts WHERE id = ?", arguments: [id.uuidString])
        }
    }

    public func seedDemoDataIfNeeded() async throws {
        let now = Date()
        let accounts = try DemoDataFactory.makeAccounts()
        for account in accounts {
            try await saveAccount(account)
        }
        let mailboxes = try DemoDataFactory.makeMailboxes(for: accounts)
        let threads = try DemoDataFactory.makeThreads(for: accounts, now: now)
        try await saveMailboxes(mailboxes)
        try await upsertThreadDetails(threads, checkpoint: nil)
    }

    public func removeAccount(accountID: MailAccountID) async throws {
        try await dbQueue.write { [decoder] db in
            _ = try AccountRecord.deleteOne(db, key: accountID.rawValue)
            _ = try MailboxRecord.filter(Column("accountID") == accountID.rawValue).deleteAll(db)
            _ = try ThreadRecord.filter(Column("accountID") == accountID.rawValue).deleteAll(db)
            _ = try MessageRecord.filter(Column("accountID") == accountID.rawValue).deleteAll(db)
            _ = try SyncCheckpointRecord.deleteOne(db, key: accountID.rawValue)
            _ = try QueuedMutationRecord.filter(Column("accountID") == accountID.rawValue).deleteAll(db)

            let localDraftRows = try Row.fetchAll(db, sql: "SELECT id, draftJSON FROM localDrafts")
            for row in localDraftRows {
                guard let draftID = row["id"] as? String,
                      let draftJSON = row["draftJSON"] as? String,
                      let draft = try? decoder.decode(OutgoingDraft.self, from: Data(draftJSON.utf8)),
                      draft.accountID == accountID else {
                    continue
                }
                try db.execute(sql: "DELETE FROM localDrafts WHERE id = ?", arguments: [draftID])
            }
        }
    }
}

private extension SQLiteMailStore {
    static func loadThreadDetail(id: MailThreadID, db: Database, decoder: JSONDecoder) throws -> MailThreadDetail? {
        guard let threadRecord = try ThreadRecord.fetchOne(db, key: id.rawValue) else {
            return nil
        }

        let messages = try MessageRecord
            .filter(Column("threadID") == id.rawValue)
            .order(Column("receivedAt"))
            .fetchAll(db)
            .map { try $0.asDomain(decoder: decoder) }

        return MailThreadDetail(thread: try threadRecord.asDomain(decoder: decoder), messages: messages)
    }
}

private extension SQLiteMailStore {
    static func filteredThreadRequest(for query: ThreadListQuery, limit: Int?) -> QueryInterfaceRequest<ThreadRecord> {
        var request = ThreadRecord.order(Column("lastActivityAt").desc)

        switch query.tab {
        case .all:
            if query.mailboxScope != .allMail {
                request = request.filter(Column("isInInbox") == true)
            }
        case .unread:
            request = request.filter(Column("isInInbox") == true && Column("hasUnread") == true)
        case .starred:
            request = request.filter(Column("isStarred") == true)
        case .snoozed:
            // Show only currently snoozed threads
            let now = Date().timeIntervalSince1970
            request = request.filter(sql: "snoozedUntil IS NOT NULL AND snoozedUntil > ?", arguments: [now])
        }

        // Hide snoozed threads from inbox views (except .snoozed tab)
        if query.tab != .snoozed {
            let now = Date().timeIntervalSince1970
            request = request.filter(sql: "snoozedUntil IS NULL OR snoozedUntil <= ?", arguments: [now])
        }

        if let accountFilter = query.accountFilter {
            request = request.filter(Column("accountID") == accountFilter.rawValue)
        }

        switch query.mailboxScope {
        case .inboxOnly, .allMail:
            break
        case let .specific(mailboxID):
            request = request.filter(sql: "mailboxRefsJSON LIKE ?", arguments: ["%\(mailboxID.rawValue)%"])
        }

        if let splitInboxQueryText = query.splitInboxQueryText,
           !splitInboxQueryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request = applyingSplitInboxQuery(splitInboxQueryText, to: request)
        }

        if let searchText = query.searchText,
           !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let pattern = "%\(searchText)%"
            request = request.filter(
                sql: "(subject LIKE ? OR snippet LIKE ? OR participantSummary LIKE ?)",
                arguments: [pattern, pattern, pattern]
            )
        }

        if let limit {
            request = request.limit(limit)
        }

        return request
    }

    static func applyingSplitInboxQuery(
        _ queryText: String,
        to request: QueryInterfaceRequest<ThreadRecord>
    ) -> QueryInterfaceRequest<ThreadRecord> {
        var request = request

        for token in splitInboxTokens(from: queryText) {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { continue }

            let lowercase = trimmed.lowercased()
            if lowercase.hasPrefix("label:") {
                let value = normalizedQueryValue(from: trimmed.dropFirst("label:".count))
                if value.isEmpty == false {
                    request = request.filter(sql: labelMailboxExistsSQL, arguments: [value, value])
                }
                continue
            }

            if lowercase.hasPrefix("category:") {
                let value = normalizedQueryValue(from: trimmed.dropFirst("category:".count))
                if value.isEmpty == false {
                    let providerValue = "category_\(value.replacingOccurrences(of: " ", with: "_"))"
                    request = request.filter(
                        sql: categoryMailboxExistsSQL,
                        arguments: [value, value, providerValue]
                    )
                }
                continue
            }

            switch lowercase {
            case "in:inbox":
                request = request.filter(Column("isInInbox") == true)
            case "in:anywhere":
                continue
            case "is:unread":
                request = request.filter(Column("hasUnread") == true)
            case "is:read":
                request = request.filter(Column("hasUnread") == false)
            case "is:starred":
                request = request.filter(Column("isStarred") == true)
            case "is:important":
                request = request.filter(sql: importantMailboxExistsSQL)
            default:
                let pattern = "%\(trimmed)%"
                request = request.filter(
                    sql: "(subject LIKE ? OR snippet LIKE ? OR participantSummary LIKE ?)",
                    arguments: [pattern, pattern, pattern]
                )
            }
        }

        return request
    }

    static func splitInboxTokens(from queryText: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoteCharacter: Character?

        for character in queryText {
            if character == "\"" || character == "'" {
                if quoteCharacter == character {
                    quoteCharacter = nil
                } else if quoteCharacter == nil {
                    quoteCharacter = character
                } else {
                    current.append(character)
                }
                continue
            }

            if character.isWhitespace, quoteCharacter == nil {
                if current.isEmpty == false {
                    tokens.append(current)
                    current = ""
                }
                continue
            }

            current.append(character)
        }

        if current.isEmpty == false {
            tokens.append(current)
        }

        return tokens
    }

    static func normalizedQueryValue<S: StringProtocol>(from rawValue: S) -> String {
        rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static let labelMailboxExistsSQL = """
        EXISTS (
            SELECT 1
            FROM json_each(mailboxRefsJSON) mailbox
            WHERE lower(coalesce(json_extract(mailbox.value, '$.kind'), '')) = 'label'
              AND (
                  lower(coalesce(json_extract(mailbox.value, '$.displayName'), '')) = ?
                  OR lower(coalesce(json_extract(mailbox.value, '$.providerMailboxID'), '')) = ?
              )
        )
        """

    static let categoryMailboxExistsSQL = """
        EXISTS (
            SELECT 1
            FROM json_each(mailboxRefsJSON) mailbox
            WHERE (
                lower(coalesce(json_extract(mailbox.value, '$.kind'), '')) = 'category'
                OR lower(coalesce(json_extract(mailbox.value, '$.providerMailboxID'), '')) LIKE 'category_%'
            )
              AND (
                  lower(coalesce(json_extract(mailbox.value, '$.displayName'), '')) = ?
                  OR lower(coalesce(json_extract(mailbox.value, '$.providerMailboxID'), '')) = ?
                  OR lower(coalesce(json_extract(mailbox.value, '$.providerMailboxID'), '')) = ?
              )
        )
        """

    static let importantMailboxExistsSQL = """
        EXISTS (
            SELECT 1
            FROM json_each(mailboxRefsJSON) mailbox
            WHERE lower(coalesce(json_extract(mailbox.value, '$.systemRole'), '')) = 'important'
        )
        """

    static func migrate(_ dbQueue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("mail-schema-v1") { db in
            try db.create(table: "accounts") { table in
                table.column("id", .text).primaryKey()
                table.column("providerKind", .text).notNull()
                table.column("providerAccountID", .text).notNull()
                table.column("primaryEmail", .text).notNull()
                table.column("displayName", .text).notNull()
                table.column("syncPhase", .text).notNull()
                table.column("lastSuccessfulSyncAt", .double)
                table.column("lastErrorDescription", .text)
                table.column("capabilitiesJSON", .text).notNull()
            }

            try db.create(table: "mailboxes") { table in
                table.column("id", .text).primaryKey()
                table.column("accountID", .text).notNull().indexed()
                table.column("providerMailboxID", .text).notNull()
                table.column("displayName", .text).notNull()
                table.column("kind", .text).notNull()
                table.column("systemRole", .text)
                table.column("colorHex", .text)
            }

            try db.create(table: "threads") { table in
                table.column("id", .text).primaryKey()
                table.column("accountID", .text).notNull().indexed()
                table.column("providerThreadID", .text).notNull()
                table.column("subject", .text).notNull()
                table.column("participantSummary", .text).notNull()
                table.column("snippet", .text).notNull()
                table.column("lastActivityAt", .double).notNull().indexed()
                table.column("hasUnread", .boolean).notNull()
                table.column("isStarred", .boolean).notNull()
                table.column("isInInbox", .boolean).notNull()
                table.column("latestMessageID", .text)
                table.column("attachmentCount", .integer).notNull().defaults(to: 0)
                table.column("snoozedUntil", .double)
                table.column("syncRevision", .text).notNull()
                table.column("mailboxRefsJSON", .text).notNull()
            }

            try db.create(table: "messages") { table in
                table.column("id", .text).primaryKey()
                table.column("threadID", .text).notNull().indexed()
                table.column("accountID", .text).notNull().indexed()
                table.column("providerMessageID", .text).notNull()
                table.column("senderJSON", .text).notNull()
                table.column("toJSON", .text).notNull()
                table.column("ccJSON", .text).notNull()
                table.column("bccJSON", .text).notNull()
                table.column("sentAt", .double)
                table.column("receivedAt", .double).indexed()
                table.column("snippet", .text).notNull()
                table.column("plainBody", .text)
                table.column("htmlBody", .text)
                table.column("bodyCacheState", .text).notNull()
                table.column("headersJSON", .text).notNull()
                table.column("mailboxRefsJSON", .text).notNull()
                table.column("attachmentsJSON", .text).notNull().defaults(to: "[]")
                table.column("isRead", .boolean).notNull()
                table.column("isOutgoing", .boolean).notNull()
                table.column("touchedAt", .double)
            }

            try db.create(table: "syncCheckpoints") { table in
                table.column("accountID", .text).primaryKey()
                table.column("payload", .text).notNull()
                table.column("lastSuccessfulSyncAt", .double)
                table.column("lastBackfillAt", .double)
            }

            try db.create(table: "queuedMutations") { table in
                table.column("id", .text).primaryKey()
                table.column("accountID", .text).notNull().indexed()
                table.column("mutationJSON", .text).notNull()
                table.column("createdAt", .double).notNull()
                table.column("retryCount", .integer).notNull().defaults(to: 0)
                table.column("nextAttemptAt", .double)
                table.column("lastAttemptAt", .double)
                table.column("lastErrorDescription", .text)
                table.column("status", .text).notNull().defaults(to: QueuedMailMutation.Status.pending.rawValue)
            }

            try db.create(table: "localDrafts") { table in
                table.column("id", .text).primaryKey()
                table.column("draftJSON", .text).notNull()
                table.column("updatedAt", .double).notNull()
            }
        }

        migrator.registerMigration("mail-schema-v2-add-snooze") { db in
            let threadColumns = try db.columns(in: "threads").map(\.name)
            if threadColumns.contains("snoozedUntil") == false {
                try db.alter(table: "threads") { table in
                    table.add(column: "snoozedUntil", .double)
                }
            }
        }

        migrator.registerMigration("mail-schema-v3-add-thread-attachment-count") { db in
            let threadColumns = try db.columns(in: "threads").map(\.name)
            if threadColumns.contains("attachmentCount") == false {
                try db.alter(table: "threads") { table in
                    table.add(column: "attachmentCount", .integer).notNull().defaults(to: 0)
                }
            }
        }

        migrator.registerMigration("mail-schema-v4-add-message-attachments-json") { db in
            let messageColumns = try db.columns(in: "messages").map(\.name)
            if messageColumns.contains("attachmentsJSON") == false {
                try db.alter(table: "messages") { table in
                    table.add(column: "attachmentsJSON", .text).notNull().defaults(to: "[]")
                }
            }
        }

        migrator.registerMigration("mail-schema-v5-add-mailbox-hidden") { db in
            let columns = try db.columns(in: "mailboxes").map(\.name)
            if columns.contains("isHiddenInLabelList") == false {
                try db.alter(table: "mailboxes") { table in
                    table.add(column: "isHiddenInLabelList", .boolean).notNull().defaults(to: false)
                }
            }
        }

        migrator.registerMigration("mail-schema-v6-add-mailbox-text-color") { db in
            let columns = try db.columns(in: "mailboxes").map(\.name)
            if columns.contains("textColorHex") == false {
                try db.alter(table: "mailboxes") { table in
                    table.add(column: "textColorHex", .text)
                }
            }
        }

        migrator.registerMigration("mail-schema-v7-add-local-drafts-table") { db in
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS localDrafts (
                    id TEXT PRIMARY KEY NOT NULL,
                    draftJSON TEXT NOT NULL,
                    updatedAt DOUBLE NOT NULL
                )
                """
            )
        }

        migrator.registerMigration("mail-schema-v8-add-queued-mutation-retry-metadata") { db in
            let columns = try db.columns(in: "queuedMutations").map(\.name)
            if columns.contains("retryCount") == false {
                try db.alter(table: "queuedMutations") { table in
                    table.add(column: "retryCount", .integer).notNull().defaults(to: 0)
                }
            }
            if columns.contains("nextAttemptAt") == false {
                try db.alter(table: "queuedMutations") { table in
                    table.add(column: "nextAttemptAt", .double)
                }
            }
            if columns.contains("lastAttemptAt") == false {
                try db.alter(table: "queuedMutations") { table in
                    table.add(column: "lastAttemptAt", .double)
                }
            }
            if columns.contains("status") == false {
                try db.alter(table: "queuedMutations") { table in
                    table.add(column: "status", .text).notNull().defaults(to: QueuedMailMutation.Status.pending.rawValue)
                }
            }
        }

        try migrator.migrate(dbQueue)
    }

    static func updateThreadMailboxJSON(db: Database, threadID: MailThreadID, mailboxID: MailboxID, isAdding: Bool) throws {
        guard var record = try ThreadRecord.fetchOne(db, key: threadID.rawValue) else { return }
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        var mailboxes = try decoder.decode([MailboxRef].self, from: Data(record.mailboxRefsJSON.utf8))
        if isAdding {
            guard mailboxes.contains(where: { $0.id == mailboxID }) == false else { return }
            mailboxes.append(
                MailboxRef(
                    id: mailboxID,
                    accountID: mailboxID.accountID,
                    providerMailboxID: mailboxID.providerMailboxID,
                    displayName: mailboxID.providerMailboxID,
                    kind: .label
                )
            )
        } else {
            mailboxes.removeAll { $0.id == mailboxID }
        }
        record.mailboxRefsJSON = String(data: try encoder.encode(mailboxes), encoding: .utf8) ?? "[]"
        try record.update(db)
    }
}

private struct AccountRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "accounts"

    var id: String
    var providerKind: String
    var providerAccountID: String
    var primaryEmail: String
    var displayName: String
    var syncPhase: String
    var lastSuccessfulSyncAt: Double?
    var lastErrorDescription: String?
    var capabilitiesJSON: String

    init(account: MailAccount, encoder: JSONEncoder) throws {
        id = account.id.rawValue
        providerKind = account.providerKind.rawValue
        providerAccountID = account.providerAccountID
        primaryEmail = account.primaryEmail
        displayName = account.displayName
        syncPhase = account.syncState.phase.rawValue
        lastSuccessfulSyncAt = account.syncState.lastSuccessfulSyncAt?.timeIntervalSince1970
        lastErrorDescription = account.syncState.lastErrorDescription
        capabilitiesJSON = String(data: try encoder.encode(account.capabilities), encoding: .utf8) ?? "{}"
    }

    func asDomain(decoder: JSONDecoder) throws -> MailAccount {
        MailAccount(
            id: MailAccountID(rawValue: id),
            providerKind: ProviderKind(rawValue: providerKind) ?? .gmail,
            providerAccountID: providerAccountID,
            primaryEmail: primaryEmail,
            displayName: displayName,
            syncState: MailAccountSyncState(
                phase: MailAccountSyncPhase(rawValue: syncPhase) ?? .idle,
                lastSuccessfulSyncAt: lastSuccessfulSyncAt.map(Date.init(timeIntervalSince1970:)),
                lastErrorDescription: lastErrorDescription
            ),
            capabilities: try decoder.decode(MailAccountCapabilities.self, from: Data(capabilitiesJSON.utf8))
        )
    }
}

private struct MailboxRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "mailboxes"

    var id: String
    var accountID: String
    var providerMailboxID: String
    var displayName: String
    var kind: String
    var systemRole: String?
    var colorHex: String?
    var textColorHex: String?
    var isHiddenInLabelList: Bool

    init(mailbox: MailboxRef) {
        id = mailbox.id.rawValue
        accountID = mailbox.accountID.rawValue
        providerMailboxID = mailbox.providerMailboxID
        displayName = mailbox.displayName
        kind = mailbox.kind.rawValue
        systemRole = mailbox.systemRole?.rawValue
        colorHex = mailbox.colorHex
        textColorHex = mailbox.textColorHex
        isHiddenInLabelList = mailbox.isHiddenInLabelList
    }

    func asDomain() -> MailboxRef {
        MailboxRef(
            id: MailboxID(rawValue: id),
            accountID: MailAccountID(rawValue: accountID),
            providerMailboxID: providerMailboxID,
            displayName: displayName,
            kind: MailboxKind(rawValue: kind) ?? .label,
            systemRole: systemRole.flatMap(MailboxSystemRole.init(rawValue:)),
            colorHex: colorHex,
            textColorHex: textColorHex,
            isHiddenInLabelList: isHiddenInLabelList
        )
    }
}

private struct ThreadRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "threads"

    var id: String
    var accountID: String
    var providerThreadID: String
    var subject: String
    var participantSummary: String
    var snippet: String
    var lastActivityAt: Double
    var hasUnread: Bool
    var isStarred: Bool
    var isInInbox: Bool
    var latestMessageID: String?
    var attachmentCount: Int
    var snoozedUntil: Double?
    var syncRevision: String
    var mailboxRefsJSON: String

    init(thread: MailThread, encoder: JSONEncoder) throws {
        id = thread.id.rawValue
        accountID = thread.accountID.rawValue
        providerThreadID = thread.providerThreadID
        subject = thread.subject
        participantSummary = thread.participantSummary
        snippet = thread.snippet
        lastActivityAt = thread.lastActivityAt.timeIntervalSince1970
        hasUnread = thread.hasUnread
        isStarred = thread.isStarred
        isInInbox = thread.isInInbox
        latestMessageID = thread.latestMessageID?.rawValue
        attachmentCount = thread.attachmentCount
        snoozedUntil = thread.snoozedUntil?.timeIntervalSince1970
        syncRevision = thread.syncRevision
        mailboxRefsJSON = String(data: try encoder.encode(thread.mailboxRefs), encoding: .utf8) ?? "[]"
    }

    func asDomain(decoder: JSONDecoder) throws -> MailThread {
        MailThread(
            id: MailThreadID(rawValue: id),
            accountID: MailAccountID(rawValue: accountID),
            providerThreadID: providerThreadID,
            subject: subject,
            participantSummary: participantSummary,
            snippet: snippet,
            lastActivityAt: Date(timeIntervalSince1970: lastActivityAt),
            hasUnread: hasUnread,
            isStarred: isStarred,
            isInInbox: isInInbox,
            mailboxRefs: try decoder.decode([MailboxRef].self, from: Data(mailboxRefsJSON.utf8)),
            latestMessageID: latestMessageID.map(MailMessageID.init(rawValue:)),
            attachmentCount: attachmentCount,
            snoozedUntil: snoozedUntil.map(Date.init(timeIntervalSince1970:)),
            syncRevision: syncRevision
        )
    }
}

private struct MessageRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "messages"

    var id: String
    var threadID: String
    var accountID: String
    var providerMessageID: String
    var senderJSON: String
    var toJSON: String
    var ccJSON: String
    var bccJSON: String
    var sentAt: Double?
    var receivedAt: Double?
    var snippet: String
    var plainBody: String?
    var htmlBody: String?
    var bodyCacheState: String
    var headersJSON: String
    var mailboxRefsJSON: String
    var attachmentsJSON: String
    var isRead: Bool
    var isOutgoing: Bool
    var touchedAt: Double?

    init(message: MailMessage, encoder: JSONEncoder) throws {
        id = message.id.rawValue
        threadID = message.threadID.rawValue
        accountID = message.accountID.rawValue
        providerMessageID = message.providerMessageID
        senderJSON = String(data: try encoder.encode(message.sender), encoding: .utf8) ?? "{}"
        toJSON = String(data: try encoder.encode(message.toRecipients), encoding: .utf8) ?? "[]"
        ccJSON = String(data: try encoder.encode(message.ccRecipients), encoding: .utf8) ?? "[]"
        bccJSON = String(data: try encoder.encode(message.bccRecipients), encoding: .utf8) ?? "[]"
        sentAt = message.sentAt?.timeIntervalSince1970
        receivedAt = message.receivedAt?.timeIntervalSince1970
        snippet = message.snippet
        plainBody = message.plainBody
        htmlBody = message.htmlBody
        bodyCacheState = message.bodyCacheState.rawValue
        headersJSON = String(data: try encoder.encode(message.headers), encoding: .utf8) ?? "[]"
        mailboxRefsJSON = String(data: try encoder.encode(message.mailboxRefs), encoding: .utf8) ?? "[]"
        attachmentsJSON = String(data: try encoder.encode(message.attachments), encoding: .utf8) ?? "[]"
        isRead = message.isRead
        isOutgoing = message.isOutgoing
        touchedAt = nil
    }

    func asDomain(decoder: JSONDecoder) throws -> MailMessage {
        MailMessage(
            id: MailMessageID(rawValue: id),
            threadID: MailThreadID(rawValue: threadID),
            accountID: MailAccountID(rawValue: accountID),
            providerMessageID: providerMessageID,
            sender: try decoder.decode(MailParticipant.self, from: Data(senderJSON.utf8)),
            toRecipients: try decoder.decode([MailParticipant].self, from: Data(toJSON.utf8)),
            ccRecipients: try decoder.decode([MailParticipant].self, from: Data(ccJSON.utf8)),
            bccRecipients: try decoder.decode([MailParticipant].self, from: Data(bccJSON.utf8)),
            sentAt: sentAt.map(Date.init(timeIntervalSince1970:)),
            receivedAt: receivedAt.map(Date.init(timeIntervalSince1970:)),
            snippet: snippet,
            plainBody: plainBody,
            htmlBody: htmlBody,
            bodyCacheState: MailBodyCacheState(rawValue: bodyCacheState) ?? .missing,
            headers: try decoder.decode([MessageHeader].self, from: Data(headersJSON.utf8)),
            mailboxRefs: try decoder.decode([MailboxRef].self, from: Data(mailboxRefsJSON.utf8)),
            attachments: (try? decoder.decode([MailAttachment].self, from: Data(attachmentsJSON.utf8))) ?? [],
            isRead: isRead,
            isOutgoing: isOutgoing
        )
    }

    mutating func preserveBodyCache(from existing: MessageRecord) {
        if bodyCacheState == MailBodyCacheState.missing.rawValue || bodyCacheState == MailBodyCacheState.cold.rawValue {
            if existing.plainBody != nil || existing.htmlBody != nil {
                plainBody = existing.plainBody
                htmlBody = existing.htmlBody
                bodyCacheState = existing.bodyCacheState
                touchedAt = existing.touchedAt
            }
        }

        if attachmentsJSON == "[]", existing.attachmentsJSON != "[]" {
            attachmentsJSON = existing.attachmentsJSON
        }
    }
}

private struct SyncCheckpointRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "syncCheckpoints"

    var accountID: String
    var payload: String
    var lastSuccessfulSyncAt: Double?
    var lastBackfillAt: Double?

    init(checkpoint: SyncCheckpoint) {
        accountID = checkpoint.accountID.rawValue
        payload = checkpoint.payload
        lastSuccessfulSyncAt = checkpoint.lastSuccessfulSyncAt?.timeIntervalSince1970
        lastBackfillAt = checkpoint.lastBackfillAt?.timeIntervalSince1970
    }

    func asDomain() -> SyncCheckpoint {
        SyncCheckpoint(
            accountID: MailAccountID(rawValue: accountID),
            payload: payload,
            lastSuccessfulSyncAt: lastSuccessfulSyncAt.map(Date.init(timeIntervalSince1970:)),
            lastBackfillAt: lastBackfillAt.map(Date.init(timeIntervalSince1970:))
        )
    }
}

private struct QueuedMutationRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "queuedMutations"

    var id: String
    var accountID: String
    var mutationJSON: String
    var createdAt: Double
    var retryCount: Int
    var nextAttemptAt: Double?
    var lastAttemptAt: Double?
    var lastErrorDescription: String?
    var status: String

    func asDomain(decoder: JSONDecoder) throws -> QueuedMailMutation {
        QueuedMailMutation(
            id: UUID(uuidString: id) ?? UUID(),
            accountID: MailAccountID(rawValue: accountID),
            mutation: try decoder.decode(MailMutation.self, from: Data(mutationJSON.utf8)),
            createdAt: Date(timeIntervalSince1970: createdAt),
            retryCount: retryCount,
            nextAttemptAt: nextAttemptAt.map(Date.init(timeIntervalSince1970:)),
            lastAttemptAt: lastAttemptAt.map(Date.init(timeIntervalSince1970:)),
            lastErrorDescription: lastErrorDescription,
            status: QueuedMailMutation.Status(rawValue: status) ?? .pending
        )
    }
}
