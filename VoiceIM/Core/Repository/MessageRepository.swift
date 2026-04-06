import Foundation

/// 消息仓库：封装消息的业务逻辑
///
/// 所有读写通过 `MessageStorage` 对应的会话 `contactID` 进行隔离。
/// 写操作在 `MessageStorage` 内部以事务方式同步更新会话、成员、回执等关联表。
@MainActor
final class MessageRepository {

    private let storage: MessageStorage
    private let fileStorage: any FileStorageProtocol
    private let imageCache: ImageCacheManager
    private let videoCache: VideoCacheManager
    private let logger: Logger
    /// 过渡期兼容：现阶段单聊会话 ID 与 contactID 相同。
    let conversationID: String

    init(
        storage: MessageStorage = .shared,
        fileStorage: any FileStorageProtocol = FileStorageManager.shared,
        contactID: String,
        imageCache: ImageCacheManager? = nil,
        videoCache: VideoCacheManager? = nil,
        logger: Logger = VoiceIM.logger
    ) {
        self.storage = storage
        self.fileStorage = fileStorage
        self.imageCache = imageCache ?? ImageCacheManager.shared
        self.videoCache = videoCache ?? VideoCacheManager.shared
        self.logger = logger
        self.conversationID = contactID
    }

    // MARK: - 消息操作

    func loadMessages() async throws -> [ChatMessage] {
        do {
            let messages = try await storage.load(contactID: conversationID)
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
            try await storage.append(message, contactID: conversationID)
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
            try await storage.append(message, contactID: conversationID)
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
            try await storage.append(message, contactID: conversationID)
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
            try await storage.append(message, contactID: conversationID)
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
            try await storage.append(message, contactID: conversationID)
            logger.info("Sent location message: \(message.id)")
            return message
        } catch {
            logger.error("Failed to send location message: \(error)")
            throw ChatError.messageSendFailed
        }
    }

    func deleteMessage(id: String) async throws {
        do {
            let messages = try await storage.load(contactID: conversationID)
            guard let message = messages.first(where: { $0.id == id }) else {
                throw ChatError.messageNotFound(id: id)
            }
            if let localURL = message.localURL {
                try? await fileStorage.deleteFile(at: localURL)
            }
            try await storage.delete(id: id, contactID: conversationID)
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
            let messages = try await storage.load(contactID: conversationID)
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
            try await storage.update(recalledMessage, contactID: conversationID)
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
            let messages = try await storage.load(contactID: conversationID)
            guard var message = messages.first(where: { $0.id == id }) else {
                throw ChatError.messageNotFound(id: id)
            }
            message.sendStatus = status
            try await storage.update(message, contactID: conversationID)
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
            let messages = try await storage.load(contactID: conversationID)
            guard var message = messages.first(where: { $0.id == id }) else {
                throw ChatError.messageNotFound(id: id)
            }
            message.isPlayed = true
            message.isRead = true
            try await storage.update(message, contactID: conversationID)
            logger.debug("Marked message \(id) as played")
        } catch let error as ChatError {
            throw error
        } catch {
            logger.error("Failed to mark message as played: \(error)")
            throw ChatError.storageWriteFailed
        }
    }

    func markConversationAsRead() async throws {
        do {
            try await storage.markConversationAsRead(contactID: conversationID)
        } catch {
            logger.error("Failed to mark conversation as read: \(error)")
            throw ChatError.storageWriteFailed
        }
    }

    func cleanOrphanedFiles() async -> Int {
        do {
            let messages = try await storage.load(contactID: conversationID)
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
            let allMessages = try await storage.load(contactID: conversationID)
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
