import Testing
import Foundation
@testable import VoiceIM

@Suite("Conversation Storage Regression Tests")
struct ConversationStorageRegressionTests {

    private func makeStorage() throws -> MessageStorage {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceim-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("test.sqlite").path
        let manager = try DatabaseManager(path: dbPath)
        return MessageStorage(db: manager)
    }

    private func makeOutgoingText(_ text: String, at date: Date) -> ChatMessage {
        ChatMessage(
            kind: .text(text),
            sender: .me,
            sentAt: date,
            isPlayed: true,
            isRead: true,
            sendStatus: .delivered
        )
    }

    private func makeIncomingText(contactID: String, text: String, at date: Date) -> ChatMessage {
        ChatMessage(
            kind: .text(text),
            sender: Sender(id: contactID, displayName: contactID),
            sentAt: date,
            isPlayed: true,
            isRead: false,
            sendStatus: .delivered
        )
    }

    @Test("置顶/取消置顶后排序回归（无新消息回原位，有新消息按活跃度前置）")
    func pinUnpinSortingRegression() async throws {
        let storage = try makeStorage()
        let contactA = "zhangsan"
        let contactB = "lisi"
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        try await storage.append(makeOutgoingText("A-1", at: base), contactID: contactA)
        try await storage.append(makeOutgoingText("B-1", at: base.addingTimeInterval(10)), contactID: contactB)

        var summaries = try await storage.loadConversationSummaries()
        #expect(summaries.map { $0.0.id } == [contactB, contactA])

        try await storage.setConversationPinned(contactID: contactA, pinned: true)
        summaries = try await storage.loadConversationSummaries()
        #expect(summaries.map { $0.0.id } == [contactA, contactB])
        #expect(summaries.first?.2 == true)

        try await storage.setConversationPinned(contactID: contactA, pinned: false)
        summaries = try await storage.loadConversationSummaries()
        #expect(summaries.map { $0.0.id } == [contactB, contactA])

        try await storage.append(makeOutgoingText("A-2", at: base.addingTimeInterval(20)), contactID: contactA)
        summaries = try await storage.loadConversationSummaries()
        #expect(summaries.map { $0.0.id } == [contactA, contactB])
    }

    @Test("隐藏会话后，发送或接收新消息会自动恢复显示")
    func hiddenConversationAutoRestoreOnNewMessage() async throws {
        let storage = try makeStorage()
        let contact = "wangwu"
        let base = Date(timeIntervalSince1970: 1_700_000_500)

        try await storage.append(makeOutgoingText("init", at: base), contactID: contact)
        var ids = try await storage.loadConversationSummaries().map { $0.0.id }
        #expect(ids.contains(contact))

        try await storage.setConversationHidden(contactID: contact, hidden: true)
        ids = try await storage.loadConversationSummaries().map { $0.0.id }
        #expect(!ids.contains(contact))

        try await storage.append(makeOutgoingText("outgoing-restore", at: base.addingTimeInterval(5)), contactID: contact)
        ids = try await storage.loadConversationSummaries().map { $0.0.id }
        #expect(ids.contains(contact))

        try await storage.setConversationHidden(contactID: contact, hidden: true)
        ids = try await storage.loadConversationSummaries().map { $0.0.id }
        #expect(!ids.contains(contact))

        try await storage.append(
            makeIncomingText(contactID: contact, text: "incoming-restore", at: base.addingTimeInterval(10)),
            contactID: contact
        )
        let summaries = try await storage.loadConversationSummaries()
        ids = summaries.map { $0.0.id }
        #expect(ids.contains(contact))
        let unread = summaries.first(where: { $0.0.id == contact })?.1 ?? 0
        #expect(unread > 0)
    }
}
