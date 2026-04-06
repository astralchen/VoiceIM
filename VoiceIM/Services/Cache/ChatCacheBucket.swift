import Foundation

/// 聊天相关磁盘缓存桶：统一挂在系统 Caches 下的 `VoiceIM/` 子目录中，便于治理与清理。
enum ChatCacheBucket: String, CaseIterable, Sendable {

    case image = "ImageCache"
    case video = "VideoCache"
    case videoThumbnail = "VideoThumbnailCache"
    /// 远程语音文件缓存（本地录音仍在 Documents，不由本枚举管理）
    case voiceRemote = "IMVoiceCache"

    /// 固定命名空间，避免与系统或其他 App 在 Caches 根目录平铺时混淆；`ChatCacheJanitor` 也依赖此层级做批量清理。
    private static let rootSegment = "VoiceIM"

    /// 相对 Caches 的子路径，例如 `VoiceIM/ImageCache`
    var subdirectoryPath: String {
        "\(Self.rootSegment)/\(rawValue)"
    }

    /// 创建并返回目录 URL（已存在则直接返回）
    func ensureDirectory() throws -> URL {
        try CacheDirectoryManager.createCacheDirectory(named: subdirectoryPath)
    }
}

/// 聊天侧 **Caches 目录内** 磁盘缓存的统一维护入口。
///
/// # 何时调用
/// - **设置 → 清理缓存**：在用户确认后调用 `clearAllChatDiskCaches()`，释放图片/视频/缩略图/远程语音等可再下载资源占用的空间。
/// - **展示占用体积**：在设置或调试面板调用 `totalChatDiskCacheBytes()`，可再格式化为 MB 展示（注意为异步，需在界面层 `await`）。
///
/// # 不会动到的范围（勿与本类型混淆）
/// - **Documents** 下由 `FileStorageManager` 管理的用户录音、消息 JSON 等：**不在** `ChatCacheBucket` 中，清理聊天缓存时若需一并处理，须单独调用 `FileStorageManager` 或业务提供的清理 API。
/// - 清理后：列表中仍引用旧本地路径的消息可能出现「文件不存在」，需产品策略（例如提示重新加载会话或依赖远程 URL 回退）；未上线项目可接受直接清空缓存。
///
/// # 调用注意
/// - 方法均为 `async`，宜在 `Task { await ... }` 或 `async` 上下文中调用，避免阻塞主线程。
/// - 与 `ImageCacheManager.clearMemoryCache` 等**内存**清理无关；若需释放内存中的 `UIImage`，仍由各 `*CacheManager` 自行处理。
enum ChatCacheJanitor: Sendable {

    /// 清空 `ChatCacheBucket` 所列全部目录中的文件（仅磁盘、仅上述子目录）。
    static func clearAllChatDiskCaches() async {
        for bucket in ChatCacheBucket.allCases {
            guard let url = try? bucket.ensureDirectory() else { continue }
            _ = await DiskCacheUtilities.clearDirectory(url)
        }
    }

    /// 统计 `ChatCacheBucket` 各目录占用字节数之和（用于设置页「缓存大小」展示）。
    static func totalChatDiskCacheBytes() async -> Int {
        var total = 0
        for bucket in ChatCacheBucket.allCases {
            guard let url = try? bucket.ensureDirectory() else { continue }
            total += await DiskCacheUtilities.directorySize(url)
        }
        return total
    }
}
