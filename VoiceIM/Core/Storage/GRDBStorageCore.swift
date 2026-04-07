import Foundation
import GRDB
import CryptoKit

/// GRDB 持久化共享逻辑：映射、懒建会话、回执与附件写入。
///
/// **为何集中在此**：避免 `MessageStore` / `ConversationStore` / `ReceiptStore` 重复大段 SQL 与域映射；
/// 各 Store 在**单次** `DatabaseManager.write/read` 闭包内调用本类型，保证同一事务内多表一致。
enum GRDBStorageCore {

    // MARK: - 消息写入

    /// 将单条 `ChatMessage` 拆成 `messages` 行 + 可选 `message_attachments`，并视需要镜像回执（对方消息）。
    static func insertMessageRecord(
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
            recalledAtMs: isRecalledKind(message.kind) ? nowMs() : nil,
            deletedAtMs: nil
        )
        try record.insert(db)

        try upsertAttachments(for: message, messageID: record.id, in: db)
        try mirrorIncomingReceiptsIfNeeded(message, messageID: record.id, in: db)
    }

    /// 读路径：`messages` + 附件 + **当前用户**在 `message_receipts` 中的行 → 推导 `isRead` / `isPlayed`（己方消息恒为已读/已播语义）。
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

    /// 单聊首次写入前自动建 `conversations` 与双方 `conversation_members`；已存在则直接返回（幂等）。
    static func ensureConversationAndMembers(
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

    /// 维护 `conversations.last_message_*` 冗余列，供会话列表排序与预览；**任意**消息增删改后应调用。
    static func refreshConversationLastMessage(
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

    /// 将内存里已标记已读/已播的**对方消息**写回 `message_receipts`，与 `toChatMessage` 读路径一致；己方发送的不写回执。
    static func mirrorIncomingReceiptsIfNeeded(
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

    static func nextSeq(
        conversationID: String, in db: Database
    ) throws -> Int64 {
        let current = try Int64.fetchOne(
            db,
            sql: "SELECT MAX(seq) FROM messages WHERE conversation_id = ?",
            arguments: [conversationID]
        ) ?? 0
        return current + 1
    }

    /// 媒体类消息：仅存文件名（`lastPathComponent`），与 `FileStorageManager` 目录拼接还原路径；本地可读时写入 **sha256 / size_bytes** 供读路径校验。
    static func upsertAttachments(
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

    // MARK: - 回执 / 未读

    /// 进入会话「全部已读」：**当前用户**成员行未读归零 + 将对方消息批量插入已读回执（`NOT EXISTS` + `ON CONFLICT` 保证幂等）。
    static func markConversationAsRead(contactID: String, in database: Database) throws {
        let now = nowMs()
        let maxSeq = try Int64.fetchOne(
            database,
            sql: "SELECT MAX(seq) FROM messages WHERE conversation_id = ?",
            arguments: [contactID]
        ) ?? 0

        try database.execute(
            sql: """
                UPDATE conversation_members
                SET unread_count = 0, last_read_message_seq = ?, updated_at_ms = ?
                WHERE conversation_id = ? AND user_id = ?
                """,
            arguments: [maxSeq, now, contactID, Sender.me.id]
        )

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

    /// 直接读 `conversation_members.unread_count`（O(1)），与列表未读角标一致。
    static func unreadCount(conversationID: String, in database: Database) throws -> Int {
        try Int.fetchOne(
            database,
            sql: """
                SELECT unread_count FROM conversation_members
                WHERE conversation_id = ? AND user_id = ?
                """,
            arguments: [conversationID, Sender.me.id]
        ) ?? 0
    }

    // MARK: - 枚举 ↔ 整型

    static func kindToInt(_ kind: ChatMessage.Kind) -> Int {
        switch kind {
        case .text:     return 0
        case .voice:    return 1
        case .image:    return 2
        case .video:    return 3
        case .recalled: return 4
        case .location: return 5
        }
    }

    static func bodyText(for kind: ChatMessage.Kind) -> String? {
        switch kind {
        case .text(let t): return t
        case .recalled(let original): return original
        default: return nil
        }
    }

    static func extJSON(for kind: ChatMessage.Kind) -> String? {
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

    /// `messages.kind` + 附件行 + `recalled_at_ms` → 还原 `ChatMessage.Kind`；语音/图/视频走 `validatedLocalURL`。
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

    static func sendStatusToInt(_ status: ChatMessage.SendStatus) -> Int {
        switch status {
        case .sending:   return 0
        case .delivered: return 1
        case .read:      return 2
        case .failed:    return 3
        }
    }

    static func intToSendStatus(_ raw: Int) -> ChatMessage.SendStatus {
        switch raw {
        case 0: return .sending
        case 1: return .delivered
        case 2: return .read
        case 3: return .failed
        default: return .delivered
        }
    }

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

    static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// 本地文件存在且可读时计算摘要与长度；用于落库与后续篡改检测。
    private static func attachmentIntegrity(for localURL: URL?) -> (sha256: String, sizeBytes: Int64)? {
        guard let localURL else { return nil }
        guard FileManager.default.fileExists(atPath: localURL.path) else { return nil }
        guard let data = try? Data(contentsOf: localURL, options: .mappedIfSafe) else { return nil }
        let digest = SHA256.hash(data: data)
        let sha = digest.compactMap { String(format: "%02x", $0) }.joined()
        return (sha256: sha, sizeBytes: Int64(data.count))
    }

    /// 读路径：按媒体类型拼缓存目录 + 校验 `size_bytes`/`sha256`；失败则删本地坏文件并返回 `nil`（可回退仅用 remoteURL）。
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

    private static func isRecalledKind(_ kind: ChatMessage.Kind) -> Bool {
        if case .recalled = kind { return true }
        return false
    }
}
