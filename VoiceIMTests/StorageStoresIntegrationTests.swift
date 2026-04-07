import Testing
import Foundation
@testable import VoiceIM

/// 验证 `MessageStore` / `ConversationStore` / `ReceiptStore` 共用同一 `DatabaseManager` 时数据一致（与 `AppDependencies` 装配方式一致）。
@Suite("多 Store 集成测试")
struct StorageStoresIntegrationTests {

    private struct TestStores {
        let messageStore: MessageStore
        let conversationStore: ConversationStore
        let receiptStore: ReceiptStore
        let temporaryDirectory: URL
    }

    private func makeStores() throws -> TestStores {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceim-stores-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let databasePath = temporaryDirectory.appendingPathComponent("test.sqlite").path
        let databaseManager = try DatabaseManager(path: databasePath)
        return TestStores(
            messageStore: MessageStore(db: databaseManager),
            conversationStore: ConversationStore(db: databaseManager),
            receiptStore: ReceiptStore(db: databaseManager),
            temporaryDirectory: temporaryDirectory
        )
    }

    @Test("写入消息后，会话列表摘要与未读数一致")
    func messageAppendReflectsInConversationSummaryAndUnread() async throws {
        let stores = try makeStores()
        defer { try? FileManager.default.removeItem(at: stores.temporaryDirectory) }

        let contactID = "集成-会话甲"
        let outgoing = ChatMessage(
            kind: .text("我发的"),
            sender: .me,
            sentAt: Date(),
            isPlayed: true,
            isRead: true,
            sendStatus: .delivered
        )
        try await stores.messageStore.append(outgoing, contactID: contactID)

        let incoming = ChatMessage(
            kind: .text("对方来的"),
            sender: Sender(id: contactID, displayName: contactID),
            sentAt: Date(),
            isPlayed: true,
            isRead: false,
            sendStatus: .delivered
        )
        try await stores.messageStore.append(incoming, contactID: contactID)

        let unread = try await stores.receiptStore.unreadCount(conversationID: contactID)
        #expect(unread == 1)

        let summaries = try await stores.conversationStore.loadConversationSummaries()
        let row = summaries.first { $0.0.id == contactID }
        #expect(row != nil)
        #expect(row?.1 == 1)
        #expect(row?.3.contains("对方") == true)

        try await stores.receiptStore.markConversationAsRead(contactID: contactID)
        let unreadAfter = try await stores.receiptStore.unreadCount(conversationID: contactID)
        #expect(unreadAfter == 0)
    }

    @Test("物理删除会话后，消息与列表均不可见")
    func deleteConversationRemovesMessages() async throws {
        let stores = try makeStores()
        defer { try? FileManager.default.removeItem(at: stores.temporaryDirectory) }

        let contactID = "待删会话"
        let message = ChatMessage(
            kind: .text("仅一条"),
            sender: .me,
            sentAt: Date(),
            isPlayed: true,
            isRead: true,
            sendStatus: .delivered
        )
        try await stores.messageStore.append(message, contactID: contactID)
        try await stores.conversationStore.deleteConversation(contactID: contactID)

        let messages = try await stores.messageStore.load(contactID: contactID)
        #expect(messages.isEmpty)

        let allIDs = try await stores.conversationStore.loadAllConversationIDs()
        #expect(allIDs.contains(contactID) == false)
    }
}
