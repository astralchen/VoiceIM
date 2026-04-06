import Foundation

/// 消息仓库：封装消息的业务逻辑
///
/// # 职责
/// - 管理消息的发送、删除、撤回等业务逻辑
/// - 协调 MessageStorage 和 FileStorageManager
/// - 处理消息状态变化
/// - 提供消息查询接口
///
/// # 设计模式
/// Repository 模式，将数据访问逻辑与业务逻辑分离
@MainActor
final class MessageRepository {

    // MARK: - Dependencies

    private let storage: any MessageStorageProtocol
    private let fileStorage: any FileStorageProtocol
    private let imageCache: ImageCacheManager
    private let videoCache: VideoCacheManager
    private let logger: Logger

    // MARK: - Init

    init(
        storage: any MessageStorageProtocol = MessageStorage.shared,
        fileStorage: any FileStorageProtocol = FileStorageManager.shared,
        imageCache: ImageCacheManager? = nil,
        videoCache: VideoCacheManager? = nil,
        logger: Logger = VoiceIM.logger
    ) {
        self.storage = storage
        self.fileStorage = fileStorage
        // Swift 6：默认实参在非隔离上下文求值，不能写 `ImageCacheManager = .shared`；在 `@MainActor` 体内再解析单例。
        // `VideoCacheManager` 为 actor，`.shared` 取的是全局 actor 实例引用，同样避免出现在默认参数里。
        self.imageCache = imageCache ?? ImageCacheManager.shared
        self.videoCache = videoCache ?? VideoCacheManager.shared
        self.logger = logger
    }

    // MARK: - Message Operations

    /// 加载所有消息
    ///
    /// - Returns: 消息列表
    /// - Throws: ChatError
    func loadMessages() async throws -> [ChatMessage] {
        do {
            let messages = try await storage.load()
            logger.info("Loaded \(messages.count) messages from storage")
            return messages
        } catch {
            logger.error("Failed to load messages: \(error)")
            throw ChatError.storageReadFailed
        }
    }

    /// 发送文本消息
    ///
    /// - Parameters:
    ///   - text: 文本内容
    ///   - sender: 发送者
    /// - Returns: 创建的消息
    /// - Throws: ChatError
    func sendTextMessage(text: String, sender: Sender = .me) async throws -> ChatMessage {
        let message = ChatMessage.text(text, sender: sender, sentAt: Date())
        try await storage.append(message)
        logger.info("Sent text message: \(message.id)")
        return message
    }

    /// 发送语音消息
    ///
    /// - Parameters:
    ///   - tempURL: 临时录音文件 URL
    ///   - duration: 录音时长
    ///   - sender: 发送者
    /// - Returns: 创建的消息
    /// - Throws: ChatError
    func sendVoiceMessage(tempURL: URL, duration: TimeInterval, sender: Sender = .me) async throws -> ChatMessage {
        do {
            // 保存录音文件到永久存储
            let permanentURL = try await fileStorage.saveVoiceFile(from: tempURL)

            // 创建消息
            let message = ChatMessage.voice(localURL: permanentURL, duration: duration, sentAt: Date())
            try await storage.append(message)

            // 删除临时文件
            try? await fileStorage.deleteFile(at: tempURL)

            logger.info("Sent voice message: \(message.id), duration: \(duration)s")
            return message
        } catch {
            logger.error("Failed to send voice message: \(error)")
            throw ChatError.messageSendFailed
        }
    }

    /// 发送图片消息
    ///
    /// - Parameters:
    ///   - tempURL: 临时图片文件 URL
    ///   - sender: 发送者
    /// - Returns: 创建的消息
    /// - Throws: ChatError
    func sendImageMessage(tempURL: URL, sender: Sender = .me) async throws -> ChatMessage {
        do {
            logger.info("📤 Sending image, temp: \(tempURL.lastPathComponent)")

            // 【关键优化】保存原图到磁盘缓存并加载缩略图到内存
            // 原因：
            // 1. 磁盘保存原图，支持高清预览和分享
            // 2. 内存缓存缩略图，列表显示快速
            // 3. 使用构造注入的 `imageCache`（默认即 `ImageCacheManager.shared`），便于单测替换
            let cacheURL = try await imageCache.saveAndCacheImage(from: tempURL)
            logger.info("💾 Saved to cache: \(cacheURL.lastPathComponent)")

            // 删除临时文件
            try? await fileStorage.deleteFile(at: tempURL)

            // 创建消息（使用磁盘缓存路径）
            let message = ChatMessage.image(localURL: cacheURL, sentAt: Date())
            try await storage.append(message)

            logger.info("Sent image message: \(message.id)")
            return message
        } catch {
            logger.error("Failed to send image message: \(error)")
            throw ChatError.messageSendFailed
        }
    }

