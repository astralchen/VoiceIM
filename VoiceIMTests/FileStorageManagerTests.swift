import Testing
import Foundation
@testable import VoiceIM

/// FileStorageManager 单元测试
@Suite("FileStorageManager Tests")
struct FileStorageManagerTests {

    @Test("保存文件")
    func testSaveFile() async throws {
        let manager = FileStorageManager()
        let data = "Hello World".data(using: .utf8)!

        let url = try await manager.save(data, type: .voice, filename: "test")

        let exists = await manager.fileExists(at: url)
        #expect(exists == true)

        // 清理
        try await manager.delete(url)
    }

    @Test("删除文件")
    func testDeleteFile() async throws {
        let manager = FileStorageManager()
        let data = "Hello World".data(using: .utf8)!

        let url = try await manager.save(data, type: .voice, filename: "test_delete")
        try await manager.delete(url)

        let exists = await manager.fileExists(at: url)
        #expect(exists == false)
    }

    @Test("计算缓存大小")
    func testCacheSize() async throws {
        let manager = FileStorageManager()
        let data = Data(repeating: 0, count: 1024)  // 1KB

        let url1 = try await manager.save(data, type: .voice, filename: "test_size_1")
        let url2 = try await manager.save(data, type: .voice, filename: "test_size_2")

        let size = await manager.cacheSize(for: .voice)
        #expect(size >= 2048)  // 至少 2KB

        // 清理
        try await manager.delete(url1)
        try await manager.delete(url2)
    }

    @Test("清理缓存")
    func testClearCache() async throws {
        let manager = FileStorageManager()
        let data = "Test".data(using: .utf8)!

        _ = try await manager.save(data, type: .image, filename: "test_clear_1")
        _ = try await manager.save(data, type: .image, filename: "test_clear_2")

        try await manager.clearCache(for: .image)

        let size = await manager.cacheSize(for: .image)
        #expect(size == 0)
    }

    @Test("清理孤立文件")
    func testCleanupOrphanedFiles() async throws {
        let manager = FileStorageManager()
        let data = "Test".data(using: .utf8)!

        let url1 = try await manager.save(data, type: .voice, filename: "test_orphan_1")
        let url2 = try await manager.save(data, type: .voice, filename: "test_orphan_2")

        // 只保留 url1
        let validURLs: Set<URL> = [url1]
        let cleanedCount = await manager.cleanupOrphanedFiles(validURLs: validURLs)

        #expect(cleanedCount == 1)

        let exists1 = await manager.fileExists(at: url1)
        let exists2 = await manager.fileExists(at: url2)
        #expect(exists1 == true)
        #expect(exists2 == false)

        // 清理
        try await manager.delete(url1)
    }
}
