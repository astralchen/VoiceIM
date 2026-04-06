import Foundation
import GRDB

/// 会话成员表 Record
///
/// 联合主键 `(conversationID, userID)`。
/// `unreadCount` 做成员级未读计数，由事务统一更新。
/// `lastReadMessageSeq` 跟踪该成员最后读到的消息序号，用于断线重连后精确补齐。
struct ConversationMemberRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "conversation_members"

    var conversationID: String
    var userID: String
    /// 0 = member, 1 = admin, 2 = owner
    var role: Int
    var joinedAtMs: Int64
    var leftAtMs: Int64?
    var isMuted: Bool
    var unreadCount: Int
    var lastReadMessageSeq: Int64
    var updatedAtMs: Int64

    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
        case userID = "user_id"
        case role
        case joinedAtMs = "joined_at_ms"
        case leftAtMs = "left_at_ms"
        case isMuted = "is_muted"
        case unreadCount = "unread_count"
        case lastReadMessageSeq = "last_read_message_seq"
        case updatedAtMs = "updated_at_ms"
    }

    enum Columns {
        static let conversationID = Column(CodingKeys.conversationID)
        static let userID = Column(CodingKeys.userID)
        static let role = Column(CodingKeys.role)
        static let joinedAtMs = Column(CodingKeys.joinedAtMs)
        static let leftAtMs = Column(CodingKeys.leftAtMs)
        static let isMuted = Column(CodingKeys.isMuted)
        static let unreadCount = Column(CodingKeys.unreadCount)
        static let lastReadMessageSeq = Column(CodingKeys.lastReadMessageSeq)
        static let updatedAtMs = Column(CodingKeys.updatedAtMs)
    }
}
