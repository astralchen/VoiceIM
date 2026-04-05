import Testing
import Foundation
@testable import VoiceIM

/// FileStorageManager 单元测试
@Suite("FileStorageManager Tests")
struct FileStorageManagerTests {

    @Test("保存录音文件")
    func testSaveVoiceFile() throws {
        let manager = FileStorageManager(testMode: true)

        // 创建临时文件
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.m4a")
        try "Hello World".data(using: .utf8)!.write(to: tempURL)

        let savedURL = try manager.saveVoiceFile(from: tempURL)

        #expect(manager.fileExists(at: savedURL) == true)

        // 清理
        try manager.deleteFile(at: savedURL)
        try? FileManager.default.removeItem(at: tempURL)
    }

    @Test("删除文件")
    func testDeleteFile() throws {
        let manager = FileStorageManager(testMode: true)

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_delete.m4a")
        try "Hello World".data(using: .utf8)!.write(to: tempURL)

        let savedURL = try manager.saveVoiceFile(from: tempURL)
        try manager.deleteFile(at: savedURL)

        #expect(manager.fileExists(at: savedURL) == false)

        try? FileManager.default.removeItem(at: tempURL)
    }

    @Test("计算缓存大小")
    func testCacheSize() throws {
        let manager = FileStorageManager(testMode: true)
        let data = Data(repeating: 0, count: 1024)  // 1KB

        let tempURL1 = FileManager.default.temporaryDirectory.appendingPathComponent("test_size_1.m4a")
        let tempURL2 = FileManager.default.temporaryDirectory.appendingPathComponent("test_size_2.m4a")
        try data.write(to: tempURL1)
        try data.write(to: tempURL2)

        let savedURL1 = try manager.saveVoiceFile(from: tempURL1)
        let savedURL2 = try manager.saveVoiceFile(from: tempURL2)

        let size = manager.getCacheSize()
        #expect(size >= 2048)  // 至少 2KB

        // 清理
        try manager.deleteFile(at: savedURL1)
        try manager.deleteFile(at: savedURL2)
        try? FileManager.default.removeItem(at: tempURL1)
        try? FileManager.default.removeItem(at: tempURL2)
    }

    @Test("清理所有缓存")
    func testClearAllCache() throws {
        let manager = FileStorageManager(testMode: true)

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_clear.jpg")
        try "Test".data(using: .utf8)!.write(to: tempURL)

        _ = try manager.saveImageFile(from: tempURL)

        try manager.clearAllCache()

        let size = manager.getCacheSize()
        #expect(size == 0)

        try? FileManager.default.removeItem(at: tempURL)
    }

    @Test("清理孤立文件")
    func testCleanupOrphanedFiles() throws {
        let manager = FileStorageManager(testMode: true)

        let tempURL1 = FileManager.default.temporaryDirectory.appendingPathComponent("test_orphan_1.m4a")
        let tempURL2 = FileManager.default.temporaryDirectory.appendingPathComponent("test_orphan_2.m4a")
        try "Test".data(using: .utf8)!.write(to: tempURL1)
        try "Test".data(using: .utf8)!.write(to: tempURL2)

        let savedURL1 = try manager.saveVoiceFile(from: tempURL1)
        let savedURL2 = try manager.saveVoiceFile(from: tempURL2)

        // 只保留 savedURL1
        let validURLs: Set<URL> = [savedURL1]
        let cleanedCount = manager.cleanOrphanedFiles(referencedURLs: validURLs)

        #expect(cleanedCount == 1)
        #expect(manager.fileExists(at: savedURL1) == true)
        #expect(manager.fileExists(at: savedURL2) == false)

        // 清理
        try manager.deleteFile(at: savedURL1)
        try? FileManager.default.removeItem(at: tempURL1)
        try? FileManager.default.removeItem(at: tempURL2)
    }
}
