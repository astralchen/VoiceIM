import Testing
import Foundation
@testable import VoiceIM

/// CacheUtilities 工具类测试
@Suite("CacheUtilities Tests")
struct CacheUtilitiesTests {

    // MARK: - StableHash Tests

    @Test("StableHash.djb2 生成稳定哈希")
    func testDjb2StableHash() {
        let input = "https://example.com/image.jpg"

        // 多次调用应返回相同结果
        let hash1 = StableHash.djb2(input)
        let hash2 = StableHash.djb2(input)

        #expect(hash1 == hash2)
        #expect(hash1 > 0)
    }

    @Test("StableHash.djb2 不同输入生成不同哈希")
    func testDjb2DifferentInputs() {
        let hash1 = StableHash.djb2("https://example.com/image1.jpg")
        let hash2 = StableHash.djb2("https://example.com/image2.jpg")

        #expect(hash1 != hash2)
    }

    @Test("StableHash.fileName 处理本地文件 URL")
    func testFileNameForLocalURL() {
        let localURL = URL(fileURLWithPath: "/path/to/image.jpg")
        let fileName = StableHash.fileName(for: localURL, defaultExtension: "jpg")

        #expect(fileName == "image.jpg")
    }

    @Test("StableHash.fileName 处理远程 URL")
    func testFileNameForRemoteURL() {
        let remoteURL = URL(string: "https://example.com/image.jpg")!
        let fileName = StableHash.fileName(for: remoteURL, defaultExtension: "jpg")

        // 应该是哈希值 + 扩展名
        #expect(fileName.hasSuffix(".jpg"))
        #expect(fileName.count > 4) // 哈希值 + ".jpg"
    }

    @Test("StableHash.fileName 使用默认扩展名")
    func testFileNameWithDefaultExtension() {
        let remoteURL = URL(string: "https://example.com/image")!
        let fileName = StableHash.fileName(for: remoteURL, defaultExtension: "png")

        #expect(fileName.hasSuffix(".png"))
    }

    // MARK: - CacheDirectoryManager Tests

    @Test("CacheDirectoryManager 创建缓存目录")
    func testCreateCacheDirectory() throws {
        let subdirectory = "TestCache_\(UUID().uuidString)"

        let url = try CacheDirectoryManager.createCacheDirectory(named: subdirectory)

        // 验证目录存在
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

        #expect(exists)
        #expect(isDirectory.boolValue)

        // 清理
        try? FileManager.default.removeItem(at: url)
    }

    @Test("CacheDirectoryManager 创建嵌套目录")
    func testCreateNestedCacheDirectory() throws {
        let subdirectory = "TestCache/Nested/Deep_\(UUID().uuidString)"

        let url = try CacheDirectoryManager.createCacheDirectory(named: subdirectory)

        // 验证目录存在
        let exists = FileManager.default.fileExists(atPath: url.path)
        #expect(exists)

        // 清理
        let parentURL = url.deletingLastPathComponent().deletingLastPathComponent()
        try? FileManager.default.removeItem(at: parentURL)
    }

    // MARK: - TaskDeduplicator Tests

    @Test("TaskDeduplicator 去重相同任务")
    func testTaskDeduplication() async throws {
        let deduplicator = TaskDeduplicator<String, Int>()
        var executionCount = 0

        // 启动多个相同 key 的任务
        async let result1 = deduplicator.deduplicate(key: "test") {
            executionCount += 1
            try await Task.sleep(for: .milliseconds(100))
            return 42
        }

        async let result2 = deduplicator.deduplicate(key: "test") {
            executionCount += 1
            try await Task.sleep(for: .milliseconds(100))
            return 99
        }

        let (r1, r2) = try await (result1, result2)

        // 应该只执行一次，两个结果相同
        #expect(executionCount == 1)
        #expect(r1 == 42)
        #expect(r2 == 42)
    }

