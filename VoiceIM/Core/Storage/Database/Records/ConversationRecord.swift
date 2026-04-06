import Foundation
import GRDB

/// 会话表 Record
///
/// 每个单聊/群聊对应一条记录。
/// `lastMessageId` 与 `lastMessageAtMs` 做冗余存储，用于会话列表排序与摘要展示，
/// 避免每次加载列表时 JOIN messages 表。
struct ConversationRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "conversations"

    var id: String
    /// 0 = single（单聊），1 = group（群聊）
    var type: Int
    var title: String?
    var ownerUserID: String?
    var lastMessageID: String?
    var lastMessageAtMs: Int64?
    /// 乐观锁版本号，用于并发写入冲突检测
    var version: Int64
    var isMutedDefault: Bool
    var createdAtMs: Int64
    var updatedAtMs: Int64
    var deletedAtMs: Int64?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case title
        case ownerUserID = "owner_user_id"
        case lastMessageID = "last_message_id"
        case lastMessageAtMs = "last_message_at_ms"
        case version
        case isMutedDefault = "is_muted_default"
        case createdAtMs = "created_at_ms"
        case updatedAtMs = "updated_at_ms"
        case deletedAtMs = "deleted_at_ms"
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let type = Column(CodingKeys.type)
        static let title = Column(CodingKeys.title)
        static let ownerUserID = Column(CodingKeys.ownerUserID)
        static let lastMessageID = Column(CodingKeys.lastMessageID)
        static let lastMessageAtMs = Column(CodingKeys.lastMessageAtMs)
        static let version = Column(CodingKeys.version)
        static let isMutedDefault = Column(CodingKeys.isMutedDefault)
        static let createdAtMs = Column(CodingKeys.createdAtMs)
        static let updatedAtMs = Column(CodingKeys.updatedAtMs)
        static let deletedAtMs = Column(CodingKeys.deletedAtMs)
    }
}
