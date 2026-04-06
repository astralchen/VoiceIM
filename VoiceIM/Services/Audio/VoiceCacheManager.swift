import Foundation

/// 语音文件下载缓存管理器（Actor 保证线程安全）
actor VoiceCacheManager: FileCacheService {

    static let shared = VoiceCacheManager()

    private let cacheDir: URL

    /// 任务去重器（避免重复下载）
    private let deduplicator = TaskDeduplicator<URL, URL>()

    private init() {
        do {
            cacheDir = try CacheDirectoryManager.createCacheDirectory(named: "IMVoiceCache")
        } catch {
            // 降级处理：使用临时目录
            cacheDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("IMVoiceCache", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: cacheDir,
                withIntermediateDirectories: true
            )
            print("Failed to create voice cache directory, using temp: \(error)")
        }
    }

    // MARK: - 公共接口

    /// 解析语音 URL：本地缓存已存在直接返回，否则下载后缓存
    func resolve(_ remoteURL: URL) async throws -> URL {
        let dest = cacheURL(for: remoteURL)

        // 已缓存，直接返回
        if FileManager.default.fileExists(atPath: dest.path) {
            return dest
        }

        // 使用去重器执行下载
        return try await deduplicator.deduplicate(key: remoteURL) {
            try await Self.download(from: remoteURL, to: dest)
        }
    }

    // MARK: - 私有

    private static func download(from remote: URL, to dest: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: remote) { tmpURL, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let tmpURL = tmpURL else {
                    continuation.resume(throwing: URLError(.unknown))
                    return
                }
                do {
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try FileManager.default.moveItem(at: tmpURL, to: dest)
                    continuation.resume(returning: dest)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            task.resume()
        }
    }

    private func cacheURL(for remote: URL) -> URL {
        // 使用稳定哈希生成文件名
        let fileName = StableHash.fileName(for: remote, defaultExtension: "m4a")
        return cacheDir.appendingPathComponent(fileName)
    }
}