    @Test("TaskDeduplicator 不同 key 独立执行")
    func testTaskDeduplicationDifferentKeys() async throws {
        let deduplicator = TaskDeduplicator<String, Int>()
        var executionCount = 0

        async let result1 = deduplicator.deduplicate(key: "key1") {
            executionCount += 1
            return 1
        }

        async let result2 = deduplicator.deduplicate(key: "key2") {
            executionCount += 1
            return 2
        }

        let (r1, r2) = try await (result1, result2)

        // 应该执行两次
        #expect(executionCount == 2)
        #expect(r1 == 1)
        #expect(r2 == 2)
    }

    @Test("TaskDeduplicator 处理错误")
    func testTaskDeduplicationError() async {
        let deduplicator = TaskDeduplicator<String, Int>()

        do {
            _ = try await deduplicator.deduplicate(key: "error") {
                throw NSError(domain: "test", code: 1)
            }
            Issue.record("应该抛出错误")
        } catch {
            // 预期的错误
            #expect(error is NSError)
        }
    }

    @Test("TaskDeduplicator 取消任务")
    func testTaskDeduplicationCancel() async throws {
        let deduplicator = TaskDeduplicator<String, Int>()

        // 启动一个长时间任务
        let task = Task {
            try await deduplicator.deduplicate(key: "cancel") {
                try await Task.sleep(for: .seconds(10))
                return 42
            }
        }

        // 立即取消
        await deduplicator.cancel(key: "cancel")
        task.cancel()

        // 验证任务被取消
        let result = await task.result
        #expect(result == .failure(CancellationError()))
    }

    // MARK: - MemoryCacheWrapper Tests

    @MainActor
    @Test("MemoryCacheWrapper 基本操作")
    func testMemoryCacheWrapperBasicOperations() {
        let cache = MemoryCacheWrapper<String, NSString>(countLimit: 10, costLimit: 1000)

        // 设置值
        cache.set("value1" as NSString, for: "key1")

        // 获取值
        let value = cache.get("key1")
        #expect(value == "value1")

        // 移除值
        cache.remove("key1")
        let removedValue = cache.get("key1")
        #expect(removedValue == nil)
    }

    @MainActor
    @Test("MemoryCacheWrapper 清空缓存")
    func testMemoryCacheWrapperClear() {
        let cache = MemoryCacheWrapper<String, NSString>(countLimit: 10, costLimit: 1000)

        cache.set("value1" as NSString, for: "key1")
        cache.set("value2" as NSString, for: "key2")

        cache.clear()

        #expect(cache.get("key1") == nil)
        #expect(cache.get("key2") == nil)
    }

    @MainActor
    @Test("MemoryCacheWrapper 成本限制")
    func testMemoryCacheWrapperCostLimit() {
        let cache = MemoryCacheWrapper<String, NSString>(countLimit: 100, costLimit: 100)

        // 添加超过成本限制的项
        for i in 0..<20 {
            cache.set("value\(i)" as NSString, for: "key\(i)", cost: 10)
        }

        // NSCache 会自动清理，但我们无法精确预测哪些被清理
        // 只验证缓存仍然可用
        cache.set("test" as NSString, for: "test")
        #expect(cache.get("test") == "test")
    }

    // MARK: - ChatCacheBucket

    @Test("ChatCacheBucket 子路径统一带 VoiceIM 前缀")
    func testChatCacheBucketSubdirectoryPath() {
        #expect(ChatCacheBucket.image.subdirectoryPath == "VoiceIM/ImageCache")
        #expect(ChatCacheBucket.video.subdirectoryPath == "VoiceIM/VideoCache")
        #expect(ChatCacheBucket.voiceRemote.subdirectoryPath == "VoiceIM/IMVoiceCache")
    }

    @Test("ChatCacheBucket.ensureDirectory 可创建目录")
    func testChatCacheBucketEnsureDirectory() throws {
        let url = try ChatCacheBucket.image.ensureDirectory()
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
    }
}
