import Testing
import Foundation
@testable import VoiceIM

/// MessageRepository 单元测试
@Suite("MessageRepository Tests")
struct MessageRepositoryTests {

    // MARK: - Mock 实现

    actor MockMessageStorage: MessageStorage {
        private var messages: [UUID: ChatMessage] = [:]

        func save(_ message: ChatMessage) throws {
            messages[message.id] = message
        }

        func saveMultiple(_ newMessages: [ChatMessage]) throws {
            for message in newMessages {
                messages[message.id] = message
            }
        }

        func update(_ message: ChatMessage) throws {
            guard messages[message.id] != nil else {
                throw ChatError.messageNotFound(message.id)
            }
            messages[message.id] = message
        }

        func delete(id: UUID) throws {
            guard messages.removeValue(forKey: id) != nil else {
                throw ChatError.messageNotFound(id)
            }
        }

        func load(id: UUID) -> ChatMessage? {
            messages[id]
        }

        func loadAll() -> [ChatMessage] {
            Array(messages.values).sorted { $0.sentAt < $1.sentAt }
        }

        func clear() throws {
            messages.removeAll()
        }
    }

    actor MockFileStorage: FileStorageService {
        private var files: Set<URL> = []

        func save(_ data: Data, type: FileStorageManager.FileType, filename: String?) throws -> URL {
            let url = URL(fileURLWithPath: "/tmp/\(filename ?? UUID().uuidString)")
            files.insert(url)
            return url
        }

        func move(_ sourceURL: URL, to type: FileStorageManager.FileType, filename: String?) throws -> URL {
            let url = URL(fileURLWithPath: "/tmp/\(filename ?? UUID().uuidString)")
            files.remove(sourceURL)
            files.insert(url)
            return url
        }

        func delete(_ url: URL) throws {
            files.remove(url)
        }

        func deleteMultiple(_ urls: [URL]) async -> [URL] {
            for url in urls {
                files.remove(url)
            }
            return []
        }

        func fileExists(at url: URL) -> Bool {
            files.contains(url)
        }

        func fileSize(at url: URL) -> Int64 {
            1024
        }

        func cacheSize(for type: FileStorageManager.FileType?) -> Int64 {
            Int64(files.count * 1024)
        }

        func clearCache(for type: FileStorageManager.FileType) throws {
            files.removeAll()
        }

        func clearAllCache() throws {
            files.removeAll()
        }

        func cleanupOrphanedFiles(validURLs: Set<URL>) async -> Int {
            let orphaned = files.subtracting(validURLs)
            files.subtract(orphaned)
            return orphaned.count
        }
    }

    struct MockNetworkService: NetworkService {
        func sendMessage(_ message: ChatMessage) async throws -> ChatMessage {
            var sent = message
            sent.sendStatus = .delivered
            return sent
        }

        func recallMessage(id: UUID) async throws {}

        func fetchHistory(page: Int) async throws -> [ChatMessage] {
            []
        }
    }

    // MARK: - 测试用例

    @Test("发送消息成功")
    func testSendMessageSuccess() async throws {
        let storage = MockMessageStorage()
        let fileStorage = MockFileStorage()
        let network = MockNetworkService()
        let repository = MessageRepository(storage: storage, fileStorage: fileStorage, networkService: network)

        let message = ChatMessage.text("Hello")
        let sent = try await repository.sendMessage(message)

        #expect(sent.sendStatus == .delivered)
        let loaded = await storage.load(id: message.id)
        #expect(loaded != nil)
        #expect(loaded?.sendStatus == .delivered)
    }

    @Test("删除消息")
    func testDeleteMessage() async throws {
        let storage = MockMessageStorage()
        let fileStorage = MockFileStorage()
        let network = MockNetworkService()
        let repository = MessageRepository(storage: storage, fileStorage: fileStorage, networkService: network)

        let message = ChatMessage.text("Hello")
        try await storage.save(message)

        try await repository.deleteMessage(id: message.id)

        let loaded = await storage.load(id: message.id)
        #expect(loaded == nil)
    }

    @Test("撤回消息成功")
    func testRecallMessageSuccess() async throws {
        let storage = MockMessageStorage()
        let fileStorage = MockFileStorage()
        let network = MockNetworkService()
        let repository = MessageRepository(storage: storage, fileStorage: fileStorage, networkService: network)

        var message = ChatMessage.text("Hello", sender: .me)
        message.sendStatus = .delivered
        try await storage.save(message)

        let recalled = try await repository.recallMessage(id: message.id)

        #expect(recalled.kind == .recalled(originalText: "Hello"))
    }

    @Test("撤回消息失败 - 非本人消息")
    func testRecallMessageFailureNotOwner() async throws {
        let storage = MockMessageStorage()
        let fileStorage = MockFileStorage()
        let network = MockNetworkService()
        let repository = MessageRepository(storage: storage, fileStorage: fileStorage, networkService: network)

        var message = ChatMessage.text("Hello", sender: .peer)
        message.sendStatus = .delivered
        try await storage.save(message)

        await #expect(throws: ChatError.self) {
            try await repository.recallMessage(id: message.id)
        }
    }

    @Test("撤回消息失败 - 超时")
    func testRecallMessageFailureTimeout() async throws {
        let storage = MockMessageStorage()
        let fileStorage = MockFileStorage()
        let network = MockNetworkService()
        let repository = MessageRepository(storage: storage, fileStorage: fileStorage, networkService: network)

        var message = ChatMessage.text("Hello", sender: .me, sentAt: Date().addingTimeInterval(-4 * 60))
        message.sendStatus = .delivered
        try await storage.save(message)

        await #expect(throws: ChatError.self) {
            try await repository.recallMessage(id: message.id)
        }
    }

    @Test("标记消息为已播放")
    func testMarkAsPlayed() async throws {
        let storage = MockMessageStorage()
        let fileStorage = MockFileStorage()
        let network = MockNetworkService()
        let repository = MessageRepository(storage: storage, fileStorage: fileStorage, networkService: network)

        let url = URL(fileURLWithPath: "/tmp/test.m4a")
        var message = ChatMessage.voice(localURL: url, duration: 5.0)
        message.isPlayed = false
        try await storage.save(message)

        try await repository.markAsPlayed(id: message.id)

        let loaded = await storage.load(id: message.id)
        #expect(loaded?.isPlayed == true)
    }
}
