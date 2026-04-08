import Foundation

/// 消息存储协议（按会话隔离读写）
///
/// 定义消息持久化的核心能力，解耦 Repository 与具体实现。
/// 生产环境实现为 `MessageStore`（基于 GRDB）；`MessageRepository` 等依赖 `any MessageStorageProtocol`。
protocol MessageStorageProtocol: Actor {

    /// 保存消息列表到指定会话
    func save(_ messages: [ChatMessage], contactID: String) throws

    /// 加载指定会话的消息列表
    func load(contactID: String) throws -> [ChatMessage]

    /// 加载指定会话最近 N 条消息（按时间正序：旧 -> 新）
    func loadRecent(contactID: String, limit: Int) throws -> [ChatMessage]

    /// 加载锚点消息之前的 N 条历史消息（按时间正序：旧 -> 新）
    /// - Parameter beforeMessageID: 锚点消息 ID；为 nil 时返回最近 N 条
    func loadHistory(contactID: String, beforeMessageID: String?, limit: Int) throws -> [ChatMessage]

    /// 追加单条消息到指定会话
    func append(_ message: ChatMessage, contactID: String) throws

    /// 物理删除指定消息
    func delete(id: String, contactID: String) throws

    /// 更新指定会话中的消息
    func update(_ message: ChatMessage, contactID: String) throws

    /// 清空指定会话消息（物理删除）
    func clear(contactID: String) throws

    /// 获取存储大小（字节）
    func getStorageSize() -> UInt64
}

/// 会话存储协议（会话列表、未读、已读）
///
/// 定义会话级聚合查询能力，供 `ConversationListViewModel` 等使用。
/// 生产环境实现为 `ConversationStore`；`ConversationListViewModel` 等依赖 `any ConversationStorageProtocol`。
/// 未读/已读 SQL 与 `ReceiptStore` 共享 `GRDBStorageCore`。
protocol ConversationStorageProtocol: Actor {

    /// 标记指定会话所有对方消息为已读
    func markConversationAsRead(contactID: String) throws

    /// 查询指定会话的未读消息数
    func unreadCount(conversationID: String) throws -> Int

    /// 加载全部已存在会话 ID（含被隐藏会话）
    func loadAllConversationIDs() throws -> [String]

    /// 加载会话列表摘要（一次聚合查询，含置顶状态、预览文案与时间，避免 N+1）
    func loadConversationSummaries() throws -> [(ConversationRecord, Int, Bool, String, Int64?)]

    /// 获取会话最后一条可见消息的预览文本与时间戳
    func lastMessagePreview(conversationID: String) throws -> (String, Int64)?

    /// 设置会话置顶状态
    func setConversationPinned(contactID: String, pinned: Bool) throws

    /// 设置会话是否隐藏（隐藏后不出现在列表，直到有新消息自动恢复）
    func setConversationHidden(contactID: String, hidden: Bool) throws

    /// 物理删除会话（级联删除消息/成员/设置等关联数据）
    func deleteConversation(contactID: String) throws
}

/// 回执存储协议（已读/已播/未读计数）
///
/// 生产环境实现为 `ReceiptStore`；`MessageRepository` 等依赖 `any ReceiptStorageProtocol`。
/// 与 `ConversationStorageProtocol` 中同名方法共用 `GRDBStorageCore` 实现，语义一致。
protocol ReceiptStorageProtocol: Actor {
    /// 标记会话为已读（写入回执并归零未读）
    func markConversationAsRead(contactID: String) throws

    /// 查询会话未读数
    func unreadCount(conversationID: String) throws -> Int
}

/// 文件存储协议
///
/// 定义文件存储管理的核心能力，解耦 Repository 与具体实现。
protocol FileStorageProtocol: Actor {

    var voiceDirectory: URL { get }
    var imageDirectory: URL { get }
    var videoDirectory: URL { get }

    func saveVoiceFile(from tempURL: URL) throws -> URL
    func saveImageFile(from tempURL: URL) throws -> URL
    func saveVideoFile(from tempURL: URL) throws -> URL
    func deleteFile(at url: URL) throws
    func fileExists(at url: URL) -> Bool
    func getCacheSize() -> UInt64
    func getFormattedCacheSize() -> String
    func clearAllCache() throws
    func cleanOrphanedFiles(referencedURLs: Set<URL>) -> Int
}