    /// 发送视频消息
    ///
    /// - Parameters:
    ///   - tempURL: 临时视频文件 URL
    ///   - duration: 视频时长
    ///   - sender: 发送者
    /// - Returns: 创建的消息
    /// - Throws: ChatError
    func sendVideoMessage(tempURL: URL, duration: TimeInterval, sender: Sender = .me) async throws -> ChatMessage {
        do {
            logger.info("📤 Sending video, temp: \(tempURL.lastPathComponent)")

            // 保存到视频缓存目录并预生成缩略图；`videoCache` 与 `imageCache` 同为注入依赖，目录由 `ChatCacheBucket` 约束
            let cacheURL = try await videoCache.saveAndCacheVideo(from: tempURL)
            logger.info("💾 Saved to cache: \(cacheURL.lastPathComponent)")

            // 删除临时文件
            try? FileManager.default.removeItem(at: tempURL)

            // 创建消息（使用视频缓存路径）
            let message = ChatMessage.video(localURL: cacheURL, duration: duration, sentAt: Date())
            try await storage.append(message)

            logger.info("Sent video message: \(message.id), duration: \(duration)s")
            return message
        } catch {
            logger.error("Failed to send video message: \(error)")
            throw ChatError.messageSendFailed
        }
    }

    /// 发送位置消息
    ///
    /// - Parameters:
    ///   - latitude: 纬度
    ///   - longitude: 经度
    ///   - address: 地址（可选）
    ///   - sender: 发送者
    /// - Returns: 创建的消息
    /// - Throws: ChatError
    func sendLocationMessage(latitude: Double, longitude: Double, address: String?, sender: Sender = .me) async throws -> ChatMessage {
        let message = ChatMessage.location(latitude: latitude, longitude: longitude, address: address, sentAt: Date())
        try await storage.append(message)
        logger.info("Sent location message: \(message.id)")
        return message
    }

    /// 删除消息
    ///
    /// - Parameter id: 消息 ID
    /// - Throws: ChatError
    func deleteMessage(id: UUID) async throws {
        do {
            // 加载消息以获取文件 URL
            let messages = try await storage.load()
            guard let message = messages.first(where: { $0.id == id }) else {
                throw ChatError.messageNotFound(id: id)
            }

            // 删除关联的文件
            if let localURL = message.localURL {
                try? await fileStorage.deleteFile(at: localURL)
            }

            // 从存储中删除消息
            try await storage.delete(id: id)

            logger.info("Deleted message: \(id)")
        } catch let error as ChatError {
            logger.error("Failed to delete message: \(error)")
            throw error
        } catch {
            logger.error("Failed to delete message: \(error)")
            throw ChatError.messageDeleteFailed
        }
    }

    /// 撤回消息
    ///
    /// - Parameter id: 消息 ID
    /// - Throws: ChatError
    func recallMessage(id: UUID) async throws {
        do {
            // 加载消息
            let messages = try await storage.load()
            guard let message = messages.first(where: { $0.id == id }) else {
                throw ChatError.messageNotFound(id: id)
            }

            // 检查撤回条件
            guard message.isOutgoing else {
                throw ChatError.messageRecallFailed
            }
            guard message.sendStatus == .delivered else {
                throw ChatError.messageRecallFailed
            }
            guard Date().timeIntervalSince(message.sentAt) <= 3 * 60 else {
                throw ChatError.messageRecallFailed
            }

            // 提取原文本内容（仅文本消息保留）
            let originalText: String?
            if case .text(let content) = message.kind {
                originalText = content
            } else {
                originalText = nil
            }

            // 删除关联的文件
            if let localURL = message.localURL {
                try? await fileStorage.deleteFile(at: localURL)
            }

            // 创建撤回消息
            var recalledMessage = message
            recalledMessage.kind = .recalled(originalText: originalText)

            // 更新存储
            try await storage.update(recalledMessage)

            logger.info("Recalled message: \(id)")
        } catch let error as ChatError {
            logger.error("Failed to recall message: \(error)")
            throw error
        } catch {
            logger.error("Failed to recall message: \(error)")
            throw ChatError.messageRecallFailed
        }
    }

