import Foundation
import GRDB

/// 消息回执表 Record
///
/// 联合主键 `(messageID, userID)`，记录每条消息在每个用户维度的送达/已读/已播放状态。
/// 群聊场景下同一条消息会有多条回执（每个群成员一条）。
struct MessageReceiptRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "message_receipts"

    var messageID: String
    var userID: String
    var deliveredAtMs: Int64?
    var readAtMs: Int64?
    var playedAtMs: Int64?
    var updatedAtMs: Int64

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case userID = "user_id"
        case deliveredAtMs = "delivered_at_ms"
        case readAtMs = "read_at_ms"
        case playedAtMs = "played_at_ms"
        case updatedAtMs = "updated_at_ms"
    }

    enum Columns {
        static let messageID = Column(CodingKeys.messageID)
        static let userID = Column(CodingKeys.userID)
        static let deliveredAtMs = Column(CodingKeys.deliveredAtMs)
        static let readAtMs = Column(CodingKeys.readAtMs)
        static let playedAtMs = Column(CodingKeys.playedAtMs)
        static let updatedAtMs = Column(CodingKeys.updatedAtMs)
    }
}
