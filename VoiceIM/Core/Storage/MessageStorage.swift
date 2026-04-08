import Foundation

/// 存储门面：聚合 `MessageStore` / `ConversationStore` / `ReceiptStore`，共享同一 `DatabaseManager`。
///
/// GRDB 的 `DatabaseQueue` 串行化跨 actor 的写操作；各 Store 仍各自以单次 `write`/`read` 调用保证语句级事务。
/// 生产环境由 `AppDependencies` 注入 `any MessageStorageProtocol` 等；本类型供测试或需要单入口转发时使用。
///
/// ```
/// MessageStorage（门面，可选）
///   ↓
/// MessageStore / ConversationStore / ReceiptStore
///   ↓
/// DatabaseManager → GRDB
/// ```
actor MessageStorage {

    static let shared = MessageStorage(db: .shared)

    // 三个 actor 持有同一 `DatabaseManager` 引用；GRDB 的 `DatabaseQueue` 负责串行化跨 actor 的 SQL。
    private let messages: MessageStore
    private let conversations: ConversationStore
    private let receipts: ReceiptStore

    /// 默认使用 `DatabaseManager.shared`；测试可注入独立库路径。
    init(db: DatabaseManager) {
        self.messages = MessageStore(db: db)
        self.conversations = ConversationStore(db: db)
        self.receipts = ReceiptStore(db: db)
    }

    // MARK: - 消息（→ MessageStore）

    func clear(contactID: String) async throws {
        try await messages.clear(contactID: contactID)
    }

    func getStorageSize() async -> UInt64 {
        await messages.getStorageSize()
    }

    func save(_ messages: [ChatMessage], contactID: String) async throws {
        try await self.messages.save(messages, contactID: contactID)
    }

    func load(contactID: String) async throws -> [ChatMessage] {
        try await messages.load(contactID: contactID)
    }

    func loadRecent(contactID: String, limit: Int) async throws -> [ChatMessage] {
        try await messages.loadRecent(contactID: contactID, limit: limit)
    }

    func loadHistory(contactID: String, beforeMessageID: String?, limit: Int) async throws -> [ChatMessage] {
        try await messages.loadHistory(contactID: contactID, beforeMessageID: beforeMessageID, limit: limit)
    }

    func append(_ message: ChatMessage, contactID: String) async throws {
        try await messages.append(message, contactID: contactID)
    }

    func delete(id: String, contactID: String) async throws {
        try await messages.delete(id: id, contactID: contactID)
    }

    func update(_ message: ChatMessage, contactID: String) async throws {
        try await messages.update(message, contactID: contactID)
    }

    // MARK: - 会话（→ ConversationStore）

    func loadAllConversationIDs() async throws -> [String] {
        try await conversations.loadAllConversationIDs()
    }

    func loadConversationSummaries() async throws -> [(ConversationRecord, Int, Bool, String, Int64?)] {
        try await conversations.loadConversationSummaries()
    }

    func lastMessagePreview(conversationID: String) async throws -> (String, Int64)? {
        try await conversations.lastMessagePreview(conversationID: conversationID)
    }

    func setConversationPinned(contactID: String, pinned: Bool) async throws {
        try await conversations.setConversationPinned(contactID: contactID, pinned: pinned)
    }

    func setConversationHidden(contactID: String, hidden: Bool) async throws {
        try await conversations.setConversationHidden(contactID: contactID, hidden: hidden)
    }

    func deleteConversation(contactID: String) async throws {
        try await conversations.deleteConversation(contactID: contactID)
    }

    // MARK: - 回执 / 未读（→ ReceiptStore；与 ConversationStore 内同名能力 SQL 一致）

    func markConversationAsRead(contactID: String) async throws {
        try await receipts.markConversationAsRead(contactID: contactID)
    }

    func unreadCount(conversationID: String) async throws -> Int {
        try await receipts.unreadCount(conversationID: conversationID)
    }
}
