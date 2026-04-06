import Foundation

/// 消息存储：消息持久化到本地 JSON 文件
///
/// # 职责
/// - 将消息列表序列化为 JSON 并保存到本地
/// - 从本地 JSON 文件加载消息列表
/// - 支持增量保存和批量加载
///
/// # 存储格式
/// ```json
/// {
///   "version": 1,
///   "messages": [
///     {
///       "id": "uuid",
///       "kind": "text",
///       "content": "Hello",
///       "sender": "me",
///       "sentAt": "2026-04-05T12:00:00Z",
///       "isOutgoing": true,
///       "sendStatus": "delivered"
///     }
///   ]
/// }
/// ```
///
/// # 线程安全
/// 使用 actor 隔离保证并发安全
actor MessageStorage: MessageStorageProtocol {

    // MARK: - Singleton

    static let shared = MessageStorage()

    // MARK: - Properties

    private let fileManager = FileManager.default
    private let storageURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Init

    private init() {
        // 存储路径：Documents/VoiceIM/messages.json
        guard let documentsURL = fileManager
            .urls(for: .documentDirectory, in: .userDomainMask).first else {
            fatalError("Failed to get documents directory")
        }
        let baseURL = documentsURL.appendingPathComponent("VoiceIM", isDirectory: true)

        // 创建目录
        do {
            try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        } catch {
            VoiceIM.logger.error("Failed to create storage directory: \(error)")
        }

        self.storageURL = baseURL.appendingPathComponent("messages.json")

        // 配置编码器
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        // 配置解码器
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Public Methods

    /// 保存消息列表
    ///
    /// - Parameter messages: 消息列表
    /// - Throws: 编码或文件写入错误
    func save(_ messages: [ChatMessage]) throws {
        let container = MessageContainer(version: 1, messages: messages)
        let data = try encoder.encode(container)
        try data.write(to: storageURL, options: .atomic)
    }

    /// 加载消息列表
    ///
    /// - Returns: 消息列表，如果文件不存在则返回空数组
    /// - Throws: 解码或文件读取错误
    func load() throws -> [ChatMessage] {
        guard fileManager.fileExists(atPath: storageURL.path) else {
            return []
        }

        let data = try Data(contentsOf: storageURL)
        let container = try decoder.decode(MessageContainer.self, from: data)
        return container.messages
    }

    /// 追加消息到存储
    ///
    /// - Parameter message: 要追加的消息
    /// - Throws: 编码或文件写入错误
    func append(_ message: ChatMessage) throws {
        var messages = try load()
        messages.append(message)
        try save(messages)
    }

    /// 删除消息
    ///
    /// - Parameter id: 消息 ID
    /// - Throws: 编码或文件写入错误
    func delete(id: UUID) throws {
        var messages = try load()
        messages.removeAll { $0.id == id }
        try save(messages)
    }

    /// 更新消息
    ///
    /// - Parameter message: 更新后的消息
    /// - Throws: 编码或文件写入错误
    func update(_ message: ChatMessage) throws {
        var messages = try load()
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
            try save(messages)
        }
    }

    /// 清空所有消息
    ///
    /// - Throws: 文件删除错误
    func clear() throws {
        if fileManager.fileExists(atPath: storageURL.path) {
            try fileManager.removeItem(at: storageURL)
        }
    }

    /// 获取存储文件大小
    ///
    /// - Returns: 文件大小（字节）
    func getStorageSize() -> UInt64 {
        guard let attributes = try? fileManager.attributesOfItem(atPath: storageURL.path),
              let fileSize = attributes[.size] as? UInt64 else {
            return 0
        }
        return fileSize
    }
}

// MARK: - MessageContainer

/// 消息存储容器
private struct MessageContainer: Codable {
    let version: Int
    let messages: [ChatMessage]

    enum CodingKeys: String, CodingKey {
        case version
        case messages
    }
}
