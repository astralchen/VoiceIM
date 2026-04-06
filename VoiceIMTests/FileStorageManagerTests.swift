import Testing
import Foundation
@testable import VoiceIM

/// FileStorageManager 单元测试
@Suite("FileStorageManager Tests")
struct FileStorageManagerTests {

    @Test("保存录音文件")
    func testSaveVoiceFile() async throws {
        let manager = FileStorageManager(testMode: true)

        // 创建临时文件
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.m4a")
        try "Hello World".data(using: .utf8)!.write(to: tempURL)

        let savedURL = try await manager.saveVoiceFile(from: tempURL)

        #expect(await manager.fileExists(at: savedURL) == true)

        // 清理
        try await manager.deleteFile(at: savedURL)
        try? FileManager.default.removeItem(at: tempURL)
    }

    @Test("删除文件")
    func testDeleteFile() async throws {
        let manager = FileStorageManager(testMode: true)

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_delete.m4a")
        try "Hello World".data(using: .utf8)!.write(to: tempURL)

        let savedURL = try await manager.saveVoiceFile(from: tempURL)
        try await manager.deleteFile(at: savedURL)

        #expect(await manager.fileExists(at: savedURL) == false)

        try? FileManager.default.removeItem(at: tempURL)
    }

    @Test("计算缓存大小")
    func testCacheSize() async throws {
        let manager = FileStorageManager(testMode: true)
        let data = Data(repeating: 0, count: 1024)  // 1KB

        let tempURL1 = FileManager.default.temporaryDirectory.appendingPathComponent("test_size_1.m4a")
        let tempURL2 = FileManager.default.temporaryDirectory.appendingPathComponent("test_size_2.m4a")
        try data.write(to: tempURL1)
        try data.write(to: tempURL2)

        let savedURL1 = try await manager.saveVoiceFile(from: tempURL1)
        let savedURL2 = try await manager.saveVoiceFile(from: tempURL2)

        let size = await manager.getCacheSize()
        #expect(size >= 2048)  // 至少 2KB

        // 清理
        try await manager.deleteFile(at: savedURL1)
        try await manager.deleteFile(at: savedURL2)
        try? FileManager.default.removeItem(at: tempURL1)
        try? FileManager.default.removeItem(at: tempURL2)
    }

    @Test("清理所有缓存")
    func testClearAllCache() async throws {
        let manager = FileStorageManager(testMode: true)

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_clear.jpg")
        try "Test".data(using: .utf8)!.write(to: tempURL)

        _ = try await manager.saveImageFile(from: tempURL)

        try await manager.clearAllCache()

        let size = await manager.getCacheSize()
        #expect(size == 0)

        try? FileManager.default.removeItem(at: tempURL)
    }

    @Test("清理孤立文件")
    func testCleanupOrphanedFiles() async throws {
        let manager = FileStorageManager(testMode: true)

        let tempURL1 = FileManager.default.temporaryDirectory.appendingPathComponent("test_orphan_1.m4a")
        let tempURL2 = FileManager.default.temporaryDirectory.appendingPathComponent("test_orphan_2.m4a")
        try "Test".data(using: .utf8)!.write(to: tempURL1)
        try "Test".data(using: .utf8)!.write(to: tempURL2)

        let savedURL1 = try await manager.saveVoiceFile(from: tempURL1)
        let savedURL2 = try await manager.saveVoiceFile(from: tempURL2)

        // 只保留 savedURL1
        let validURLs: Set<URL> = [savedURL1]
        let cleanedCount = await manager.cleanOrphanedFiles(referencedURLs: validURLs)

        #expect(cleanedCount == 1)
        #expect(await manager.fileExists(at: savedURL1) == true)
        #expect(await manager.fileExists(at: savedURL2) == false)

        // 清理
        try await manager.deleteFile(at: savedURL1)
        try? FileManager.default.removeItem(at: tempURL1)
        try? FileManager.default.removeItem(at: tempURL2)
    }
}
