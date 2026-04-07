import Foundation

/// 消息仓库：封装消息的业务逻辑
///
/// 消息读写通过 `MessageStorageProtocol`、会话已读通过 `ReceiptStorageProtocol`，按会话 `contactID` 隔离。
@MainActor
final class MessageRepository {

    /// 消息 CRUD、列表加载等均走消息存储。
    private let messageStorage: any MessageStorageProtocol
    /// 整会话已读、未读计数与 `message_receipts` / `conversation_members` 对齐，单独抽象便于与列表侧 `ConversationStorageProtocol` 分工。
    private let receiptStorage: any ReceiptStorageProtocol
    private let fileStorage: any FileStorageProtocol
    private let imageCache: ImageCacheManager
    private let videoCache: VideoCacheManager
    private let logger: Logger
    /// 过渡期兼容：现阶段单聊会话 ID 与 contactID 相同。
    let conversationID: String

    init(
        messageStorage: any MessageStorageProtocol = MessageStore.shared,
        receiptStorage: any ReceiptStorageProtocol = ReceiptStore.shared,
        fileStorage: any FileStorageProtocol = FileStorageManager.shared,
        contactID: String,
        imageCache: ImageCacheManager? = nil,
        videoCache: VideoCacheManager? = nil,
        logger: Logger = VoiceIM.logger
    ) {
        self.messageStorage = messageStorage
        self.receiptStorage = receiptStorage
        self.fileStorage = fileStorage
        self.imageCache = imageCache ?? ImageCacheManager.shared
        self.videoCache = videoCache ?? VideoCacheManager.shared
        self.logger = logger
        self.conversationID = contactID
    }

    // MARK: - 消息操作

    func loadMessages() async throws -> [ChatMessage] {
        do {
            let messages = try await messageStorage.load(contactID: conversationID)
            logger.info("Loaded \(messages.count) messages from storage")
            return messages
        } catch {
            logger.error("Failed to load messages: \(error)")
            throw ChatError.storageReadFailed
        }
    }

    func sendTextMessage(text: String, sender: Sender = .me) async throws -> ChatMessage {
        do {
            let message = ChatMessage.text(text, sender: sender, sentAt: Date())
            try await messageStorage.append(message, contactID: conversationID)
            logger.info("Sent text message: \(message.id)")
            return message
        } catch {
            logger.error("Failed to send text message: \(error)")
            throw ChatError.messageSendFailed
        }
    }

    func sendVoiceMessage(tempURL: URL, duration: TimeInterval, sender: Sender = .me) async throws -> ChatMessage {
        do {
            let permanentURL = try await fileStorage.saveVoiceFile(from: tempURL)
            let message = ChatMessage.voice(localURL: permanentURL, duration: duration, sentAt: Date())
            try await messageStorage.append(message, contactID: conversationID)
            try? await fileStorage.deleteFile(at: tempURL)
            logger.info("Sent voice message: \(message.id), duration: \(duration)s")
            return message
        } catch {
            logger.error("Failed to send voice message: \(error)")
            throw ChatError.messageSendFailed
        }
    }

    func sendImageMessage(tempURL: URL, sender: Sender = .me) async throws -> ChatMessage {
        do {
            let cacheURL = try await imageCache.saveAndCacheImage(from: tempURL)
            try? await fileStorage.deleteFile(at: tempURL)
            let message = ChatMessage.image(localURL: cacheURL, sentAt: Date())
            try await messageStorage.append(message, contactID: conversationID)
            logger.info("Sent image message: \(message.id)")
            return message
        } catch {
            logger.error("Failed to send image message: \(error)")
            throw ChatError.messageSendFailed
        }
    }

    func sendVideoMessage(tempURL: URL, duration: TimeInterval, sender: Sender = .me) async throws -> ChatMessage {
        do {
            let cacheURL = try await videoCache.saveAndCacheVideo(from: tempURL)
            try? FileManager.default.removeItem(at: tempURL)
            let message = ChatMessage.video(localURL: cacheURL, duration: duration, sentAt: Date())
            try await messageStorage.append(message, contactID: conversationID)
            logger.info("Sent video message: \(message.id), duration: \(duration)s")
            return message
        } catch {
            logger.error("Failed to send video message: \(error)")
            throw ChatError.messageSendFailed
        }
    }

    func sendLocationMessage(latitude: Double, longitude: Double, address: String?, sender: Sender = .me) async throws -> ChatMessage {
        do {
            let message = ChatMessage.location(latitude: latitude, longitude: longitude, address: address, sentAt: Date())
            try await messageStorage.append(message, contactID: conversationID)
            logger.info("Sent location message: \(message.id)")
            return message
        } catch {
            logger.error("Failed to send location message: \(error)")
            throw ChatError.messageSendFailed
        }
    }

