import Foundation
import GRDB

/// 回执与未读计数读写（与 `ConversationStore` 共享同一套 SQL，由 `GRDBStorageCore` 去重）。
///
/// **供谁用**：`MessageRepository.markConversationAsRead()` 等聊天内路径只依赖本协议，与会话列表用的 `ConversationStorageProtocol` 解耦。
actor ReceiptStore {

    static let shared = ReceiptStore(db: .shared)

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
}
