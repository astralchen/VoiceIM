import AVFoundation
import UIKit

/// 视频缓存管理器：统一管理视频文件和缩略图的缓存
///
/// # 功能特性
/// - 视频文件缓存：缓存远程视频到本地
/// - 缩略图缓存：两级缓存（内存 + 磁盘）
/// - 异步生成：后台线程生成缩略图
/// - 自动清理：内存警告时清理缓存
/// - 线程安全：使用 actor 保证并发安全
///
/// # 使用方式
/// ```swift
/// let manager = VideoCacheManager.shared
/// let thumbnail = await manager.loadThumbnail(from: videoURL)
/// ```
actor VideoCacheManager {

    static let shared = VideoCacheManager()

    // MARK: - Properties

    /// 缩略图内存缓存（nonisolated(unsafe)：NSCache 本身线程安全，允许 nonisolated 同步访问）
    private nonisolated(unsafe) let thumbnailCache = NSCache<NSString, UIImage>()

    /// 视频文件缓存目录
    private let videoCacheURL: URL

    /// 缩略图缓存目录
    private let thumbnailCacheURL: URL

    /// 正在进行的缩略图生成任务
    private var thumbnailTasks: [URL: Task<UIImage?, Error>] = [:]

    /// 正在进行的视频下载任务
    private var downloadTasks: [URL: Task<URL, Error>] = [:]

    // MARK: - Init

    private init() {
        // 配置缩略图内存缓存
        thumbnailCache.countLimit = 100  // 最多缓存 100 张缩略图
        thumbnailCache.totalCostLimit = 20 * 1024 * 1024  // 最多 20MB

        // 配置缓存目录
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        videoCacheURL = cacheDir.appendingPathComponent("VideoCache", isDirectory: true)
        thumbnailCacheURL = cacheDir.appendingPathComponent("VideoThumbnailCache", isDirectory: true)

        // 创建缓存目录
        try? FileManager.default.createDirectory(at: videoCacheURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: thumbnailCacheURL, withIntermediateDirectories: true)

        // 监听内存警告
        Task { @MainActor in
            let _ = NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task {
                    await self?.clearMemoryCache()
                }
            }
        }
    }

    // MARK: - Save & Cache

    /// 将临时视频文件持久化到视频缓存目录，并预生成缩略图（用于发送视频消息）
    ///
    /// 流程与 `ImageCacheManager.saveAndCacheImage` 对称：
    /// - 复制文件到 `videoCacheURL/`（后台线程，避免阻塞 actor）
    /// - 预生成缩略图并写入内存 + 磁盘缓存
    ///
    /// - Parameter tempURL: 临时视频文件 URL
    /// - Returns: 视频缓存目录中的永久路径（存储到 ChatMessage.kind 里）
    func saveAndCacheVideo(from tempURL: URL) async throws -> URL {
        let fileName = stableDiskFileName(for: tempURL)
        let permanentURL = videoCacheURL.appendingPathComponent(fileName)

        // 视频文件可能较大，在后台线程执行拷贝
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.copyItem(at: tempURL, to: permanentURL)
        }.value

        VoiceIM.logger.info("💾 Saved video: \(fileName)")

        // 预生成并缓存缩略图（确保列表首屏无闪烁）
        _ = await loadThumbnail(from: permanentURL)

        return permanentURL
    }

    // MARK: - URL Resolution

    /// 解析视频 URL，优先级：本地文件 → 视频缓存目录（路径失效时） → 远程 URL
    ///
    /// Codable decode 用文件名 + `videoDirectory` 重建路径，但视频实际存在 `videoCacheURL`。
    /// 此处检测路径失效后，按文件名在 `videoCacheURL` 中查找。
    nonisolated func resolveVideoURL(local localURL: URL?, remote remoteURL: URL?) -> URL? {
        if let localURL {
            if FileManager.default.fileExists(atPath: localURL.path) {
                return localURL
            }
            // 路径失效，按 stableDiskFileName 在视频缓存目录中查找
            let cached = videoCacheURL.appendingPathComponent(stableDiskFileName(for: localURL))
            if FileManager.default.fileExists(atPath: cached.path) {
                return cached
            }
        }
        return remoteURL
    }

    // MARK: - Sync Cache Check

    /// 同步查询缩略图缓存（内存 → 磁盘），命中时直接返回，避免异步加载闪烁
    nonisolated func cachedThumbnail(for videoURL: URL) -> UIImage? {
        let key = memoryCacheKey(for: videoURL)

        // 1. 内存缓存
        if let image = thumbnailCache.object(forKey: key as NSString) {
            return image
        }

        // 2. 磁盘缓存（缩略图为小尺寸 JPEG，同步 I/O 可接受）
        let diskPath = thumbnailCacheURL.appendingPathComponent(thumbnailCacheKey(for: videoURL)).path
        guard FileManager.default.fileExists(atPath: diskPath),
              let image = UIImage(contentsOfFile: diskPath) else {
            return nil
        }

        // 回写内存缓存
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        thumbnailCache.setObject(image, forKey: key as NSString, cost: cost)
        return image
    }

    // MARK: - Public API

    /// 加载视频缩略图（带缓存）
    ///
    /// - Parameters:
    ///   - videoURL: 视频 URL（本地或远程）
    ///   - time: 截取时间点（默认 1 秒）
    /// - Returns: 缩略图，失败返回 nil
    func loadThumbnail(from videoURL: URL, at time: CMTime = CMTime(seconds: 1, preferredTimescale: 600)) async -> UIImage? {
        // 1. 检查内存缓存
        if let cachedThumbnail = thumbnailCache.object(forKey: memoryCacheKey(for: videoURL) as NSString) {
            return cachedThumbnail
        }

        // 2. 检查是否已有生成任务
        if let existingTask = thumbnailTasks[videoURL] {
            return try? await existingTask.value
        }

        // 3. 创建新的生成任务
        let task = Task<UIImage?, Error> {
            // 检查磁盘缓存
            if let diskThumbnail = await loadThumbnailFromDisk(videoURL: videoURL) {
                cacheInMemory(thumbnail: diskThumbnail, for: videoURL)
                return diskThumbnail
            }

            // 生成缩略图
            let thumbnail = await generateThumbnail(from: videoURL, at: time)

            if let thumbnail = thumbnail {
                cacheInMemory(thumbnail: thumbnail, for: videoURL)
                await saveThumbnailToDisk(thumbnail: thumbnail, for: videoURL)
            }

            return thumbnail
        }

        thumbnailTasks[videoURL] = task

        defer {
            thumbnailTasks.removeValue(forKey: videoURL)
        }

        return try? await task.value
    }

    /// 缓存远程视频到本地
    ///
    /// - Parameter remoteURL: 远程视频 URL
    /// - Returns: 本地缓存的 URL
    func cacheVideo(from remoteURL: URL) async throws -> URL {
        // 检查是否已缓存
        let cacheKey = stableDiskFileName(for: remoteURL)
        let cacheURL = videoCacheURL.appendingPathComponent(cacheKey)

        if FileManager.default.fileExists(atPath: cacheURL.path) {
            return cacheURL
        }

        // 检查是否已有下载任务
        if let existingTask = downloadTasks[remoteURL] {
            return try await existingTask.value
        }

        // 创建新的下载任务
        let task = Task<URL, Error> {
            let (tempURL, _) = try await URLSession.shared.download(from: remoteURL)

            // 移动到缓存目录
            if FileManager.default.fileExists(atPath: cacheURL.path) {
                try? FileManager.default.removeItem(at: cacheURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: cacheURL)

            return cacheURL
        }

        downloadTasks[remoteURL] = task

        defer {
            downloadTasks.removeValue(forKey: remoteURL)
        }

        return try await task.value
    }

    /// 清理内存缓存
    func clearMemoryCache() {
        thumbnailCache.removeAllObjects()
        VoiceIM.logger.info("Cleared video thumbnail memory cache")
    }

    /// 清理磁盘缓存
    func clearDiskCache() async {
        do {
            // 清理视频缓存
            let videoFiles = try FileManager.default.contentsOfDirectory(at: videoCacheURL, includingPropertiesForKeys: nil)
            for file in videoFiles {
                try? FileManager.default.removeItem(at: file)
            }

            // 清理缩略图缓存
            let thumbnailFiles = try FileManager.default.contentsOfDirectory(at: thumbnailCacheURL, includingPropertiesForKeys: nil)
            for file in thumbnailFiles {
                try? FileManager.default.removeItem(at: file)
            }

            VoiceIM.logger.info("Cleared video disk cache (\(videoFiles.count) videos, \(thumbnailFiles.count) thumbnails)")
        } catch {
            VoiceIM.logger.error("Failed to clear video disk cache: \(error)")
        }
    }

    /// 获取缓存大小
    func getCacheSize() async -> (video: Int, thumbnail: Int) {
        let videoSize = await getDiskCacheSize(directory: videoCacheURL)
        let thumbnailSize = await getDiskCacheSize(directory: thumbnailCacheURL)
        return (video: videoSize, thumbnail: thumbnailSize)
    }

    // MARK: - Private Methods

    /// 从磁盘加载缩略图
    private func loadThumbnailFromDisk(videoURL: URL) async -> UIImage? {
        let cacheKey = thumbnailCacheKey(for: videoURL)
        let cacheURL = thumbnailCacheURL.appendingPathComponent(cacheKey)

        guard FileManager.default.fileExists(atPath: cacheURL.path) else {
            return nil
        }

        return await Task.detached {
            guard let data = try? Data(contentsOf: cacheURL),
                  let image = UIImage(data: data) else {
                return nil
            }
            return image
        }.value
    }

    /// 生成视频缩略图
    private func generateThumbnail(from videoURL: URL, at time: CMTime) async -> UIImage? {
        return await Task.detached {
            let asset = AVAsset(url: videoURL)
            let imageGenerator = AVAssetImageGenerator(asset: asset)
            imageGenerator.appliesPreferredTrackTransform = true
            imageGenerator.maximumSize = CGSize(width: 400, height: 400)  // 限制缩略图大小

            do {
                let cgImage = try imageGenerator.copyCGImage(at: time, actualTime: nil)
                return UIImage(cgImage: cgImage)
            } catch {
                VoiceIM.logger.error("Failed to generate video thumbnail: \(error)")
                return nil
            }
        }.value
    }

    /// 缓存到内存
    private func cacheInMemory(thumbnail: UIImage, for videoURL: URL) {
        let cost = Int(thumbnail.size.width * thumbnail.size.height * thumbnail.scale * thumbnail.scale * 4)
        thumbnailCache.setObject(thumbnail, forKey: memoryCacheKey(for: videoURL) as NSString, cost: cost)
    }

    /// 内存缓存键：本地文件用规范路径，远程用完整 URL 字符串（与 ImageCacheManager.memoryCacheKey 逻辑一致）
    ///
    /// `url.standardized.path` 解析符号链接，确保 `/var/...` 和 `/private/var/...` 映射到同一键。
    private nonisolated func memoryCacheKey(for url: URL) -> String {
        url.isFileURL ? url.standardized.path : url.absoluteString
    }

    /// 保存缩略图到磁盘
    private func saveThumbnailToDisk(thumbnail: UIImage, for videoURL: URL) async {
        let cacheKey = thumbnailCacheKey(for: videoURL)
        let cacheURL = thumbnailCacheURL.appendingPathComponent(cacheKey)

        await Task.detached {
            guard let data = thumbnail.jpegData(compressionQuality: 0.8) else { return }
            try? data.write(to: cacheURL)
        }.value
    }

    /// 视频磁盘缓存文件名（本地和远程 URL 通用）
    ///
    /// - 本地文件：直接取 `lastPathComponent`（UUID 命名，天然唯一且稳定）
    /// - 远程 URL：用 djb2 哈希生成文件名（跨进程/重启稳定，不依赖 Swift.hashValue）
    nonisolated func stableDiskFileName(for url: URL) -> String {
        if url.isFileURL {
            return url.lastPathComponent
        }
        let string = url.absoluteString
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = hash &* 127 &+ UInt64(byte)
        }
        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        return "\(hash).\(ext)"
    }

    /// 缩略图磁盘缓存文件名（复用 stableDiskFileName，替换扩展名为 .jpg）
    ///
    /// - 本地 `abc123.mp4` → `abc123.jpg`
    /// - 远程 `12345678.mp4` → `12345678.jpg`
    private nonisolated func thumbnailCacheKey(for url: URL) -> String {
        let base = (stableDiskFileName(for: url) as NSString).deletingPathExtension
        return base + ".jpg"
    }

    /// 获取磁盘缓存大小
    private func getDiskCacheSize(directory: URL) async -> Int {
        return await Task.detached {
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else {
                return 0
            }

            var totalSize = 0
            for file in files {
                if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    totalSize += size
                }
            }
            return totalSize
        }.value
    }
}
