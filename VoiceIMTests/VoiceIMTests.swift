import XCTest
@testable import VoiceIM

/// MessageRepository 单元测试
@MainActor
final class MessageRepositoryTests: XCTestCase {

    var repository: MessageRepository!
    var mockFileStorage: FileStorageManager!
    var mockCacheService: VoiceCacheManager!

    override func setUp() async throws {
        mockFileStorage = FileStorageManager()
        mockCacheService = VoiceCacheManager.shared
        repository = MessageRepository(
            fileStorage: mockFileStorage,
            cacheService: mockCacheService
        )
    }

    override func tearDown() async throws {
        repository = nil
        mockFileStorage = nil
        mockCacheService = nil
    }

    // MARK: - 发送消息测试

    func testSendMessageSuccess() async throws {
        // Given
        let message = ChatMessage.text("Hello")

        // When
        let sentMessage = try await repository.sendMessage(message)

        // Then
        XCTAssertEqual(sentMessage.id, message.id)
        // 注意：由于是模拟发送，70% 成功率，这个测试可能失败
        // 生产环境应使用 mock 网络服务保证 100% 成功
    }

    // MARK: - 历史消息测试

    func testFetchHistory() async throws {
        // When
        let messages = try await repository.fetchHistory(page: 0)

        // Then
        XCTAssertFalse(messages.isEmpty)
        XCTAssertEqual(messages.count, 5)
    }

    func testFetchHistoryMultiplePages() async throws {
        // When
        let page0 = try await repository.fetchHistory(page: 0)
        let page1 = try await repository.fetchHistory(page: 1)

        // Then
        XCTAssertEqual(page0.count, 5)
        XCTAssertEqual(page1.count, 4)
    }

    // MARK: - 撤回消息测试

    func testRecallMessageSuccess() async throws {
        // Given
        let message = ChatMessage.text("Test", sender: .me, sentAt: Date())
        var mutableMessage = message
        mutableMessage.sendStatus = .delivered

        // When
        let recalledMessage = try await repository.recallMessage(
            id: message.id,
            message: mutableMessage
        )

        // Then
        if case .recalled(let originalText) = recalledMessage.kind {
            XCTAssertEqual(originalText, "Test")
        } else {
            XCTFail("Expected recalled message")
        }
    }

    func testRecallMessageFailureNotOwner() async throws {
        // Given
        let message = ChatMessage.text("Test", sender: .peer, sentAt: Date())

        // When/Then
        do {
            _ = try await repository.recallMessage(id: message.id, message: message)
            XCTFail("Should throw error")
        } catch let error as ChatError {
            if case .recallFailed(let reason) = error {
                XCTAssertEqual(reason, .notOwner)
            } else {
                XCTFail("Expected recallFailed error")
            }
        }
    }

    func testRecallMessageFailureTimeExpired() async throws {
        // Given
        let oldDate = Date().addingTimeInterval(-4 * 60) // 4 分钟前
        let message = ChatMessage.text("Test", sender: .me, sentAt: oldDate)
        var mutableMessage = message
        mutableMessage.sendStatus = .delivered

        // When/Then
        do {
            _ = try await repository.recallMessage(id: message.id, message: mutableMessage)
            XCTFail("Should throw error")
        } catch let error as ChatError {
            if case .recallFailed(let reason) = error {
                XCTAssertEqual(reason, .timeExpired)
            } else {
                XCTFail("Expected recallFailed error")
            }
        }
    }
}

/// ChatError 单元测试
final class ChatErrorTests: XCTestCase {

    func testErrorDescription() {
        let error = ChatError.messageTooShort
        XCTAssertEqual(error.errorDescription, "说话时间太短")
    }

    func testNetworkError() {
        let error = ChatError.networkError(NSError(domain: "test", code: -1))
        XCTAssertTrue(error.isNetworkError)
    }

    func testPermissionError() {
        let error = ChatError.permissionDenied(.microphone)
        XCTAssertTrue(error.isPermissionError)
    }

    func testRetryableError() {
        let error = ChatError.timeout
        XCTAssertTrue(error.isRetryable)
    }
}

