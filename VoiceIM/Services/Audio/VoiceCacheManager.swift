import Foundation

/// 远程语音文件下载缓存（本地录音文件仍由 `FileStorageManager` 保存在 Documents）
actor VoiceCacheManager: FileCacheService {

    static let shared = VoiceCacheManager()

    private let voiceDirectory: URL

    private init() {
        // 与 `FileStorageManager` 中「用户录音」Documents 路径分离；此处仅缓存**可再下载**的远程语音
        if let dir = try? ChatCacheBucket.voiceRemote.ensureDirectory() {
            voiceDirectory = dir
        } else {
            let fallback = FileManager.default.temporaryDirectory
                .appendingPathComponent("VoiceIM/IMVoiceCache", isDirectory: true)
            try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
            print("语音远程缓存目录创建失败，已使用临时目录")
            voiceDirectory = fallback
        }
    }

    /// 实现 `FileCacheService`：落盘目录固定为 `ChatCacheBucket.voiceRemote`，与 `ChatViewModel` 注入的协议一致，便于测试替换。
    func resolve(_ remoteURL: URL) async throws -> URL {
        try await RemoteFileCache.shared.localFile(
            for: remoteURL,
            defaultExtension: "m4a",
            cacheDirectory: voiceDirectory
        )
    }
}