    /// 更新消息发送状态
    ///
    /// - Parameters:
    ///   - id: 消息 ID
    ///   - status: 新的发送状态
    /// - Throws: ChatError
    func updateSendStatus(id: UUID, status: ChatMessage.SendStatus) async throws {
        do {
            let messages = try await storage.load()
            guard var message = messages.first(where: { $0.id == id }) else {
                throw ChatError.messageNotFound(id: id)
            }

            message.sendStatus = status
            try await storage.update(message)

            logger.debug("Updated message \(id) status to \(status)")
        } catch let error as ChatError {
            throw error
        } catch {
            logger.error("Failed to update message status: \(error)")
            throw ChatError.storageWriteFailed
        }
    }

    /// 标记消息为已播放
    ///
    /// - Parameter id: 消息 ID
    /// - Throws: ChatError
    func markAsPlayed(id: UUID) async throws {
        do {
            let messages = try await storage.load()
            guard var message = messages.first(where: { $0.id == id }) else {
                throw ChatError.messageNotFound(id: id)
            }

            message.isPlayed = true
            try await storage.update(message)

            logger.debug("Marked message \(id) as played")
        } catch let error as ChatError {
            throw error
        } catch {
            logger.error("Failed to mark message as played: \(error)")
            throw ChatError.storageWriteFailed
        }
    }

    /// 清理孤立文件
    ///
    /// - Returns: 清理的文件数量
    func cleanOrphanedFiles() async -> Int {
        do {
            let messages = try await storage.load()
            let referencedURLs = Set(messages.compactMap { $0.localURL })
            let cleanedCount = await fileStorage.cleanOrphanedFiles(referencedURLs: referencedURLs)

            logger.info("Cleaned \(cleanedCount) orphaned files")
            return cleanedCount
        } catch {
            logger.error("Failed to clean orphaned files: \(error)")
            return 0
        }
    }

    // MARK: - History Loading

    /// 加载历史消息（分页）
    ///
    /// - Parameters:
    ///   - page: 页码（从 0 开始）
    ///   - pageSize: 每页消息数量
    /// - Returns: 历史消息列表（按时间倒序）
    /// - Throws: ChatError
    func loadHistory(page: Int, pageSize: Int = 20) async throws -> [ChatMessage] {
        // TODO: 接入真实的网络 API
        // 当前实现：生成模拟历史消息

        // 模拟网络延迟
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 秒

        // 生成模拟历史消息
        let startIndex = page * pageSize
        let endIndex = startIndex + pageSize

        var historyMessages: [ChatMessage] = []

        for i in startIndex..<endIndex {
            let timestamp = Date().addingTimeInterval(-Double((i + 1) * 3600)) // 每条消息间隔 1 小时

            // 交替生成不同类型的消息
            let message: ChatMessage
            switch i % 3 {
            case 0:
                message = ChatMessage.text(
                    "历史消息 #\(i + 1)",
                    sender: i % 2 == 0 ? .me : .peer,
                    sentAt: timestamp,
                    sendStatus: .delivered
                )
            case 1:
                message = ChatMessage.text(
                    "这是一条较长的历史消息，用于测试消息列表的显示效果 #\(i + 1)",
                    sender: i % 2 == 0 ? .me : .peer,
                    sentAt: timestamp,
                    sendStatus: .delivered
                )
            default:
                message = ChatMessage.text(
                    "历史消息内容 #\(i + 1)",
                    sender: i % 2 == 0 ? .me : .peer,
                    sentAt: timestamp,
                    sendStatus: .delivered
                )
            }

            historyMessages.append(message)
        }

        logger.info("Loaded \(historyMessages.count) history messages for page \(page)")
        return historyMessages
    }
}
