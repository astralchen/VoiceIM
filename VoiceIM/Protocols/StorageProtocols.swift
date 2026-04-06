import Foundation

/// 消息存储协议
///
/// 定义消息持久化的核心能力，解耦 Repository 与具体实现。
///
/// # 实现者
/// - `MessageStorage`：生产环境使用的存储实现
/// - `MockMessageStorage`：单元测试使用的 Mock 实现
protocol MessageStorageProtocol: Actor {

    /// 保存消息列表
    ///
    /// - Parameter messages: 要保存的消息列表
    /// - Throws: 保存失败时抛出错误
    func save(_ messages: [ChatMessage]) throws

    /// 加载消息列表
    ///
    /// - Returns: 已保存的消息列表
    /// - Throws: 加载失败时抛出错误
    func load() throws -> [ChatMessage]

    /// 追加单条消息
    ///
    /// - Parameter message: 要追加的消息
    /// - Throws: 追加失败时抛出错误
    func append(_ message: ChatMessage) throws

    /// 删除指定消息
    ///
    /// - Parameter id: 消息 ID
    /// - Throws: 删除失败时抛出错误
    func delete(id: UUID) throws

    /// 更新消息
    ///
    /// - Parameter message: 更新后的消息
    /// - Throws: 更新失败时抛出错误
    func update(_ message: ChatMessage) throws

    /// 清空所有消息
    ///
    /// - Throws: 清空失败时抛出错误
    func clear() throws

    /// 获取存储大小（字节）
    ///
    /// - Returns: 存储文件的大小
    func getStorageSize() -> UInt64
}

/// 文件存储协议
///
/// 定义文件存储管理的核心能力，解耦 Repository 与具体实现。
///
/// # 实现者
/// - `FileStorageManager`：生产环境使用的存储实现
/// - `MockFileStorageManager`：单元测试使用的 Mock 实现
protocol FileStorageProtocol: Actor {

    /// 语音文件目录
    var voiceDirectory: URL { get }

    /// 图片文件目录
    var imageDirectory: URL { get }

    /// 视频文件目录
    var videoDirectory: URL { get }

    /// 保存语音文件
    ///
    /// - Parameter tempURL: 临时文件 URL
    /// - Returns: 保存后的文件 URL
    /// - Throws: 保存失败时抛出错误
    func saveVoiceFile(from tempURL: URL) throws -> URL

    /// 保存图片文件
    ///
    /// - Parameter tempURL: 临时文件 URL
    /// - Returns: 保存后的文件 URL
    /// - Throws: 保存失败时抛出错误
    func saveImageFile(from tempURL: URL) throws -> URL

    /// 保存视频文件
    ///
    /// - Parameter tempURL: 临时文件 URL
    /// - Returns: 保存后的文件 URL
    /// - Throws: 保存失败时抛出错误
    func saveVideoFile(from tempURL: URL) throws -> URL

    /// 删除文件
    ///
    /// - Parameter url: 文件 URL
    /// - Throws: 删除失败时抛出错误
    func deleteFile(at url: URL) throws

    /// 检查文件是否存在
    ///
    /// - Parameter url: 文件 URL
    /// - Returns: 文件是否存在
    func fileExists(at url: URL) -> Bool

    /// 获取缓存大小（字节）
    ///
    /// - Returns: 缓存总大小
    func getCacheSize() -> UInt64

    /// 获取格式化的缓存大小（如 "1.5 MB"）
    ///
    /// - Returns: 格式化的缓存大小字符串
    func getFormattedCacheSize() -> String

    /// 清空所有缓存
    ///
    /// - Throws: 清空失败时抛出错误
    func clearAllCache() throws

    /// 清理孤立文件（未被消息引用的文件）
    ///
    /// - Parameter referencedURLs: 被引用的文件 URL 集合
    /// - Returns: 清理的文件数量
    func cleanOrphanedFiles(referencedURLs: Set<URL>) -> Int
}
