import Foundation

/// 文件存储管理器：统一管理录音、图片、视频文件的存储
///
/// # 职责
/// - 提供统一的文件存储路径
/// - 管理文件的创建、读取、删除
/// - 清理孤立文件（未被消息引用的文件）
/// - 统计缓存大小
///
/// # 目录结构
/// ```
/// Documents/
/// ├── Voice/      # 录音文件
/// ├── Images/     # 图片文件
/// └── Videos/     # 视频文件
/// ```
final class FileStorageManager {

    // MARK: - Singleton

    nonisolated(unsafe) static let shared = FileStorageManager()

    // MARK: - Properties

    private let fileManager = FileManager.default
    private let baseDirectory: URL

    // MARK: - Directories

    private(set) lazy var voiceDirectory: URL = {
        let url = baseDirectory.appendingPathComponent("Voice", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private(set) lazy var imageDirectory: URL = {
        let url = baseDirectory.appendingPathComponent("Images", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private(set) lazy var videoDirectory: URL = {
        let url = baseDirectory.appendingPathComponent("Videos", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    // MARK: - Init

    private init() {
        // 使用 Documents 目录作为基础目录
        self.baseDirectory = fileManager
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceIM", isDirectory: true)

        // 创建基础目录
        try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    // MARK: - File Operations

    /// 保存录音文件
    ///
    /// - Parameter tempURL: 临时文件 URL
    /// - Returns: 永久存储的文件 URL
    /// - Throws: 文件操作错误
    func saveVoiceFile(from tempURL: URL) throws -> URL {
        let fileName = UUID().uuidString + ".m4a"
        let destURL = voiceDirectory.appendingPathComponent(fileName)

        try fileManager.copyItem(at: tempURL, to: destURL)
        return destURL
    }

    /// 保存图片文件
    ///
    /// - Parameter tempURL: 临时文件 URL
    /// - Returns: 永久存储的文件 URL
    /// - Throws: 文件操作错误
    func saveImageFile(from tempURL: URL) throws -> URL {
        let fileName = UUID().uuidString + "." + tempURL.pathExtension
        let destURL = imageDirectory.appendingPathComponent(fileName)

        try fileManager.copyItem(at: tempURL, to: destURL)
        return destURL
    }

    /// 保存视频文件
    ///
    /// - Parameter tempURL: 临时文件 URL
    /// - Returns: 永久存储的文件 URL
    /// - Throws: 文件操作错误
    func saveVideoFile(from tempURL: URL) throws -> URL {
        let fileName = UUID().uuidString + "." + tempURL.pathExtension
        let destURL = videoDirectory.appendingPathComponent(fileName)

        try fileManager.copyItem(at: tempURL, to: destURL)
        return destURL
    }

    /// 删除文件
    ///
    /// - Parameter url: 文件 URL
    /// - Throws: 文件操作错误
    func deleteFile(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    /// 文件是否存在
    ///
    /// - Parameter url: 文件 URL
    /// - Returns: 是否存在
    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    // MARK: - Cache Management

    /// 获取缓存大小（字节）
    ///
    /// - Returns: 缓存大小
    func getCacheSize() -> UInt64 {
        var totalSize: UInt64 = 0

        let directories = [voiceDirectory, imageDirectory, videoDirectory]
        for directory in directories {
            totalSize += directorySize(at: directory)
        }

        return totalSize
    }

    /// 获取格式化的缓存大小字符串
    ///
    /// - Returns: 格式化字符串（如 "12.5 MB"）
    func getFormattedCacheSize() -> String {
        let size = getCacheSize()
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    /// 清理所有缓存
    ///
    /// - Throws: 文件操作错误
    func clearAllCache() throws {
        let directories = [voiceDirectory, imageDirectory, videoDirectory]
        for directory in directories {
            try clearDirectory(at: directory)
        }
    }

    /// 清理孤立文件（未被消息引用的文件）
    ///
    /// - Parameter referencedURLs: 被消息引用的文件 URL 集合
    /// - Returns: 清理的文件数量
    func cleanOrphanedFiles(referencedURLs: Set<URL>) -> Int {
        var cleanedCount = 0

        let directories = [voiceDirectory, imageDirectory, videoDirectory]
        for directory in directories {
            guard let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) else { continue }

            for fileURL in files {
                if !referencedURLs.contains(fileURL) {
                    try? fileManager.removeItem(at: fileURL)
                    cleanedCount += 1
                }
            }
        }

        return cleanedCount
    }

    // MARK: - Private Methods

    /// 计算目录大小
    private func directorySize(at url: URL) -> UInt64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }

        var totalSize: UInt64 = 0
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                  let fileSize = resourceValues.fileSize else { continue }
            totalSize += UInt64(fileSize)
        }

        return totalSize
    }

    /// 清空目录
    private func clearDirectory(at url: URL) throws {
        guard let files = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        ) else { return }

        for fileURL in files {
            try fileManager.removeItem(at: fileURL)
        }
    }
}