    func deleteMessage(id: String) async throws {
        do {
            let messages = try await messageStorage.load(contactID: conversationID)
            guard let message = messages.first(where: { $0.id == id }) else {
                throw ChatError.messageNotFound(id: id)
            }
            if let localURL = message.localURL {
                try? await fileStorage.deleteFile(at: localURL)
            }
            try await messageStorage.delete(id: id, contactID: conversationID)
            logger.info("Deleted message: \(id)")
        } catch let error as ChatError {
            throw error
        } catch {
            logger.error("Failed to delete message: \(error)")
            throw ChatError.messageDeleteFailed
        }
    }

    func recallMessage(id: String) async throws {
        do {
            let messages = try await messageStorage.load(contactID: conversationID)
            guard let message = messages.first(where: { $0.id == id }) else {
                throw ChatError.messageNotFound(id: id)
            }
            guard message.isOutgoing else { throw ChatError.messageRecallFailed }
            guard message.sendStatus == .delivered else { throw ChatError.messageRecallFailed }
            guard Date().timeIntervalSince(message.sentAt) <= 3 * 60 else { throw ChatError.messageRecallFailed }

            let originalText: String?
            if case .text(let content) = message.kind { originalText = content } else { originalText = nil }

            if let localURL = message.localURL {
                try? await fileStorage.deleteFile(at: localURL)
            }

            var recalledMessage = message
            recalledMessage.kind = .recalled(originalText: originalText)
            try await messageStorage.update(recalledMessage, contactID: conversationID)
            logger.info("Recalled message: \(id)")
        } catch let error as ChatError {
            throw error
        } catch {
            logger.error("Failed to recall message: \(error)")
            throw ChatError.messageRecallFailed
        }
    }

    func updateSendStatus(id: String, status: ChatMessage.SendStatus) async throws {
        do {
            let messages = try await messageStorage.load(contactID: conversationID)
            guard var message = messages.first(where: { $0.id == id }) else {
                throw ChatError.messageNotFound(id: id)
            }
            message.sendStatus = status
            try await messageStorage.update(message, contactID: conversationID)
            logger.debug("Updated message \(id) status to \(status)")
        } catch let error as ChatError {
            throw error
        } catch {
            logger.error("Failed to update message status: \(error)")
            throw ChatError.storageWriteFailed
        }
    }

    func markAsPlayed(id: String) async throws {
        do {
            let messages = try await messageStorage.load(contactID: conversationID)
            guard var message = messages.first(where: { $0.id == id }) else {
                throw ChatError.messageNotFound(id: id)
            }
            message.isPlayed = true
            message.isRead = true
            try await messageStorage.update(message, contactID: conversationID)
            logger.debug("Marked message \(id) as played")
        } catch let error as ChatError {
            throw error
        } catch {
            logger.error("Failed to mark message as played: \(error)")
            throw ChatError.storageWriteFailed
        }
    }

    /// 故意走 `ReceiptStorageProtocol`：聊天页不依赖会话列表用的 `ConversationStorageProtocol`，减少门面交叉引用。
    func markConversationAsRead() async throws {
        do {
            try await receiptStorage.markConversationAsRead(contactID: conversationID)
        } catch {
            logger.error("Failed to mark conversation as read: \(error)")
            throw ChatError.storageWriteFailed
        }
    }

    func cleanOrphanedFiles() async -> Int {
        do {
            let messages = try await messageStorage.load(contactID: conversationID)
            let referencedURLs = Set(messages.compactMap { $0.localURL })
            let cleanedCount = await fileStorage.cleanOrphanedFiles(referencedURLs: referencedURLs)
            logger.info("Cleaned \(cleanedCount) orphaned files")
            return cleanedCount
        } catch {
            logger.error("Failed to clean orphaned files: \(error)")
            return 0
        }
    }

    func loadHistory(page: Int, pageSize: Int = 20) async throws -> [ChatMessage] {
        do {
            let allMessages = try await messageStorage.load(contactID: conversationID)
            let startIndex = page * pageSize
            guard startIndex < allMessages.count else { return [] }
            let endIndex = min(startIndex + pageSize, allMessages.count)
            let slice = Array(allMessages.reversed()[startIndex..<endIndex])
            return slice
        } catch {
            logger.error("Failed to load history: \(error)")
            throw ChatError.storageReadFailed
        }
    }
}
