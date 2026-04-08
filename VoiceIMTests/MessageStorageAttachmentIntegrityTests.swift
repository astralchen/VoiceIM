import Testing
import Foundation
import GRDB
@testable import VoiceIM

@Suite("MessageStorage Attachment Integrity Tests")
struct MessageStorageAttachmentIntegrityTests {

    private func makeStorage() throws -> (MessageStorage, DatabaseManager, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceim-attachment-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("test.sqlite").path
        let manager = try DatabaseManager(path: dbPath)
        let storage = MessageStorage(db: manager)
        return (storage, manager, dir)
    }

    @Test("写入附件时落库 sha256 与 size_bytes")
    func testAttachmentIntegrityPersistedOnAppend() async throws {
        let (storage, db, tmpDir) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let localURL = tmpDir.appendingPathComponent("voice.m4a")
        let data = "voice-payload".data(using: .utf8)!
        try data.write(to: localURL)

        var message = ChatMessage.voice(localURL: localURL, duration: 1.2, sentAt: Date())
        message.sendStatus = .delivered
        try await storage.append(message, contactID: "u1")

        let row = try db.read { database in
            try Row.fetchOne(
                database,
                sql: "SELECT sha256, size_bytes FROM message_attachments WHERE message_id = ?",
                arguments: [message.id]
            )
        }
        let sha: String? = row?["sha256"]
        let size: Int64? = row?["size_bytes"]

        #expect(sha != nil)
        #expect(size == Int64(data.count))
    }

    @Test("读取附件时若 hash 不匹配则回收本地文件并降级为远端")
    func testAttachmentIntegrityMismatchRecyclesLocalFile() async throws {
        let (storage, _, tmpDir) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let imageCacheDirectory = try ChatCacheBucket.image.ensureDirectory()
        let localURL = imageCacheDirectory
            .appendingPathComponent("integrity-\(UUID().uuidString).jpg")
        try FileManager.default.createDirectory(
            at: localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x01, 0x02, 0x03, 0x04]).write(to: localURL)

        let remoteURL = URL(string: "https://example.com/a.jpg")
        let message = ChatMessage(
            kind: .image(localURL: localURL, remoteURL: remoteURL),
            sender: .me,
            sentAt: Date(),
            isPlayed: true,
            isRead: true,
            sendStatus: .delivered
        )
        try await storage.append(message, contactID: "u2")

        // 篡改本地文件，触发 sha256 不匹配
        try Data([0xFF, 0xEE, 0xDD]).write(to: localURL)

        let loaded = try await storage.load(contactID: "u2")
        #expect(loaded.count == 1)
        if case let .image(local, remote) = loaded[0].kind {
            #expect(local == nil)
            #expect(remote == remoteURL)
        } else {
            Issue.record("消息类型应为 image")
        }
        #expect(FileManager.default.fileExists(atPath: localURL.path) == false)
    }
}
