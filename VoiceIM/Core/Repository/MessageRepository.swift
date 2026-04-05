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

    private let storage: MessageStorage
    private let fileStorage: FileStorageManager
    private let logger: Logger

    // MARK: - Init

    init(
        storage: MessageStorage = .shared,
        fileStorage: FileStorageManager = .shared,
        logger: Logger = VoiceIM.logger
    ) {
        self.storage = storage
        self.fileStorage = fileStorage
        self.logger = logger
    }

    // MARK: - Message Operations

    /// 加载所有消息
    ///
    /// - Returns: 消息列表
    /// - Throws: ChatError
    func loadMessages() throws -> [ChatMessage] {
        do {
            let messages = try storage.load()
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
    func sendTextMessage(text: String, sender: Sender = .me) throws -> ChatMessage {
        let message = ChatMessage.text(text, sender: sender, sentAt: Date())
        try storage.append(message)
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
    func sendVoiceMessage(tempURL: URL, duration: TimeInterval, sender: Sender = .me) throws -> ChatMessage {
        do {
            // 保存录音文件到永久存储
            let permanentURL = try fileStorage.saveVoiceFile(from: tempURL)

            // 创建消息
            let message = ChatMessage.voice(localURL: permanentURL, duration: duration, sentAt: Date())
            try storage.append(message)

            // 删除临时文件
            try? fileStorage.deleteFile(at: tempURL)

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
    func sendImageMessage(tempURL: URL, sender: Sender = .me) throws -> ChatMessage {
        do {
            // 保存图片文件到永久存储
            let permanentURL = try fileStorage.saveImageFile(from: tempURL)

            // 创建消息
            let message = ChatMessage.image(localURL: permanentURL, sentAt: Date())
            try storage.append(message)

            // 删除临时文件
            try? fileStorage.deleteFile(at: tempURL)

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
    func sendVideoMessage(tempURL: URL, duration: TimeInterval, sender: Sender = .me) throws -> ChatMessage {
        do {
            // 保存视频文件到永久存储
            let permanentURL = try fileStorage.saveVideoFile(from: tempURL)

            // 创建消息
            let message = ChatMessage.video(localURL: permanentURL, duration: duration, sentAt: Date())
            try storage.append(message)

            // 删除临时文件
            try? fileStorage.deleteFile(at: tempURL)

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
    func sendLocationMessage(latitude: Double, longitude: Double, address: String?, sender: Sender = .me) throws -> ChatMessage {
        let message = ChatMessage.location(latitude: latitude, longitude: longitude, address: address, sentAt: Date())
        try storage.append(message)
        logger.info("Sent location message: \(message.id)")
        return message
    }

    /// 删除消息
    ///
    /// - Parameter id: 消息 ID
    /// - Throws: ChatError
    func deleteMessage(id: UUID) throws {
        do {
            // 加载消息以获取文件 URL
            let messages = try storage.load()
            guard let message = messages.first(where: { $0.id == id }) else {
                throw ChatError.messageNotFound(id: id)
            }

            // 删除关联的文件
            if let localURL = message.localURL {
                try? fileStorage.deleteFile(at: localURL)
            }

            // 从存储中删除消息
            try storage.delete(id: id)

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
    func recallMessage(id: UUID) throws {
        do {
            // 加载消息
            let messages = try storage.load()
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
                try? fileStorage.deleteFile(at: localURL)
            }

            // 创建撤回消息
            var recalledMessage = message
            recalledMessage.kind = .recalled(originalText: originalText)

            // 更新存储
            try storage.update(recalledMessage)

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
    func updateSendStatus(id: UUID, status: ChatMessage.SendStatus) throws {
        do {
            let messages = try storage.load()
            guard var message = messages.first(where: { $0.id == id }) else {
                throw ChatError.messageNotFound(id: id)
            }

            message.sendStatus = status
            try storage.update(message)

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
    func markAsPlayed(id: UUID) throws {
        do {
            let messages = try storage.load()
            guard var message = messages.first(where: { $0.id == id }) else {
                throw ChatError.messageNotFound(id: id)
            }

            message.isPlayed = true
            try storage.update(message)

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
    func cleanOrphanedFiles() -> Int {
        do {
            let messages = try storage.load()
            let referencedURLs = Set(messages.compactMap { $0.localURL })
            let cleanedCount = fileStorage.cleanOrphanedFiles(referencedURLs: referencedURLs)

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
                    sentAt: timestamp
                )
            case 1:
                message = ChatMessage.text(
                    "这是一条较长的历史消息，用于测试消息列表的显示效果 #\(i + 1)",
                    sender: i % 2 == 0 ? .me : .peer,
                    sentAt: timestamp
                )
            default:
                message = ChatMessage.text(
                    "历史消息内容 #\(i + 1)",
                    sender: i % 2 == 0 ? .me : .peer,
                    sentAt: timestamp
                )
            }

            historyMessages.append(message)
        }

        logger.info("Loaded \(historyMessages.count) history messages for page \(page)")
        return historyMessages
    }
}
