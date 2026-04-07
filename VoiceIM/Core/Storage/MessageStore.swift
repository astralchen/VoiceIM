import Foundation
import GRDB

/// 消息维度的 GRDB 读写（单会话内消息的增删改查）。
///
/// **事务约定**：每个对外方法内部至多一次 `db.write` / `db.read`，闭包内多步 SQL 同属一个 SQLite 事务。
actor MessageStore {

    static let shared = MessageStore(db: .shared)

    private let db: DatabaseManager

    init(db: DatabaseManager) {
        self.db = db
    }

    func clear(contactID: String) throws {
        try db.write { database in
            try database.execute(
                sql: "DELETE FROM messages WHERE conversation_id = ?",
                arguments: [contactID]
            )
            try GRDBStorageCore.refreshConversationLastMessage(
                conversationID: contactID, in: database
            )
        }
    }

    func getStorageSize() -> UInt64 {
        db.databaseFileSize()
    }

    func save(_ messages: [ChatMessage], contactID: String) throws {
        try db.write { database in
            try GRDBStorageCore.ensureConversationAndMembers(contactID: contactID, in: database)

            try database.execute(
                sql: "DELETE FROM messages WHERE conversation_id = ?",
                arguments: [contactID]
            )

            for (index, message) in messages.enumerated() {
                try GRDBStorageCore.insertMessageRecord(
                    message, conversationID: contactID,
                    seq: Int64(index + 1), in: database
                )
            }

            try GRDBStorageCore.refreshConversationLastMessage(
                conversationID: contactID, in: database
            )
        }
    }

    func load(contactID: String) throws -> [ChatMessage] {
        try db.read { database in
            let records = try MessageRecord
                .filter(MessageRecord.Columns.conversationID == contactID)
                .order(MessageRecord.Columns.seq.asc)
                .fetchAll(database)

            return try records.map { record in
                try GRDBStorageCore.toChatMessage(record: record, in: database)
            }
        }
    }

    func append(_ message: ChatMessage, contactID: String) throws {
        try db.write { database in
            try GRDBStorageCore.ensureConversationAndMembers(contactID: contactID, in: database)

            let nextSeq = try GRDBStorageCore.nextSeq(conversationID: contactID, in: database)
            try GRDBStorageCore.insertMessageRecord(
                message, conversationID: contactID,
                seq: nextSeq, in: database
            )

            try GRDBStorageCore.refreshConversationLastMessage(
                conversationID: contactID, in: database
            )

            // 任意新消息（发/收）若会话曾被「不显示」，则自动恢复列表可见。
            try database.execute(
                sql: """
                    UPDATE conversation_settings
                    SET is_hidden = 0, updated_at_ms = ?
                    WHERE conversation_id = ? AND user_id = ? AND is_hidden = 1
                    """,
                arguments: [GRDBStorageCore.nowMs(), contactID, Sender.me.id]
            )

            // 对方消息：递增当前用户在会话内的未读计数（与 `markConversationAsRead` 对账）。
            if !message.isOutgoing {
                try database.execute(
                    sql: """
                        UPDATE conversation_members
                        SET unread_count = unread_count + 1, updated_at_ms = ?
                        WHERE conversation_id = ? AND user_id = ?
                        """,
                    arguments: [GRDBStorageCore.nowMs(), contactID, Sender.me.id]
                )
            }
        }
    }

    func delete(id: String, contactID: String) throws {
        try db.write { database in
            try database.execute(
                sql: """
                    DELETE FROM messages
                    WHERE id = ? AND conversation_id = ?
                    """,
                arguments: [id, contactID]
            )
            try GRDBStorageCore.refreshConversationLastMessage(
                conversationID: contactID, in: database
            )
        }
    }

    func update(_ message: ChatMessage, contactID: String) throws {
        try db.write { database in
            let now = GRDBStorageCore.nowMs()
            let kindRaw = GRDBStorageCore.kindToInt(message.kind)
            let bodyText = GRDBStorageCore.bodyText(for: message.kind)
            let extJSON = GRDBStorageCore.extJSON(for: message.kind)
            let sendStatusRaw = GRDBStorageCore.sendStatusToInt(message.sendStatus)
            let recalledAtMs: Int64? = {
                if case .recalled = message.kind { return now }
                return nil
            }()

            try database.execute(
                sql: """
                    UPDATE messages
                    SET kind = ?, body_text = ?, ext_json = ?,
                        send_status = ?,
                        recalled_at_ms = ?,
                        server_at_ms = COALESCE(server_at_ms, ?)
                    WHERE id = ? AND conversation_id = ?
                    """,
                arguments: [
                    kindRaw, bodyText, extJSON,
                    sendStatusRaw,
                    recalledAtMs,
                    now,
                    message.id, contactID
                ]
            )

            try GRDBStorageCore.upsertAttachments(
                for: message, messageID: message.id, in: database
            )

            try GRDBStorageCore.mirrorIncomingReceiptsIfNeeded(
                message, messageID: message.id, in: database
            )

            try GRDBStorageCore.refreshConversationLastMessage(
                conversationID: contactID, in: database
            )
        }
    }
}
