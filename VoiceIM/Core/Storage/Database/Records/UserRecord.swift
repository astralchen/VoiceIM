import Foundation
import GRDB

/// 用户表 Record
///
/// 存储所有出现过的用户信息（含自己）。
/// 主键为服务端下发的用户 ID，文本类型，支持多端同步场景。
struct UserRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "users"

    var id: String
    var displayName: String
    var avatarURL: String?
    /// 0 = active, 1 = disabled
    var status: Int
    var createdAtMs: Int64
    var updatedAtMs: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case avatarURL = "avatar_url"
        case status
        case createdAtMs = "created_at_ms"
        case updatedAtMs = "updated_at_ms"
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let displayName = Column(CodingKeys.displayName)
        static let avatarURL = Column(CodingKeys.avatarURL)
        static let status = Column(CodingKeys.status)
        static let createdAtMs = Column(CodingKeys.createdAtMs)
        static let updatedAtMs = Column(CodingKeys.updatedAtMs)
    }
}
