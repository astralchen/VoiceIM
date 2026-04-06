import Foundation
import GRDB
import CryptoKit

/// 消息存储：基于 GRDB 生产级关系模型的核心读写层
///
/// # 架构位置
/// ```
/// UI 层（ViewController）
///   ↓
/// ChatViewModel / ConversationListViewModel
///   ↓
/// MessageRepository（业务逻辑：撤回/重试/文件管理）
///   ↓
/// ★ MessageStorage（数据读写：本文件）
///   ↓
/// DatabaseManager → GRDB → SQLite
/// ```
///
/// # 核心设计
/// 1. **事务一致性**：每次消息写入都在同一事务中同步更新
///    `conversations.last_message_*` 冗余字段和 `conversation_members.unread_count`，
///    避免会话列表与聊天页数据不一致。
///
/// 2. **域模型映射**：数据库使用拆分的关系表（messages + attachments + receipts），
///    对外统一返回 `ChatMessage` 域模型。映射逻辑集中在 `toChatMessage` 和 `insertMessageRecord`。
///
/// 3. **懒建会话**：首次向某联系人发消息时自动创建 conversation 和 members 记录
///    （`ensureConversationAndMembers`），上层无需显式"创建会话"。
///
/// 4. **删除策略**：消息和会话均采用物理删除，依赖外键级联清理关联表数据。
///
/// 5. **回执驱动已读**：`isRead` / `isPlayed` 不再作为消息表字段，
///    而是从 `message_receipts` 表实时查询，支持群聊多人回执。
///
/// # 线程安全
/// 使用 Swift actor 隔离。内部所有数据库操作通过 `DatabaseManager.read/write` 执行，
/// GRDB 的 `DatabaseQueue` 保证串行化。
actor MessageStorage {

    static let shared = MessageStorage()

    private let db: DatabaseManager

    private init() {
        self.db = DatabaseManager.shared
    }

    /// 测试专用初始化器，允许注入独立的内存数据库
    init(db: DatabaseManager) {
        self.db = db
    }

    // MARK: - MessageStorageProtocol

    func clear(contactID: String) throws {
        try db.write { database in
            try database.execute(
                sql: "DELETE FROM messages WHERE conversation_id = ?",
                arguments: [contactID]
            )
            try Self.refreshConversationLastMessage(
                conversationID: contactID, in: database
            )
        }
    }

    func getStorageSize() -> UInt64 {
        db.databaseFileSize()
    }

    // MARK: - 会话级写入

    /// 批量替换某会话的全部消息（用于种子数据初始化）
    ///
    /// 在同一事务中：
    /// 1. 确保会话和成员记录存在
    /// 2. 删除该会话旧消息
    /// 3. 逐条插入新消息（含附件）
    /// 4. 刷新会话冗余字段
    func save(_ messages: [ChatMessage], contactID: String) throws {
        try db.write { database in
            try Self.ensureConversationAndMembers(contactID: contactID, in: database)

            try database.execute(
                sql: "DELETE FROM messages WHERE conversation_id = ?",
                arguments: [contactID]
            )

            for (index, message) in messages.enumerated() {
                try Self.insertMessageRecord(
                    message, conversationID: contactID,
                    seq: Int64(index + 1), in: database
                )
            }

            try Self.refreshConversationLastMessage(
                conversationID: contactID, in: database
            )
        }
    }

    /// 加载某会话的全部消息（按 seq 升序）
    ///
    /// 查询路径：messages → 附件（LEFT JOIN 效果） → 回执
    func load(contactID: String) throws -> [ChatMessage] {
        try db.read { database in
            let records = try MessageRecord
                .filter(MessageRecord.Columns.conversationID == contactID)
                .order(MessageRecord.Columns.seq.asc)
                .fetchAll(database)

            return try records.map { record in
                try Self.toChatMessage(record: record, in: database)
            }
        }
    }

    /// 追加单条消息到会话
    ///
    /// 事务内完成：
    /// 1. 确保会话与成员存在（懒建会话）
    /// 2. 计算下一个 seq（`MAX(seq) + 1`）
    /// 3. 插入 messages + message_attachments
    /// 4. 刷新 conversations.last_message_*
    /// 5. 若为对方消息，递增当前用户的 unread_count
    func append(_ message: ChatMessage, contactID: String) throws {
        try db.write { database in
            try Self.ensureConversationAndMembers(contactID: contactID, in: database)

            let nextSeq = try Self.nextSeq(conversationID: contactID, in: database)
            try Self.ensureUser(message.sender, in: database)
            try Self.insertMessageRecord(
                message, conversationID: contactID,
                seq: nextSeq, in: database
            )

            try Self.refreshConversationLastMessage(
                conversationID: contactID, in: database
            )

            // 只要会话产生新消息（发送或接收），都自动取消"不显示该会话"
            try database.execute(
                sql: """
                    UPDATE conversation_settings
                    SET is_hidden = 0, updated_at_ms = ?
                    WHERE conversation_id = ? AND user_id = ? AND is_hidden = 1
                    """,
                arguments: [Self.nowMs(), contactID, Sender.me.id]
            )

            // 对方消息 → 递增"我"在这个会话的未读计数
            if !message.isOutgoing {
                try database.execute(
                    sql: """
                        UPDATE conversation_members
                        SET unread_count = unread_count + 1, updated_at_ms = ?
                        WHERE conversation_id = ? AND user_id = ?
                        """,
                    arguments: [Self.nowMs(), contactID, Sender.me.id]
                )
            }
        }
    }

    /// 物理删除消息
    func delete(id: String, contactID: String) throws {
        try db.write { database in
            try database.execute(
                sql: """
                    DELETE FROM messages
                    WHERE id = ? AND conversation_id = ?
                    """,
                arguments: [id, contactID]
            )
            // 最后一条消息可能变了，刷新冗余字段
            try Self.refreshConversationLastMessage(
                conversationID: contactID, in: database
            )
        }
    }

    /// 更新消息（撤回/状态变更/附件更新）
    ///
    /// 使用原地 UPDATE 而非删除重建，保持 seq 不变。
    /// `server_at_ms` 使用 COALESCE 保留首次服务端确认时间。
    func update(_ message: ChatMessage, contactID: String) throws {
        try db.write { database in
            let now = Self.nowMs()
            let kindRaw = Self.kindToInt(message.kind)
            let bodyText = Self.bodyText(for: message.kind)
            let extJSON = Self.extJSON(for: message.kind)
            let sendStatusRaw = Self.sendStatusToInt(message.sendStatus)

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
                    message.kind.isRecalled ? now : nil,
                    now,
                    message.id, contactID
                ]
            )

            try Self.upsertAttachments(
                for: message, messageID: message.id, in: database
            )

            try Self.mirrorIncomingReceiptsIfNeeded(
                message, messageID: message.id, in: database
            )

            try Self.refreshConversationLastMessage(
                conversationID: contactID, in: database
            )
        }
    }

    // MARK: - 会话未读（微信风格）

    /// 进入会话时调用：将该会话所有对方消息标记为已读
    ///
    /// 事务内完成：
    /// 1. 将 conversation_members.unread_count 归零
    /// 2. 将 last_read_message_seq 更新到当前最大 seq
    /// 3. 批量插入 message_receipts（仅对尚无已读回执的对方消息）
    ///
    /// 使用 `NOT EXISTS` 子查询避免重复插入回执，保证幂等性。
    func markConversationAsRead(contactID: String) throws {
        try db.write { database in
            let now = Self.nowMs()
            let maxSeq = try Int64.fetchOne(
                database,
                sql: "SELECT MAX(seq) FROM messages WHERE conversation_id = ?",
                arguments: [contactID]
            ) ?? 0

            // 1. 成员未读归零 + 更新已读水位
            try database.execute(
                sql: """
                    UPDATE conversation_members
                    SET unread_count = 0, last_read_message_seq = ?, updated_at_ms = ?
                    WHERE conversation_id = ? AND user_id = ?
                    """,
                arguments: [maxSeq, now, contactID, Sender.me.id]
            )

            // 2. 批量为对方消息写入已读回执（幂等：已有 read_at_ms 则跳过 SELECT）
            //    若仅存在「仅已播」回执行，则 ON CONFLICT 合并 read_at，避免主键冲突
            try database.execute(
                sql: """
                    INSERT INTO message_receipts (message_id, user_id, read_at_ms, played_at_ms, updated_at_ms)
                    SELECT m.id, ?, ?, NULL, ?
                    FROM messages m
                    WHERE m.conversation_id = ? AND m.sender_user_id != ?
                      AND NOT EXISTS (
                        SELECT 1 FROM message_receipts r
                        WHERE r.message_id = m.id AND r.user_id = ? AND r.read_at_ms IS NOT NULL
                      )
                    ON CONFLICT(message_id, user_id) DO UPDATE SET
                        read_at_ms = COALESCE(message_receipts.read_at_ms, excluded.read_at_ms),
                        updated_at_ms = excluded.updated_at_ms
                    """,
                arguments: [Sender.me.id, now, now, contactID, Sender.me.id, Sender.me.id]
            )
        }
    }

    /// 从会话列表移除（物理删除 `conversations` 行，外键 CASCADE 自动清理关联数据）
    func deleteConversation(contactID: String) throws {
        try db.write { database in
            try database.execute(
                sql: "DELETE FROM conversations WHERE id = ?",
                arguments: [contactID]
            )
        }
    }

    /// 查询当前用户在某会话的未读数（直接读 conversation_members，O(1)）
    func unreadCount(conversationID: String) throws -> Int {
        try db.read { database in
            try Int.fetchOne(
                database,
                sql: """
                    SELECT unread_count FROM conversation_members
                    WHERE conversation_id = ? AND user_id = ?
                    """,
                arguments: [conversationID, Sender.me.id]
            ) ?? 0
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

    // MARK: - 会话列表查询

    /// 加载会话列表：conversations LEFT JOIN conversation_members，并关联最后一条消息
    ///
    /// 返回值：`(会话记录, 当前用户未读数, 是否置顶, 预览文案, 最后消息时间毫秒)`。
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
                    previewText = Self.previewText(kind: k, bodyText: previewBody)
                } else {
                    previewText = ""
                }
                return (conv, unread, isPinned, previewText, previewMs)
            }
        }
    }

    func setConversationPinned(contactID: String, pinned: Bool) throws {
        try db.write { database in
            try Self.ensureConversationAndMembers(contactID: contactID, in: database)
            let now = Self.nowMs()
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
            try Self.ensureConversationAndMembers(contactID: contactID, in: database)
            let now = Self.nowMs()
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

    /// 获取会话最后一条可见消息的预览文本与时间戳
    ///
    /// 返回 `(预览文本, created_at_ms)` 或 nil（空会话）。
    /// 走 idx_messages_conv_seq 索引，按 seq DESC LIMIT 1。
    func lastMessagePreview(conversationID: String) throws -> (String, Int64)? {
        try db.read { database in
            guard let record = try MessageRecord
                .filter(MessageRecord.Columns.conversationID == conversationID)
                .order(MessageRecord.Columns.seq.desc)
                .fetchOne(database) else { return nil }

            let preview = Self.previewText(kind: record.kind, bodyText: record.bodyText)
            return (preview, record.createdAtMs)
        }
    }

    // MARK: - Record ↔ ChatMessage 映射

    /// 将 ChatMessage 域模型拆分写入 messages + message_attachments 两张表
    ///
    /// 拆分策略：
    /// - messages 表：存储消息元数据（kind/body_text/ext_json/send_status/时间戳）
    /// - message_attachments 表：存储媒体文件元信息（路径/URL/时长/尺寸/哈希）
    /// - message_receipts 表：写入时不操作，由 markConversationAsRead 批量处理
    private static func insertMessageRecord(
        _ message: ChatMessage,
        conversationID: String,
        seq: Int64,
        in db: Database
    ) throws {
        try ensureUser(message.sender, in: db)

        var record = MessageRecord(
            id: message.id,
            conversationID: conversationID,
            seq: seq,
            clientMsgID: message.clientMsgID,
            senderUserID: message.sender.id,
            kind: kindToInt(message.kind),
            bodyText: bodyText(for: message.kind),
            extJSON: extJSON(for: message.kind),
            sendStatus: sendStatusToInt(message.sendStatus),
            createdAtMs: Int64(message.sentAt.timeIntervalSince1970 * 1000),
            serverAtMs: nil,
            editedAtMs: nil,
            recalledAtMs: message.kind.isRecalled ? nowMs() : nil,
            deletedAtMs: nil
        )
        try record.insert(db)

        try upsertAttachments(for: message, messageID: record.id, in: db)
        try mirrorIncomingReceiptsIfNeeded(message, messageID: record.id, in: db)
    }

    /// 从 messages + attachments + receipts 三张表还原 ChatMessage 域模型
    ///
    /// 还原逻辑：
    /// 1. 从 users 表取发送者显示名
    /// 2. 从 message_attachments 取媒体元信息，重建 ChatMessage.Kind
    /// 3. 从 message_receipts 取当前用户的回执，判断 isRead / isPlayed
    ///    - 自己发的消息：isRead/isPlayed 恒为 true
    ///    - 对方消息：有 read_at_ms 回执则 isRead=true，有 played_at_ms 则 isPlayed=true
    static func toChatMessage(record: MessageRecord, in db: Database) throws -> ChatMessage {
        let sender = Sender(
            id: record.senderUserID,
            displayName: try UserRecord
                .filter(UserRecord.Columns.id == record.senderUserID)
                .fetchOne(db)?.displayName ?? record.senderUserID
        )

        let attachment = try MessageAttachmentRecord
            .filter(MessageAttachmentRecord.Columns.messageID == record.id)
            .fetchOne(db)

        let kind = buildKind(
            raw: record.kind,
            bodyText: record.bodyText,
            extJSON: record.extJSON,
            attachment: attachment,
            recalledAtMs: record.recalledAtMs
        )

        let sendStatus = intToSendStatus(record.sendStatus)

        let receipt = try MessageReceiptRecord
            .filter(MessageReceiptRecord.Columns.messageID == record.id)
            .filter(MessageReceiptRecord.Columns.userID == Sender.me.id)
            .fetchOne(db)

        let isRead = sender.id == Sender.me.id || receipt?.readAtMs != nil
        let isPlayed: Bool
        if case .voice = kind {
            isPlayed = sender.id == Sender.me.id || receipt?.playedAtMs != nil
        } else {
            isPlayed = true
        }

        return ChatMessage(
            id: record.id,
            clientMsgID: record.clientMsgID,
            kind: kind,
            sender: sender,
            sentAt: Date(timeIntervalSince1970: Double(record.createdAtMs) / 1000),
            isPlayed: isPlayed,
            isRead: isRead,
            sendStatus: sendStatus
        )
    }

    // MARK: - 懒建会话与用户

    /// 首次向某联系人发消息时自动创建会话和成员记录
    ///
    /// 幂等操作：若会话已存在则跳过。
    /// 单聊场景下自动创建"我"和"对方"两条成员记录。
    private static func ensureConversationAndMembers(
        contactID: String, in db: Database
    ) throws {
        let now = nowMs()
        let exists = try ConversationRecord
            .filter(ConversationRecord.Columns.id == contactID)
            .fetchOne(db) != nil

        if !exists {
            var conv = ConversationRecord(
                id: contactID, type: 0, title: nil, ownerUserID: nil,
                lastMessageID: nil, lastMessageAtMs: nil,
                version: 1, isMutedDefault: false,
                createdAtMs: now, updatedAtMs: now, deletedAtMs: nil
            )
            try conv.insert(db)

            try ensureUser(Sender.me, in: db)
            try ensureUser(
                Sender(id: contactID, displayName: contactID), in: db
            )

            // INSERT OR IGNORE：防止并发或重复调用导致主键冲突
            let meAsMember = ConversationMemberRecord(
                conversationID: contactID, userID: Sender.me.id,
                role: 0, joinedAtMs: now, leftAtMs: nil,
                isMuted: false, unreadCount: 0, lastReadMessageSeq: 0,
                updatedAtMs: now
            )
            try meAsMember.insert(db, onConflict: .ignore)

            let peerAsMember = ConversationMemberRecord(
                conversationID: contactID, userID: contactID,
                role: 0, joinedAtMs: now, leftAtMs: nil,
                isMuted: false, unreadCount: 0, lastReadMessageSeq: 0,
                updatedAtMs: now
            )
            try peerAsMember.insert(db, onConflict: .ignore)
        }
    }

    /// 确保用户记录存在（幂等：已存在则跳过）
    private static func ensureUser(_ sender: Sender, in db: Database) throws {
        let exists = try UserRecord
            .filter(UserRecord.Columns.id == sender.id)
            .fetchOne(db) != nil
        if !exists {
            let now = nowMs()
            var user = UserRecord(
                id: sender.id,
                displayName: sender.displayName,
                avatarURL: nil,
                status: 0,
                createdAtMs: now,
                updatedAtMs: now
            )
            try user.insert(db)
        }
    }

    /// 刷新会话的 last_message_id 和 last_message_at_ms 冗余字段
    ///
    /// 每次消息写入/删除后调用，保证会话列表排序和预览文本的正确性。
    /// 使用子查询取最后一条消息，避免额外的 SELECT + UPDATE 两次往返。
    private static func refreshConversationLastMessage(
        conversationID: String, in db: Database
    ) throws {
        let now = nowMs()
        try db.execute(
            sql: """
                UPDATE conversations SET
                  last_message_id = (
                    SELECT id FROM messages
                    WHERE conversation_id = ?
                    ORDER BY seq DESC LIMIT 1
                  ),
                  last_message_at_ms = (
                    SELECT created_at_ms FROM messages
                    WHERE conversation_id = ?
                    ORDER BY seq DESC LIMIT 1
                  ),
                  updated_at_ms = ?,
                  version = version + 1
                WHERE id = ?
                """,
            arguments: [conversationID, conversationID, now, conversationID]
        )
    }

    /// 将当前用户对「对方消息」的已读/已播状态写入 `message_receipts`，与 `toChatMessage` 读路径一致
    ///
    /// - 仅处理 `sender != 我` 的消息；自己发送的消息不写入回执（读路径恒为已读）。
    /// - 使用 `ON CONFLICT DO UPDATE` + `COALESCE`：保留首次已读/已播时间，避免覆盖。
    private static func mirrorIncomingReceiptsIfNeeded(
        _ message: ChatMessage,
        messageID: String,
        in db: Database
    ) throws {
        guard message.sender.id != Sender.me.id else { return }
        let now = nowMs()
        let readMs: Int64? = message.isRead ? now : nil
        let playedMs: Int64?
        if case .voice = message.kind {
            playedMs = message.isPlayed ? now : nil
        } else {
            playedMs = nil
        }
        guard readMs != nil || playedMs != nil else { return }
        try upsertCurrentUserReceipt(
            messageID: messageID,
            readAtMs: readMs,
            playedAtMs: playedMs,
            in: db
        )
    }

    private static func upsertCurrentUserReceipt(
        messageID: String,
        readAtMs: Int64?,
        playedAtMs: Int64?,
        in db: Database
    ) throws {
        let now = nowMs()
        try db.execute(
            sql: """
                INSERT INTO message_receipts (message_id, user_id, read_at_ms, played_at_ms, updated_at_ms)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(message_id, user_id) DO UPDATE SET
                    read_at_ms = CASE WHEN excluded.read_at_ms IS NOT NULL
                        THEN COALESCE(message_receipts.read_at_ms, excluded.read_at_ms)
                        ELSE message_receipts.read_at_ms END,
                    played_at_ms = CASE WHEN excluded.played_at_ms IS NOT NULL
                        THEN COALESCE(message_receipts.played_at_ms, excluded.played_at_ms)
                        ELSE message_receipts.played_at_ms END,
                    updated_at_ms = excluded.updated_at_ms
                """,
            arguments: [messageID, Sender.me.id, readAtMs, playedAtMs, now]
        )
    }

    /// 获取会话内下一个可用序号（当前最大 seq + 1）
    private static func nextSeq(
        conversationID: String, in db: Database
    ) throws -> Int64 {
        let current = try Int64.fetchOne(
            db,
            sql: "SELECT MAX(seq) FROM messages WHERE conversation_id = ?",
            arguments: [conversationID]
        ) ?? 0
        return current + 1
    }

    /// 写入/更新消息附件（INSERT OR REPLACE，幂等）
    ///
    /// 附件 ID 规则：`{messageID}_{mediaType}`，保证同一消息同类型附件仅一条。
    /// 仅保存文件名（lastPathComponent），读取时拼接对应缓存目录前缀。
    private static func upsertAttachments(
        for message: ChatMessage, messageID: String, in db: Database
    ) throws {
        switch message.kind {
        case .voice(let localURL, let remoteURL, let duration):
            let integrity = attachmentIntegrity(for: localURL)
            var att = MessageAttachmentRecord(
                id: "\(messageID)_voice",
                messageID: messageID,
                mediaType: 0,
                localPath: localURL?.lastPathComponent,
                remoteURL: remoteURL?.absoluteString,
                sha256: integrity?.sha256,
                sizeBytes: integrity?.sizeBytes,
                durationMs: Int64(duration * 1000),
                width: nil, height: nil,
                createdAtMs: nowMs()
            )
            try att.insert(db, onConflict: .replace)

        case .image(let localURL, let remoteURL):
            let integrity = attachmentIntegrity(for: localURL)
            var att = MessageAttachmentRecord(
                id: "\(messageID)_image",
                messageID: messageID,
                mediaType: 1,
                localPath: localURL?.lastPathComponent,
                remoteURL: remoteURL?.absoluteString,
                sha256: integrity?.sha256,
                sizeBytes: integrity?.sizeBytes,
                durationMs: nil, width: nil, height: nil,
                createdAtMs: nowMs()
            )
            try att.insert(db, onConflict: .replace)

        case .video(let localURL, let remoteURL, let duration):
            let integrity = attachmentIntegrity(for: localURL)
            var att = MessageAttachmentRecord(
                id: "\(messageID)_video",
                messageID: messageID,
                mediaType: 2,
                localPath: localURL?.lastPathComponent,
                remoteURL: remoteURL?.absoluteString,
                sha256: integrity?.sha256,
                sizeBytes: integrity?.sizeBytes,
                durationMs: Int64(duration * 1000),
                width: nil, height: nil,
                createdAtMs: nowMs()
            )
            try att.insert(db, onConflict: .replace)

        default:
            break
        }
    }

    // MARK: - 枚举 ↔ 整型映射

    /// ChatMessage.Kind → 整型（存入 messages.kind 列）
    /// 0=text, 1=voice, 2=image, 3=video, 4=recalled, 5=location
    private static func kindToInt(_ kind: ChatMessage.Kind) -> Int {
        switch kind {
        case .text:     return 0
        case .voice:    return 1
        case .image:    return 2
        case .video:    return 3
        case .recalled: return 4
        case .location: return 5
        }
    }

    /// 提取消息正文文本（text→正文，recalled→原文本，其他→nil）
    private static func bodyText(for kind: ChatMessage.Kind) -> String? {
        switch kind {
        case .text(let t): return t
        case .recalled(let original): return original
        default: return nil
        }
    }

    /// 将消息类型特有数据序列化为 JSON 字符串（存入 messages.ext_json 列）
    /// 目前仅 location 类型使用（经纬度+地址）
    private static func extJSON(for kind: ChatMessage.Kind) -> String? {
        switch kind {
        case .location(let lat, let lon, let addr):
            let obj: [String: Any?] = ["lat": lat, "lon": lon, "addr": addr]
            if let data = try? JSONSerialization.data(
                withJSONObject: obj.compactMapValues { $0 }
            ) {
                return String(data: data, encoding: .utf8)
            }
            return nil
        default:
            return nil
        }
    }

    /// 从数据库整型字段还原 ChatMessage.Kind
    ///
    /// 还原优先级：
    /// 1. recalled_at_ms 不为空 → .recalled（无论 kind 列的值）
    /// 2. kind=0 → .text
    /// 3. kind=1/2/3 → 从 attachment 表取媒体信息
    /// 4. kind=5 → 从 ext_json 解析经纬度
    private static func buildKind(
        raw: Int, bodyText: String?,
        extJSON: String?,
        attachment: MessageAttachmentRecord?,
        recalledAtMs: Int64?
    ) -> ChatMessage.Kind {
        if recalledAtMs != nil || raw == 4 {
            return .recalled(originalText: bodyText)
        }
        switch raw {
        case 0:
            return .text(bodyText ?? "")
        case 1:
            let localURL = validatedLocalURL(from: attachment, mediaType: 0)
            let remoteURL = attachment?.remoteURL.flatMap(URL.init(string:))
            let durationSec = Double(attachment?.durationMs ?? 0) / 1000
            return .voice(localURL: localURL, remoteURL: remoteURL, duration: durationSec)
        case 2:
            let localURL = validatedLocalURL(from: attachment, mediaType: 1)
            let remoteURL = attachment?.remoteURL.flatMap(URL.init(string:))
            return .image(localURL: localURL, remoteURL: remoteURL)
        case 3:
            let localURL = validatedLocalURL(from: attachment, mediaType: 2)
            let remoteURL = attachment?.remoteURL.flatMap(URL.init(string:))
            let durationSec = Double(attachment?.durationMs ?? 0) / 1000
            return .video(localURL: localURL, remoteURL: remoteURL, duration: durationSec)
        case 5:
            if let json = extJSON,
               let data = json.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let lat = obj["lat"] as? Double ?? 0
                let lon = obj["lon"] as? Double ?? 0
                let addr = obj["addr"] as? String
                return .location(latitude: lat, longitude: lon, address: addr)
            }
            return .location(latitude: 0, longitude: 0, address: nil)
        default:
            return .text(bodyText ?? "")
        }
    }

    /// ChatMessage.SendStatus → 整型
    /// 0=sending, 1=delivered, 2=read, 3=failed
    private static func sendStatusToInt(_ status: ChatMessage.SendStatus) -> Int {
        switch status {
        case .sending:   return 0
        case .delivered: return 1
        case .read:      return 2
        case .failed:    return 3
        }
    }

    /// 整型 → ChatMessage.SendStatus
    private static func intToSendStatus(_ raw: Int) -> ChatMessage.SendStatus {
        switch raw {
        case 0: return .sending
        case 1: return .delivered
        case 2: return .read
        case 3: return .failed
        default: return .delivered
        }
    }

    /// 消息类型整型 → 会话列表预览文本
    static func previewText(kind: Int, bodyText: String?) -> String {
        switch kind {
        case 0: return bodyText ?? ""
        case 1: return "[语音]"
        case 2: return "[图片]"
        case 3: return "[视频]"
        case 4: return "你撤回了一条消息"
        case 5: return "[位置]"
        default: return ""
        }
    }

    /// 当前时间戳（毫秒精度，Int64），所有时间字段统一使用此格式
    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private static func attachmentIntegrity(for localURL: URL?) -> (sha256: String, sizeBytes: Int64)? {
        guard let localURL else { return nil }
        guard FileManager.default.fileExists(atPath: localURL.path) else { return nil }
        guard let data = try? Data(contentsOf: localURL, options: .mappedIfSafe) else { return nil }
        let digest = SHA256.hash(data: data)
        let sha = digest.compactMap { String(format: "%02x", $0) }.joined()
        return (sha256: sha, sizeBytes: Int64(data.count))
    }

    /// 读取附件时执行完整性校验；校验失败会回收本地文件并降级为远端路径。
    private static func validatedLocalURL(
        from attachment: MessageAttachmentRecord?,
        mediaType: Int
    ) -> URL? {
        guard let attachment, let localPath = attachment.localPath else { return nil }
        let directoryURL: URL
        switch mediaType {
        case 0:
            directoryURL = FileStorageManager.getVoiceDirectory()
        case 1:
            directoryURL = FileStorageManager.getImageDirectory()
        case 2:
            directoryURL = FileStorageManager.getVideoDirectory()
        default:
            return nil
        }
        let localURL = directoryURL.appendingPathComponent(localPath)
        let fm = FileManager.default
        guard fm.fileExists(atPath: localURL.path) else { return nil }
        guard let data = try? Data(contentsOf: localURL, options: .mappedIfSafe) else { return nil }

        if let expectedSize = attachment.sizeBytes, expectedSize != Int64(data.count) {
            try? fm.removeItem(at: localURL)
            logger.warning("附件完整性校验失败（size_bytes 不匹配），已回收本地文件: \(localPath)")
            return nil
        }

        if let expectedHash = attachment.sha256 {
            let actualHash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
            if actualHash.caseInsensitiveCompare(expectedHash) != .orderedSame {
                try? fm.removeItem(at: localURL)
                logger.warning("附件完整性校验失败（sha256 不匹配），已回收本地文件: \(localPath)")
                return nil
            }
        }
        return localURL
    }

}

// MARK: - ChatMessage.Kind 辅助

private extension ChatMessage.Kind {
    /// 判断消息是否为撤回类型（用于写入时决定是否设置 recalled_at_ms）
    var isRecalled: Bool {
        if case .recalled = self { return true }
        return false
    }
}
