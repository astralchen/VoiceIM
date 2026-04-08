import Testing
import Foundation
@testable import VoiceIM

/// `MessageRepository` 单元测试：独立 SQLite 文件 + 注入 `MessageStore` / `ReceiptStore`，避免污染应用沙盒数据库。
@Suite("MessageRepository 测试")
@MainActor
struct MessageRepositoryTests {

    /// 测试夹具：临时目录、数据库、仓库与用于构造「对方消息」的 `MessageStore`。
    private struct TestContext {
        let repository: MessageRepository
        let messageStore: MessageStore
        let temporaryDirectory: URL
    }

    private func makeContext(contactID: String = "测试联系人-01") throws -> TestContext {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceim-repo-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let databasePath = temporaryDirectory.appendingPathComponent("test.sqlite").path
        let databaseManager = try DatabaseManager(path: databasePath)
        let messageStore = MessageStore(db: databaseManager)
        let receiptStore = ReceiptStore(db: databaseManager)
        let fileStorage = FileStorageManager(testMode: true)
        let logger = ConsoleLogger(minimumLevel: .error)
        let repository = MessageRepository(
            messageStorage: messageStore,
            receiptStorage: receiptStore,
            fileStorage: fileStorage,
            contactID: contactID,
            logger: logger
        )
        return TestContext(
            repository: repository,
            messageStore: messageStore,
            temporaryDirectory: temporaryDirectory
        )
    }

    /// 通过存储层写入一条对方发来的文本（仓库侧无「接收」API 时用于夹具）。
    private func appendIncomingText(
        messageStore: MessageStore,
        contactID: String,
        content: String
    ) async throws {
        let message = ChatMessage(
            kind: .text(content),
            sender: Sender(id: contactID, displayName: contactID),
            sentAt: Date(),
            isPlayed: true,
            isRead: false,
            sendStatus: .delivered
        )
        try await messageStore.append(message, contactID: contactID)
    }

    @Test("发送文本后可加载且内容与条数正确")
    func sendTextThenLoad() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.temporaryDirectory) }

        let sent = try await context.repository.sendTextMessage(text: "你好，仓库测试")
        let loaded = try await context.repository.loadMessages()
        #expect(loaded.count == 1)
        #expect(loaded[0].id == sent.id)
        if case let .text(body) = loaded[0].kind {
            #expect(body == "你好，仓库测试")
        } else {
            Issue.record("应为文本消息")
        }
    }

    @Test("标记整会话已读后，对方消息应变为已读")
    func markConversationAsReadUpdatesPeerMessages() async throws {
        let contactID = "同伴-A"
        let context = try makeContext(contactID: contactID)
        defer { try? FileManager.default.removeItem(at: context.temporaryDirectory) }

        try await appendIncomingText(
            messageStore: context.messageStore,
            contactID: contactID,
            content: "未读一条"
        )
        var loaded = try await context.repository.loadMessages()
        #expect(loaded.first?.isRead == false)

        try await context.repository.markConversationAsRead()
        loaded = try await context.repository.loadMessages()
        #expect(loaded.first?.isRead == true)
    }

    @Test("删除不存在的消息应抛出 messageNotFound")
    func deleteMissingMessageThrows() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.temporaryDirectory) }

        do {
            try await context.repository.deleteMessage(id: "不存在的标识")
            Issue.record("应抛出 ChatError.messageNotFound")
        } catch let error as ChatError {
            guard case .messageNotFound = error else {
                Issue.record("期望 messageNotFound，实际为其他 ChatError")
                return
            }
        } catch {
            Issue.record("期望 ChatError")
        }
    }

    @Test("撤回：先置为已送达再撤回，类型变为 recalled")
    func recallDeliveredOutgoingText() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.temporaryDirectory) }

        let sent = try await context.repository.sendTextMessage(text: "待撤回")
        try await context.repository.updateSendStatus(id: sent.id, status: .delivered)
        try await context.repository.recallMessage(id: sent.id)

        let loaded = try await context.repository.loadMessages()
        #expect(loaded.count == 1)
        if case let .recalled(original) = loaded[0].kind {
            #expect(original == "待撤回")
        } else {
            Issue.record("应为撤回类型")
        }
    }

    @Test("发送语音：临时文件经 FileStorage 落盘并写入会话")
    func sendVoiceMessagePersists() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.temporaryDirectory) }

        let tempURL = context.temporaryDirectory.appendingPathComponent("clip.m4a")
        try Data([0x00, 0x01, 0x02]).write(to: tempURL)

        let message = try await context.repository.sendVoiceMessage(tempURL: tempURL, duration: 2.5)
        #expect(FileManager.default.fileExists(atPath: tempURL.path) == false)

        let loaded = try await context.repository.loadMessages()
        #expect(loaded.count == 1)
        #expect(loaded[0].id == message.id)
        if case .voice(_, _, let duration) = loaded[0].kind {
            #expect(abs(duration - 2.5) < 0.01)
        } else {
            Issue.record("应为语音消息")
        }
    }

    @Test("发送位置消息后能正确加载")
    func sendLocationMessageLoads() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.temporaryDirectory) }

        let sent = try await context.repository.sendLocationMessage(
            latitude: 31.2,
            longitude: 121.5,
            address: "测试路 1 号"
        )
        let loaded = try await context.repository.loadMessages()
        #expect(loaded.count == 1)
        if case let .location(lat, lon, addr) = loaded[0].kind {
            #expect(abs(lat - 31.2) < 0.001)
            #expect(abs(lon - 121.5) < 0.001)
            #expect(addr == "测试路 1 号")
        } else {
            Issue.record("应为位置消息")
        }
        #expect(loaded[0].id == sent.id)
    }

    @Test("游标历史：按最老消息向前分页")
    func loadHistoryByCursor() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.temporaryDirectory) }

        for index in 0..<5 {
            _ = try await context.repository.sendTextMessage(text: "第\(index)条")
        }

        // 最近 2 条：第3条、第4条（旧 -> 新）
        let recent = try await context.repository.loadHistory(beforeMessageID: nil, limit: 2)
        #expect(recent.count == 2)
        if case let .text(t0) = recent[0].kind { #expect(t0 == "第3条") }
        else { Issue.record("最近页首条应为第3条") }
        if case let .text(t1) = recent[1].kind { #expect(t1 == "第4条") }
        else { Issue.record("最近页末条应为第4条") }

        // 以前一页最老消息为锚点继续向前：第1条、第2条
        let older = try await context.repository.loadHistory(
            beforeMessageID: recent.first?.id,
            limit: 2
        )
        #expect(older.count == 2)
        if case let .text(t2) = older[0].kind { #expect(t2 == "第1条") }
        else { Issue.record("第二页首条应为第1条") }
        if case let .text(t3) = older[1].kind { #expect(t3 == "第2条") }
        else { Issue.record("第二页末条应为第2条") }

        // 继续向前应只剩第0条
        let oldest = try await context.repository.loadHistory(
            beforeMessageID: older.first?.id,
            limit: 2
        )
        #expect(oldest.count == 1)
        if case let .text(t4) = oldest[0].kind { #expect(t4 == "第0条") }
        else { Issue.record("第三页应为第0条") }

        // 已无更多历史
        let empty = try await context.repository.loadHistory(
            beforeMessageID: oldest.first?.id,
            limit: 2
        )
        #expect(empty.isEmpty)
    }
}
