import Foundation
import GRDB

/// 消息附件表 Record
///
/// 每条消息可关联零到多条附件（语音、图片、视频等媒体文件）。
/// `sha256` 与 `sizeBytes` 用于文件完整性校验。
struct MessageAttachmentRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "message_attachments"

    var id: String
    var messageID: String
    /// 0=voice, 1=image, 2=video
    var mediaType: Int
    var localPath: String?
    var remoteURL: String?
    var sha256: String?
    var sizeBytes: Int64?
    var durationMs: Int64?
    var width: Int?
    var height: Int?
    var createdAtMs: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case messageID = "message_id"
        case mediaType = "media_type"
        case localPath = "local_path"
        case remoteURL = "remote_url"
        case sha256
        case sizeBytes = "size_bytes"
        case durationMs = "duration_ms"
        case width
        case height
        case createdAtMs = "created_at_ms"
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let messageID = Column(CodingKeys.messageID)
        static let mediaType = Column(CodingKeys.mediaType)
        static let localPath = Column(CodingKeys.localPath)
        static let remoteURL = Column(CodingKeys.remoteURL)
        static let sha256 = Column(CodingKeys.sha256)
        static let sizeBytes = Column(CodingKeys.sizeBytes)
        static let durationMs = Column(CodingKeys.durationMs)
        static let width = Column(CodingKeys.width)
        static let height = Column(CodingKeys.height)
        static let createdAtMs = Column(CodingKeys.createdAtMs)
    }
}
