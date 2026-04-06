import AVFoundation
import UIKit

/// 视频缓存管理器：视频文件、远程下载与缩略图（内存 + 磁盘）
///
/// 远程视频落盘统一走 `RemoteFileCache`；缩略图生成仍在本 actor 内串行协调。
actor VideoCacheManager {

    static let shared = VideoCacheManager()

    // MARK: - Properties

    private nonisolated(unsafe) let thumbnailCache = NSCache<NSString, UIImage>()

    /// 缓存目录根路径（`Sendable`，`nonisolated` 方法可直接读取）
    private let videoCacheURL: URL
    private let thumbnailCacheURL: URL

    private var thumbnailTasks: [URL: Task<UIImage?, Error>] = [:]

    private var memoryWarningObserver: NSObjectProtocol?

    // MARK: - Init

    private init() {
        thumbnailCache.countLimit = 100
        thumbnailCache.totalCostLimit = 20 * 1024 * 1024

        if let videoURL = try? ChatCacheBucket.video.ensureDirectory(),
           let thumbnailURL = try? ChatCacheBucket.videoThumbnail.ensureDirectory() {
            videoCacheURL = videoURL
            thumbnailCacheURL = thumbnailURL
        } else {
            let tempDir = FileManager.default.temporaryDirectory
            videoCacheURL = tempDir.appendingPathComponent("VoiceIM/VideoCache", isDirectory: true)
            thumbnailCacheURL = tempDir.appendingPathComponent("VoiceIM/VideoThumbnailCache", isDirectory: true)
            try? FileManager.default.createDirectory(at: videoCacheURL, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: thumbnailCacheURL, withIntermediateDirectories: true)
            print("视频缓存目录创建失败，已使用临时目录")
        }

        Task {
            await self.setupMemoryWarning()
        }
    }

    private func setupMemoryWarning() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task {
                await self?.clearMemoryCache()
            }
        }
    }

    deinit {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Save & Cache

    func saveAndCacheVideo(from tempURL: URL) async throws -> URL {
        let fileName = StableHash.fileName(for: tempURL, defaultExtension: "mp4")
        let permanentURL = videoCacheURL.appendingPathComponent(fileName)

        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.copyItem(at: tempURL, to: permanentURL)
        }.value

        VoiceIM.logger.info("💾 Saved video: \(fileName)")

        _ = await loadThumbnail(from: permanentURL)

        return permanentURL
    }

    // MARK: - URL Resolution

    nonisolated func resolveVideoURL(local localURL: URL?, remote remoteURL: URL?) -> URL? {
        if let localURL {
            if FileManager.default.fileExists(atPath: localURL.path) {
                return localURL
            }
            let cached = videoCacheURL.appendingPathComponent(StableHash.fileName(for: localURL, defaultExtension: "mp4"))
            if FileManager.default.fileExists(atPath: cached.path) {
                return cached
            }
        }
        return remoteURL
    }

    // MARK: - Sync Cache Check

    nonisolated func cachedThumbnail(for videoURL: URL) -> UIImage? {
        let key = memoryCacheKey(for: videoURL)

        if let image = thumbnailCache.object(forKey: key as NSString) {
            return image
        }

        let diskPath = thumbnailCacheURL.appendingPathComponent(thumbnailCacheKey(for: videoURL)).path
        guard FileManager.default.fileExists(atPath: diskPath),
              let image = UIImage(contentsOfFile: diskPath) else {
            return nil
        }

        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        thumbnailCache.setObject(image, forKey: key as NSString, cost: cost)
        return image
    }

    // MARK: - Public API

    func loadThumbnail(from videoURL: URL, at time: CMTime = CMTime(seconds: 1, preferredTimescale: 600)) async -> UIImage? {
        if let cachedThumbnail = thumbnailCache.object(forKey: memoryCacheKey(for: videoURL) as NSString) {
            return cachedThumbnail
        }

        // 同一视频 URL 并发缩略图请求合并（与 `RemoteFileCache` 的全局下载去重独立，因生成逻辑在本 actor 内）
        if let existingTask = thumbnailTasks[videoURL] {
            return try? await existingTask.value
        }

        let task = Task<UIImage?, Error> {
            if let diskThumbnail = await loadThumbnailFromDisk(videoURL: videoURL) {
                cacheInMemory(thumbnail: diskThumbnail, for: videoURL)
                return diskThumbnail
            }

            let thumbnail = await generateThumbnail(from: videoURL, at: time)

            if let thumbnail {
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

    /// 远程整文件缓存：与缩略图、`saveAndCacheVideo` 共用 `videoCacheURL`，下载逻辑委托 `RemoteFileCache`（含并发去重与 HTTP 校验）。
    func cacheVideo(from remoteURL: URL) async throws -> URL {
        try await RemoteFileCache.shared.localFile(
            for: remoteURL,
            defaultExtension: "mp4",
            cacheDirectory: videoCacheURL
        )
    }

    func clearMemoryCache() {
        thumbnailCache.removeAllObjects()
        VoiceIM.logger.info("Cleared video thumbnail memory cache")
    }

    func clearDiskCache() async {
        let videoCount = await DiskCacheUtilities.clearDirectory(videoCacheURL)
        let thumbnailCount = await DiskCacheUtilities.clearDirectory(thumbnailCacheURL)
        VoiceIM.logger.info("Cleared video disk cache (\(videoCount) videos, \(thumbnailCount) thumbnails)")
    }

    func getCacheSize() async -> (video: Int, thumbnail: Int) {
        let videoSize = await DiskCacheUtilities.directorySize(videoCacheURL)
        let thumbnailSize = await DiskCacheUtilities.directorySize(thumbnailCacheURL)
        return (video: videoSize, thumbnail: thumbnailSize)
    }

    // MARK: - Private Methods

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

    private func generateThumbnail(from videoURL: URL, at time: CMTime) async -> UIImage? {
        await Task.detached {
            let asset = AVAsset(url: videoURL)
            let imageGenerator = AVAssetImageGenerator(asset: asset)
            imageGenerator.appliesPreferredTrackTransform = true
            imageGenerator.maximumSize = CGSize(width: 400, height: 400)

            do {
                let cgImage = try imageGenerator.copyCGImage(at: time, actualTime: nil)
                return UIImage(cgImage: cgImage)
            } catch {
                VoiceIM.logger.error("Failed to generate video thumbnail: \(error)")
                return nil
            }
        }.value
    }

    private func cacheInMemory(thumbnail: UIImage, for videoURL: URL) {
        let cost = Int(thumbnail.size.width * thumbnail.size.height * thumbnail.scale * thumbnail.scale * 4)
        thumbnailCache.setObject(thumbnail, forKey: memoryCacheKey(for: videoURL) as NSString, cost: cost)
    }

    private nonisolated func memoryCacheKey(for url: URL) -> String {
        CacheKeyGenerator.memoryCacheKey(for: url)
    }

    private func saveThumbnailToDisk(thumbnail: UIImage, for videoURL: URL) async {
        let cacheKey = thumbnailCacheKey(for: videoURL)
        let cacheURL = thumbnailCacheURL.appendingPathComponent(cacheKey)

        await Task.detached {
            guard let data = thumbnail.jpegData(compressionQuality: 0.8) else { return }
            try? data.write(to: cacheURL)
        }.value
    }

    nonisolated func stableDiskFileName(for url: URL) -> String {
        StableHash.fileName(for: url, defaultExtension: "mp4")
    }

    private nonisolated func thumbnailCacheKey(for url: URL) -> String {
        let base = (StableHash.fileName(for: url, defaultExtension: "mp4") as NSString).deletingPathExtension
        return base + ".jpg"
    }
}
