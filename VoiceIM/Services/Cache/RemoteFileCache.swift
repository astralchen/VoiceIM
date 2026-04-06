import Foundation

/// 远程文件落盘缓存（语音 m4a、视频 mp4 等共用）。
///
/// **去重维度**：同一「远程 URL + 缓存根目录」只会有一个下载任务；同一 URL 写入不同目录（如语音桶与视频桶）互不合并，键见 `CacheKey`。
actor RemoteFileCache: Sendable {

    static let shared = RemoteFileCache()

    /// 去重键：必须包含目录路径，否则不同业务目录会错误共用一个下载结果。
    private struct CacheKey: Hashable, Sendable {
        let remoteAbsoluteString: String
        let directoryStandardizedPath: String
    }

    private let deduplicator = TaskDeduplicator<CacheKey, URL>()

    private init() {}

    /// 若目标路径已存在文件则直接返回；否则下载并移动到稳定哈希文件名对应的路径。
    ///
    /// - Parameters:
    ///   - remoteURL: 远程资源地址
    ///   - defaultExtension: URL 无扩展名时使用的扩展名
    ///   - cacheDirectory: 缓存根目录（通常为某一 `ChatCacheBucket`）
    /// - Returns: 本地 file URL
    func localFile(
        for remoteURL: URL,
        defaultExtension: String,
        cacheDirectory: URL
    ) async throws -> URL {
        let fileName = StableHash.fileName(for: remoteURL, defaultExtension: defaultExtension)
        let destination = cacheDirectory.appendingPathComponent(fileName)

        // 快速路径：已有落盘文件则不再进 actor 去重
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }

        let key = CacheKey(
            remoteAbsoluteString: remoteURL.absoluteString,
            directoryStandardizedPath: cacheDirectory.standardized.path
        )

        return try await deduplicator.deduplicate(key: key) {
            // 并发下可能已被其他 waiter 写完，再判一次避免重复下载
            if FileManager.default.fileExists(atPath: destination.path) {
                return destination
            }

            let (tempURL, response) = try await URLSession.shared.download(from: remoteURL)
            // 与 `URLSession.data` 不同，download 仍可能得到非 2xx，需显式校验
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                try? FileManager.default.removeItem(at: tempURL)
                throw URLError(.badServerResponse)
            }

            // 下载期间另一协程可能已完成 move，此时直接丢弃临时文件并返回已有目标
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: tempURL)
                return destination
            }

            try FileManager.default.moveItem(at: tempURL, to: destination)
            return destination
        }
    }
}
