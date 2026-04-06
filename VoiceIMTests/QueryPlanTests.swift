import Testing
import Foundation
import GRDB
@testable import VoiceIM

@Suite("Query Plan Tests")
struct QueryPlanTests {

    private func makeDatabase() throws -> DatabaseManager {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceim-query-plan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("test.sqlite").path
        return try DatabaseManager(path: dbPath)
    }

    private func explainDetails(_ db: Database, sql: String, arguments: StatementArguments = StatementArguments()) throws -> [String] {
        try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(sql)", arguments: arguments).compactMap { row in
            row["detail"] as String?
        }
    }

    @Test("聊天分页查询命中 idx_messages_conv_seq")
    func testMessagePagingPlanUsesConversationSeqIndex() throws {
        let manager = try makeDatabase()
        let details = try manager.read { db in
            try explainDetails(
                db,
                sql: "SELECT id FROM messages WHERE conversation_id = ? ORDER BY seq DESC LIMIT 20",
                arguments: ["c1"]
            )
        }
        #expect(details.contains { $0.localizedCaseInsensitiveContains("idx_messages_conv_seq") })
        #expect(!details.contains { $0.localizedCaseInsensitiveContains("SCAN messages") })
    }

    @Test("未读聚合查询命中 idx_members_user_unread")
    func testUnreadPlanUsesMembersUnreadIndex() throws {
        let manager = try makeDatabase()
        let details = try manager.read { db in
            try explainDetails(
                db,
                sql: "SELECT conversation_id, unread_count FROM conversation_members WHERE user_id = ? ORDER BY unread_count DESC",
                arguments: [Sender.me.id]
            )
        }
        #expect(details.contains { $0.localizedCaseInsensitiveContains("idx_members_user_unread") })
    }
}
