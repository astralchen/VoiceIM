import Foundation

/// 语音文件下载缓存管理器（Actor 保证线程安全）
actor VoiceCacheManager: FileCacheService {

    static let shared = VoiceCacheManager()

    private let cacheDir: URL
    /// 正在进行中的下载任务（避免重复下载）
    private var inFlight: [URL: Task<URL, Error>] = [:]

    private init() {
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDir = base.appendingPathComponent("IMVoiceCache", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - 公共接口

    /// 解析语音 URL：本地缓存已存在直接返回，否则下载后缓存
    func resolve(_ remoteURL: URL) async throws -> URL {
        let dest = cacheURL(for: remoteURL)

        // 已缓存，直接返回
        if FileManager.default.fileExists(atPath: dest.path) {
            return dest
        }

        // 已有下载任务，等待完成
        if let existing = inFlight[remoteURL] {
            return try await existing.value
        }

        // 启动新下载任务
        let destination = dest
        let task = Task<URL, Error> {
            try await Self.download(from: remoteURL, to: destination)
        }
        inFlight[remoteURL] = task

        do {
            let result = try await task.value
            inFlight.removeValue(forKey: remoteURL)
            return result
        } catch {
            inFlight.removeValue(forKey: remoteURL)
            throw error
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
        // 用 URL 字符串的哈希值作为文件名，保留原始扩展名
        let hash = abs(remote.absoluteString.hashValue)
        let ext = remote.pathExtension.isEmpty ? "m4a" : remote.pathExtension
        return cacheDir.appendingPathComponent("\(hash).\(ext)")
    }
}
