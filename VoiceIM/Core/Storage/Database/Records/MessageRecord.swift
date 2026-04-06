import Foundation
import GRDB

/// 消息表 Record
///
/// 主键为消息 ID（有序字符串），外键关联 `conversations`。
/// `seq` 为会话内严格递增序号，配合 `(conversationID, seq)` 唯一索引保证会话内时序。
/// `clientMsgID` 为客户端生成的幂等键，防止重发产生重复消息。
/// 撤回/编辑/删除使用独立时间字段，不覆盖原始数据，保证审计可追溯。
struct MessageRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "messages"

    var id: String
    var conversationID: String
    var seq: Int64
    var clientMsgID: String
    var senderUserID: String
    /// 0=text, 1=voice, 2=image, 3=video, 4=recalled, 5=location
    var kind: Int
    var bodyText: String?
    /// 扩展字段（JSON），存储消息类型特有的结构化数据
    var extJSON: String?
    /// 0=sending, 1=delivered, 2=read, 3=failed
    var sendStatus: Int
    var createdAtMs: Int64
    var serverAtMs: Int64?
    var editedAtMs: Int64?
    var recalledAtMs: Int64?
    var deletedAtMs: Int64?

    enum CodingKeys: String, CodingKey {
        case id
        case conversationID = "conversation_id"
        case seq
        case clientMsgID = "client_msg_id"
        case senderUserID = "sender_user_id"
        case kind
        case bodyText = "body_text"
        case extJSON = "ext_json"
        case sendStatus = "send_status"
        case createdAtMs = "created_at_ms"
        case serverAtMs = "server_at_ms"
        case editedAtMs = "edited_at_ms"
        case recalledAtMs = "recalled_at_ms"
        case deletedAtMs = "deleted_at_ms"
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let conversationID = Column(CodingKeys.conversationID)
        static let seq = Column(CodingKeys.seq)
        static let clientMsgID = Column(CodingKeys.clientMsgID)
        static let senderUserID = Column(CodingKeys.senderUserID)
        static let kind = Column(CodingKeys.kind)
        static let bodyText = Column(CodingKeys.bodyText)
        static let extJSON = Column(CodingKeys.extJSON)
        static let sendStatus = Column(CodingKeys.sendStatus)
        static let createdAtMs = Column(CodingKeys.createdAtMs)
        static let serverAtMs = Column(CodingKeys.serverAtMs)
        static let editedAtMs = Column(CodingKeys.editedAtMs)
        static let recalledAtMs = Column(CodingKeys.recalledAtMs)
        static let deletedAtMs = Column(CodingKeys.deletedAtMs)
    }
}
