import Foundation
import GRDB

/// 会话列表、设置与物理删除等会话维度的 GRDB 能力。
///
/// **与 `ReceiptStore` 的关系**：`markConversationAsRead` / `unreadCount` 与回执层共用 `GRDBStorageCore` 实现，避免分叉 SQL。
actor ConversationStore {

    static let shared = ConversationStore(db: .shared)

    private let db: DatabaseManager

    init(db: DatabaseManager) {
        self.db = db
    }

    func markConversationAsRead(contactID: String) throws {
        try db.write { database in
            try GRDBStorageCore.markConversationAsRead(contactID: contactID, in: database)
        }
    }

    func unreadCount(conversationID: String) throws -> Int {
        try db.read { database in
            try GRDBStorageCore.unreadCount(conversationID: conversationID, in: database)
        }
    }

    func loadAllConversationIDs() throws -> [String] {
        try db.read { database in
            try String.fetchAll(
                database,
                sql: "SELECT id FROM conversations"
            )
        }
    }

    /// 一次 SQL 拉齐会话行、当前用户未读、置顶、最后一条消息预览（避免对每条会话再查库）。
    func loadConversationSummaries() throws -> [(ConversationRecord, Int, Bool, String, Int64?)] {
        try db.read { database in
            let rows = try Row.fetchAll(database, sql: """
                SELECT c.*, COALESCE(cm.unread_count, 0) AS member_unread_count,
                       COALESCE(cs.is_pinned, 0) AS is_pinned,
                       lm.kind AS preview_kind,
                       lm.body_text AS preview_body_text,
                       lm.created_at_ms AS preview_created_ms
                FROM conversations c
                LEFT JOIN conversation_members cm
                  ON cm.conversation_id = c.id AND cm.user_id = ?
                LEFT JOIN conversation_settings cs
                  ON cs.conversation_id = c.id AND cs.user_id = ?
                LEFT JOIN messages lm ON lm.id = (
                    SELECT m.id FROM messages m
                    WHERE m.conversation_id = c.id
                    ORDER BY m.seq DESC LIMIT 1
                )
                WHERE COALESCE(cs.is_hidden, 0) = 0
                ORDER BY
                    COALESCE(cs.is_pinned, 0) DESC,
                    COALESCE(c.last_message_at_ms, c.created_at_ms, 0) DESC,
                    c.id ASC
                """, arguments: [Sender.me.id, Sender.me.id])

            return try rows.map { row in
                let conv = try ConversationRecord(row: row)
                let unread: Int = row["member_unread_count"]
                let isPinnedRaw: Int = row["is_pinned"]
                let isPinned = isPinnedRaw != 0
                let previewKind: Int? = row["preview_kind"]
                let previewBody: String? = row["preview_body_text"]
                let previewMs: Int64? = row["preview_created_ms"]
                let previewText: String
                if let k = previewKind {
                    previewText = GRDBStorageCore.previewText(kind: k, bodyText: previewBody)
                } else {
                    previewText = ""
                }
                return (conv, unread, isPinned, previewText, previewMs)
            }
        }
    }

    func lastMessagePreview(conversationID: String) throws -> (String, Int64)? {
        try db.read { database in
            guard let record = try MessageRecord
                .filter(MessageRecord.Columns.conversationID == conversationID)
                .order(MessageRecord.Columns.seq.desc)
                .fetchOne(database) else { return nil }

            let preview = GRDBStorageCore.previewText(kind: record.kind, bodyText: record.bodyText)
            return (preview, record.createdAtMs)
        }
    }

    func setConversationPinned(contactID: String, pinned: Bool) throws {
        try db.write { database in
            try GRDBStorageCore.ensureConversationAndMembers(contactID: contactID, in: database)
            let now = GRDBStorageCore.nowMs()
            try database.execute(
                sql: """
                    INSERT INTO conversation_settings (conversation_id, user_id, is_pinned, is_hidden, mute_until_ms, updated_at_ms)
                    VALUES (?, ?, ?, false, NULL, ?)
                    ON CONFLICT(conversation_id, user_id) DO UPDATE SET
                        is_pinned = excluded.is_pinned,
                        updated_at_ms = excluded.updated_at_ms
                    """,
                arguments: [contactID, Sender.me.id, pinned, now]
            )
        }
    }

    func setConversationHidden(contactID: String, hidden: Bool) throws {
        try db.write { database in
            try GRDBStorageCore.ensureConversationAndMembers(contactID: contactID, in: database)
            let now = GRDBStorageCore.nowMs()
            try database.execute(
                sql: """
                    INSERT INTO conversation_settings (conversation_id, user_id, is_pinned, is_hidden, mute_until_ms, updated_at_ms)
                    VALUES (?, ?, false, ?, NULL, ?)
                    ON CONFLICT(conversation_id, user_id) DO UPDATE SET
                        is_hidden = excluded.is_hidden,
                        updated_at_ms = excluded.updated_at_ms
                    """,
                arguments: [contactID, Sender.me.id, hidden, now]
            )
        }
    }

    func deleteConversation(contactID: String) throws {
        try db.write { database in
            try database.execute(
                sql: "DELETE FROM conversations WHERE id = ?",
                arguments: [contactID]
            )
        }
    }
}