/// RecallFailureReason 单元测试
final class RecallFailureReasonTests: XCTestCase {

    func testFromMessageNotOwner() {
        let message = ChatMessage.text("Test", sender: .peer)
        let reason = RecallFailureReason.from(message: message)
        XCTAssertEqual(reason, .notOwner)
    }

    func testFromMessageNotDelivered() {
        let message = ChatMessage.text("Test", sender: .me)
        let reason = RecallFailureReason.from(message: message)
        XCTAssertEqual(reason, .notDelivered)
    }

    func testFromMessageTimeExpired() {
        let oldDate = Date().addingTimeInterval(-4 * 60)
        let message = ChatMessage.text("Test", sender: .me, sentAt: oldDate)
        var mutableMessage = message
        mutableMessage.sendStatus = .delivered
        let reason = RecallFailureReason.from(message: mutableMessage)
        XCTAssertEqual(reason, .timeExpired)
    }

    func testFromMessageValid() {
        let message = ChatMessage.text("Test", sender: .me, sentAt: Date())
        var mutableMessage = message
        mutableMessage.sendStatus = .delivered
        let reason = RecallFailureReason.from(message: mutableMessage)
        XCTAssertNil(reason)
    }
}

/// LogManager 单元测试
final class LogManagerTests: XCTestCase {

    func testLogLevelComparison() {
        XCTAssertTrue(LogLevel.debug < LogLevel.info)
        XCTAssertTrue(LogLevel.info < LogLevel.warning)
        XCTAssertTrue(LogLevel.warning < LogLevel.error)
    }

    func testConsoleLogger() {
        let logger = ConsoleLogger()
        logger.minimumLevel = .warning

        // 不应输出（低于最低级别）
        logger.log("Debug message", level: .debug, file: #file, line: #line, function: #function)

        // 应该输出
        logger.log("Warning message", level: .warning, file: #file, line: #line, function: #function)
    }
}

/// MessagePagingManager 单元测试
@MainActor
final class MessagePagingManagerTests: XCTestCase {

    var pagingManager: MessagePagingManager!

    override func setUp() async throws {
        pagingManager = MessagePagingManager()
    }

    override func tearDown() async throws {
        try await pagingManager.clear()
        pagingManager = nil
    }

    func testAppendMessage() async throws {
        // Given
        let message = ChatMessage.text("Test")

        // When
        try await pagingManager.append(message)

        // Then
        XCTAssertEqual(pagingManager.totalCount, 1)
        let loaded = try await pagingManager.message(at: 0)
        XCTAssertEqual(loaded?.id, message.id)
    }

    func testPrependMessages() async throws {
        // Given
        let message1 = ChatMessage.text("Message 1")
        try await pagingManager.append(message1)

        let newMessages = [
            ChatMessage.text("Message 0"),
        ]

        // When
        try await pagingManager.prepend(newMessages)

        // Then
        XCTAssertEqual(pagingManager.totalCount, 2)
        let first = try await pagingManager.message(at: 0)
        XCTAssertEqual(first?.id, newMessages[0].id)
    }

    func testDeleteMessage() async throws {
        // Given
        let message1 = ChatMessage.text("Message 1")
        let message2 = ChatMessage.text("Message 2")
        try await pagingManager.append(message1)
        try await pagingManager.append(message2)

        // When
        try await pagingManager.delete(at: 0)

        // Then
        XCTAssertEqual(pagingManager.totalCount, 1)
        let remaining = try await pagingManager.message(at: 0)
        XCTAssertEqual(remaining?.id, message2.id)
    }

    func testMemoryOptimization() async throws {
        // Given: 添加 100 条消息
        for i in 0..<100 {
            try await pagingManager.append(ChatMessage.text("Message \(i)"))
        }

        // When: 更新可见范围为 40-60
        await pagingManager.updateVisibleRange(40..<60)

        // Then: 内存占用应该减少（只保留可见范围 ± 缓冲区）
        let memoryUsage = pagingManager.memoryUsage()
        XCTAssertLessThan(memoryUsage, 100 * 1024) // 应该少于 100KB
    }
}
