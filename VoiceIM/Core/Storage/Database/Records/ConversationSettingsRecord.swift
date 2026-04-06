import Foundation
import GRDB

/// 会话设置表 Record
///
/// 联合主键 `(conversationID, userID)`，每个用户对每个会话的个性化配置。
struct ConversationSettingsRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "conversation_settings"

    var conversationID: String
    var userID: String
    var isPinned: Bool
    var isHidden: Bool
    var muteUntilMs: Int64?
    var updatedAtMs: Int64

    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
        case userID = "user_id"
        case isPinned = "is_pinned"
        case isHidden = "is_hidden"
        case muteUntilMs = "mute_until_ms"
        case updatedAtMs = "updated_at_ms"
    }

    enum Columns {
        static let conversationID = Column(CodingKeys.conversationID)
        static let userID = Column(CodingKeys.userID)
        static let isPinned = Column(CodingKeys.isPinned)
        static let isHidden = Column(CodingKeys.isHidden)
        static let muteUntilMs = Column(CodingKeys.muteUntilMs)
        static let updatedAtMs = Column(CodingKeys.updatedAtMs)
    }
}
