import UIKit

/// 图片缓存管理器：统一管理图片的内存缓存和磁盘缓存
///
/// # 功能特性
/// - 两级缓存：内存缓存 (NSCache) + 磁盘缓存
/// - 图片下采样：根据目标尺寸优化内存占用
/// - 异步加载：后台线程解码，避免阻塞主线程
/// - 自动清理：内存警告时清理缓存
/// - 线程安全：使用 actor 保证并发安全
///
/// # 使用方式
/// ```swift
/// let manager = ImageCacheManager.shared
/// let image = await manager.loadImage(from: url, targetSize: CGSize(width: 250, height: 250))
/// ```
actor ImageCacheManager {

    static let shared = ImageCacheManager()

    // MARK: - Properties

    /// 内存缓存
    private let memoryCache = NSCache<NSURL, UIImage>()

    /// 磁盘缓存目录
    private let diskCacheURL: URL

    /// 正在进行的加载任务（防止重复加载）
    private var loadingTasks: [URL: Task<UIImage?, Error>] = [:]

    // MARK: - Init

    private init() {
        // 配置内存缓存
        memoryCache.countLimit = 50  // 最多缓存 50 张图片
        memoryCache.totalCostLimit = 50 * 1024 * 1024  // 最多 50MB

        // 配置磁盘缓存目录
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskCacheURL = cacheDir.appendingPathComponent("ImageCache", isDirectory: true)

        // 创建缓存目录
        try? FileManager.default.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)

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

    // MARK: - Public API

    /// 加载图片（带缓存和下采样）
    ///
    /// - Parameters:
    ///   - url: 图片 URL（本地或远程）
    ///   - targetSize: 目标显示尺寸（用于下采样优化）
    /// - Returns: 加载的图片，失败返回 nil
    func loadImage(from url: URL, targetSize: CGSize? = nil) async -> UIImage? {
        // 1. 检查内存缓存
        if let cachedImage = memoryCache.object(forKey: url as NSURL) {
            return cachedImage
        }

        // 2. 检查是否已有加载任务
        if let existingTask = loadingTasks[url] {
            return try? await existingTask.value
        }

        // 3. 创建新的加载任务
        let task = Task<UIImage?, Error> {
            // 检查磁盘缓存
            if let diskImage = await loadFromDisk(url: url, targetSize: targetSize) {
                cacheInMemory(image: diskImage, for: url)
                return diskImage
            }

            // 从文件系统加载
            let image = await loadFromFile(url: url, targetSize: targetSize)

            if let image = image {
                cacheInMemory(image: image, for: url)
                await saveToDisk(image: image, for: url)
            }

            return image
        }

        loadingTasks[url] = task

        defer {
            loadingTasks.removeValue(forKey: url)
        }

        return try? await task.value
    }

    /// 预加载图片（不返回结果，仅缓存）
    ///
    /// - Parameters:
    ///   - url: 图片 URL
    ///   - targetSize: 目标显示尺寸
    func preloadImage(from url: URL, targetSize: CGSize? = nil) {
        Task {
            _ = await loadImage(from: url, targetSize: targetSize)
        }
    }

    /// 清理内存缓存
    func clearMemoryCache() {
        memoryCache.removeAllObjects()
        VoiceIM.logger.info("Cleared image memory cache")
    }

    /// 清理磁盘缓存
    func clearDiskCache() async {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: diskCacheURL, includingPropertiesForKeys: nil)
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
            VoiceIM.logger.info("Cleared image disk cache (\(files.count) files)")
        } catch {
            VoiceIM.logger.error("Failed to clear disk cache: \(error)")
        }
    }

    /// 获取缓存大小
    func getCacheSize() async -> (memory: Int, disk: Int) {
        let diskSize = await getDiskCacheSize()
        return (memory: 0, disk: diskSize)  // NSCache 无法获取准确大小
    }

    // MARK: - Private Methods

    /// 从磁盘缓存加载图片
    private func loadFromDisk(url: URL, targetSize: CGSize?) async -> UIImage? {
        let cacheKey = diskCacheKey(for: url)
        let cacheURL = diskCacheURL.appendingPathComponent(cacheKey)

        guard FileManager.default.fileExists(atPath: cacheURL.path) else {
            return nil
        }

        return await downsampleImage(at: cacheURL, to: targetSize)
    }

    /// 从文件系统加载图片
    private func loadFromFile(url: URL, targetSize: CGSize?) async -> UIImage? {
        guard url.isFileURL else {
            // 远程 URL 需要先下载（这里暂不实现，可以集成 URLSession）
            return nil
        }

        return await downsampleImage(at: url, to: targetSize)
    }

    /// 图片下采样（优化内存占用）
    ///
    /// 原理：直接解码原图会占用大量内存（如 4000x3000 的图片需要 ~46MB）
    /// 下采样可以在解码时就缩小尺寸，大幅减少内存占用
    private func downsampleImage(at url: URL, to targetSize: CGSize?) async -> UIImage? {
        return await Task.detached {
            guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                return nil
            }

            let options: [CFString: Any]

            if let targetSize = targetSize {
                // 计算下采样比例
                let scale = await MainActor.run { UIScreen.main.scale }
                let maxDimension = max(targetSize.width, targetSize.height) * scale

                options = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                    kCGImageSourceShouldCache: false
                ]
            } else {
                // 不下采样，直接解码
                options = [
                    kCGImageSourceShouldCache: false
                ]
            }

            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
                return nil
            }

            return UIImage(cgImage: cgImage)
        }.value
    }

    /// 缓存到内存
    private func cacheInMemory(image: UIImage, for url: URL) {
        // 计算图片占用的内存大小（用于 NSCache 的 cost）
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        memoryCache.setObject(image, forKey: url as NSURL, cost: cost)
    }

    /// 保存到磁盘
    private func saveToDisk(image: UIImage, for url: URL) async {
        let cacheKey = diskCacheKey(for: url)
        let cacheURL = diskCacheURL.appendingPathComponent(cacheKey)

        await Task.detached {
            guard let data = image.jpegData(compressionQuality: 0.8) else { return }
            try? data.write(to: cacheURL)
        }.value
    }

    /// 生成磁盘缓存的文件名
    private func diskCacheKey(for url: URL) -> String {
        let hash = abs(url.absoluteString.hashValue)
        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
        return "\(hash).\(ext)"
    }

    /// 获取磁盘缓存大小
    private func getDiskCacheSize() async -> Int {
        return await Task.detached {
            guard let files = try? FileManager.default.contentsOfDirectory(at: self.diskCacheURL, includingPropertiesForKeys: [.fileSizeKey]) else {
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
