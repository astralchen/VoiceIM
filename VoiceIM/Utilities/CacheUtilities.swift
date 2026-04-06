import Foundation
import UIKit

// MARK: - Stable Hash

/// 稳定哈希工具：使用 djb2 算法生成跨进程/重启稳定的哈希值
///
/// 与 Swift 的 `hashValue` 不同，djb2 算法生成的哈希值在不同进程和应用重启后保持一致。
/// 适用于需要持久化的文件名生成。
enum StableHash {

    /// 使用 djb2 算法计算字符串的稳定哈希值
    ///
    /// - Parameter string: 输入字符串
    /// - Returns: 64 位无符号整数哈希值
    static func djb2(_ string: String) -> UInt64 {
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = hash &* 127 &+ UInt64(byte)
        }
        return hash
    }

    /// 为 URL 生成稳定的文件名
    ///
    /// - 本地文件 URL：直接返回文件名
    /// - 远程 URL：使用 djb2 哈希生成文件名，保留原始扩展名
    ///
    /// - Parameters:
    ///   - url: 输入 URL
    ///   - defaultExtension: 当 URL 没有扩展名时使用的默认扩展名
    /// - Returns: 稳定的文件名
    static func fileName(for url: URL, defaultExtension: String) -> String {
        if url.isFileURL {
            return url.lastPathComponent
        }
        let hash = djb2(url.absoluteString)
        let ext = url.pathExtension.isEmpty ? defaultExtension : url.pathExtension
        return "\(hash).\(ext)"
    }
}

// MARK: - Cache Directory Manager

/// 缓存目录管理器：统一管理缓存目录的创建和访问
enum CacheDirectoryManager {

    /// 缓存目录创建错误
    enum CacheDirectoryError: LocalizedError {
        case cachesDirectoryNotFound
        case directoryCreationFailed(Error)

        var errorDescription: String? {
            switch self {
            case .cachesDirectoryNotFound:
                return "无法获取系统缓存目录"
            case .directoryCreationFailed(let error):
                return "创建缓存目录失败: \(error.localizedDescription)"
            }
        }
    }

    /// 创建缓存子目录
    ///
    /// - Parameter subdirectory: 子目录名称（如 "ImageCache"）
    /// - Returns: 创建的目录 URL
    /// - Throws: 创建失败时抛出错误
    static func createCacheDirectory(named subdirectory: String) throws -> URL {
        guard let cacheDir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw CacheDirectoryError.cachesDirectoryNotFound
        }

        let url = cacheDir.appendingPathComponent(subdirectory, isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: nil
            )
            return url
        } catch {
            throw CacheDirectoryError.directoryCreationFailed(error)
        }
    }
}

// MARK: - Task Deduplicator

/// 并发任务去重器：防止相同的异步任务重复执行
///
/// 使用场景：
/// - 图片下载去重
/// - 视频缓存去重
/// - 缩略图生成去重
///
/// 示例：
/// ```swift
/// let deduplicator = TaskDeduplicator<URL, UIImage>()
/// let image = try await deduplicator.deduplicate(key: imageURL) {
///     try await downloadImage(from: imageURL)
/// }
/// ```
actor TaskDeduplicator<Key: Hashable, Value> {

    /// 正在进行中的任务字典
    private var inFlight: [Key: Task<Value, Error>] = [:]

    /// 执行去重的异步操作
    ///
    /// - 如果相同 key 的任务正在执行，等待其完成并返回结果
    /// - 如果没有进行中的任务，创建新任务并执行
    ///
    /// - Parameters:
    ///   - key: 任务的唯一标识
    ///   - operation: 要执行的异步操作
    /// - Returns: 操作结果
    /// - Throws: 操作失败时抛出错误
    func deduplicate(
        key: Key,
        operation: @escaping () async throws -> Value
    ) async throws -> Value {
        // 检查是否已有进行中的任务
        if let existingTask = inFlight[key] {
            return try await existingTask.value
        }

        // 创建新任务
        let task = Task<Value, Error> {
            try await operation()
        }
        inFlight[key] = task

        // 执行任务并清理
        do {
            let result = try await task.value
            inFlight.removeValue(forKey: key)
            return result
        } catch {
            inFlight.removeValue(forKey: key)
            throw error
        }
    }

    /// 取消指定 key 的任务
    ///
    /// - Parameter key: 任务的唯一标识
    func cancel(key: Key) {
        inFlight[key]?.cancel()
        inFlight.removeValue(forKey: key)
    }

    /// 取消所有进行中的任务
    func cancelAll() {
        for task in inFlight.values {
            task.cancel()
        }
        inFlight.removeAll()
    }
}

// MARK: - Memory Cache Wrapper

/// 内存缓存包装器：封装 NSCache 并自动处理内存警告
///
/// 特性：
/// - 自动响应内存警告并清理缓存
/// - 支持自定义缓存限制
/// - 线程安全（NSCache 本身线程安全）
///
/// 示例：
/// ```swift
/// let cache = MemoryCacheWrapper<URL, UIImage>(
///     countLimit: 50,
///     costLimit: 50 * 1024 * 1024  // 50 MB
/// )
/// cache.set(image, for: url, cost: imageSize)
/// let cachedImage = cache.get(url)
/// ```
@MainActor
final class MemoryCacheWrapper<Key: Hashable, Value: AnyObject> {

    private let cache = NSCache<NSString, Value>()
    private var memoryWarningObserver: NSObjectProtocol?

    /// 初始化内存缓存
    ///
    /// - Parameters:
    ///   - countLimit: 最大缓存对象数量（0 表示无限制）
    ///   - costLimit: 最大缓存成本（字节数，0 表示无限制）
    init(countLimit: Int = 0, costLimit: Int = 0) {
        cache.countLimit = countLimit
        cache.totalCostLimit = costLimit

        // 监听内存警告
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.cache.removeAllObjects()
        }
    }

    deinit {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// 获取缓存的值
    ///
    /// - Parameter key: 缓存键
    /// - Returns: 缓存的值，不存在时返回 nil
    func get(_ key: Key) -> Value? {
        cache.object(forKey: String(describing: key) as NSString)
    }

    /// 设置缓存值
    ///
    /// - Parameters:
    ///   - value: 要缓存的值
    ///   - key: 缓存键
    ///   - cost: 缓存成本（通常是对象的字节大小）
    func set(_ value: Value, for key: Key, cost: Int = 0) {
        cache.setObject(value, forKey: String(describing: key) as NSString, cost: cost)
    }

    /// 移除指定键的缓存
    ///
    /// - Parameter key: 缓存键
    func remove(_ key: Key) {
        cache.removeObject(forKey: String(describing: key) as NSString)
    }

    /// 清空所有缓存
    func clear() {
        cache.removeAllObjects()
    }
}
