import UIKit

// MARK: - Error

enum ImageCacheError: LocalizedError {
    case loadFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .loadFailed:    return "无法读取图片文件"
        case .encodingFailed: return "图片编码失败"
        }
    }
}

/// 图片缓存管理器：统一管理本地和远程图片的缓存
///
/// # 缓存层级
///
/// ```
/// 内存缓存 (NSCache)          ← 最快，应用重启后清空
///     ↓ miss
/// 磁盘缓存 (ImageCache/)      ← 持久化，发送的图片和远程下载图片
///     ↓ miss（仅远程 URL）
/// 网络下载                     ← 下载后同时写入内存和磁盘
/// ```
///
/// # URL 类型处理
///
/// - **本地文件 URL**：直接读取，不写磁盘缓存（文件本身就是缓存）
/// - **远程 URL**：下载后写入磁盘缓存，键名用稳定哈希（djb2），跨进程不变
///
/// # 临时缓存
///
/// 用于选图/处理期间的短暂显示，与永久缓存隔离：
/// ```swift
/// // 选图后立即显示
/// imageManager.cacheTemporary(image, for: pickerTempURL)
///
/// // 保存完成后提升到永久缓存
/// let finalURL = try await imageManager.saveAndCacheImage(from: pickerTempURL)
///
/// // 清理临时数据
/// imageManager.clearTemporaryCache()
/// ```
@MainActor
final class ImageCacheManager {

    static let shared = ImageCacheManager()

    // MARK: - Properties

    /// 永久内存缓存（已发送/已下载的图片）
    private nonisolated(unsafe) let memoryCache = NSCache<NSString, UIImage>()

    /// 临时内存缓存（选图/处理期间）
    private nonisolated(unsafe) let tempMemoryCache = NSCache<NSString, UIImage>()

    /// 永久磁盘缓存目录
    let diskCacheURL: URL

    /// 磁盘操作 actor（保证并发安全）
    private let diskActor = DiskCacheActor()

    // MARK: - Init

    private init() {
        memoryCache.countLimit = 50
        memoryCache.totalCostLimit = 50 * 1024 * 1024  // 50 MB

        tempMemoryCache.countLimit = 10
        tempMemoryCache.totalCostLimit = 20 * 1024 * 1024  // 20 MB

        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskCacheURL = cacheDir.appendingPathComponent("ImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)

        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.clearMemoryCache()
        }
    }

    /// 测试专用初始化方法（使用独立磁盘目录，避免污染真实缓存）
    init(testDiskCacheURL: URL) {
        memoryCache.countLimit = 50
        memoryCache.totalCostLimit = 50 * 1024 * 1024

        tempMemoryCache.countLimit = 10
        tempMemoryCache.totalCostLimit = 20 * 1024 * 1024

        diskCacheURL = testDiskCacheURL
        try? FileManager.default.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
    }

    // MARK: - URL Resolution

    /// 解析图片 URL，优先级：本地文件 → 磁盘缓存（路径失效时） → 远程 URL
    ///
    /// 场景：模拟器重启后应用容器 ID 变化导致本地绝对路径失效。
    /// 此时从磁盘缓存目录按文件名重新查找。
    nonisolated func resolveImageURL(local localURL: URL?, remote remoteURL: URL?) -> URL? {
        if let localURL {
            if FileManager.default.fileExists(atPath: localURL.path) {
                return localURL
            }
            // 路径失效（如模拟器重启），按 stableDiskFileName 在磁盘缓存中查找
            let cached = diskCacheURL.appendingPathComponent(stableDiskFileName(for: localURL))
            if FileManager.default.fileExists(atPath: cached.path) {
                return cached
            }
        }
        return remoteURL
    }

    // MARK: - Sync Cache Check

    /// 同步查询缓存（内存 → 磁盘），命中时直接返回，避免异步加载闪烁
    ///
    /// 磁盘读取适用于已下采样的缩略图（50–100 KB），同步 I/O 代价可接受。
    /// 命中磁盘缓存时会同步回写内存，下次调用直接走内存。
    nonisolated func cachedImage(for url: URL) -> UIImage? {
        let key = memoryCacheKey(for: url)

        // 1. 内存缓存（永久 + 临时）
        if let image = memoryCache.object(forKey: key as NSString)
            ?? tempMemoryCache.object(forKey: key as NSString) {
            return image
        }

        // 2. 磁盘缓存：本地文件直接读，远程 URL 查缓存目录
        let diskPath = url.isFileURL
            ? url.standardized.path
            : diskCacheURL.appendingPathComponent(stableDiskFileName(for: url)).path

        guard FileManager.default.fileExists(atPath: diskPath),
              let image = UIImage(contentsOfFile: diskPath) else {
            return nil
        }

        // 回写内存缓存（NSCache 线程安全，nonisolated 可直接操作）
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)

        return image
    }

    // MARK: - Async Load

    /// 加载图片（内存 → 磁盘 → 网络，并发去重）
    ///
    /// - Parameters:
    ///   - url: 本地 file URL 或远程 HTTPS URL
    ///   - targetSize: 目标渲染尺寸，用于下采样节省内存
    func loadImage(from url: URL, targetSize: CGSize? = nil) async -> UIImage? {
        // 1. 内存 + 磁盘同步检查（复用 cachedImage，命中则无需启动 Task）
        if let image = cachedImage(for: url) {
            return image
        }

        // 2. 并发去重：复用已有任务
        if let existing = await diskActor.getLoadingTask(for: url) {
            return try? await existing.value
        }

        // 3. 启动新任务
        let task = Task<UIImage?, Error> { [weak self] in
            guard let self else { return nil }
            return url.isFileURL
                ? await self.loadLocalImage(url: url, targetSize: targetSize)
                : await self.loadRemoteImage(url: url, targetSize: targetSize)
        }

        await diskActor.setLoadingTask(task, for: url)
        let result = try? await task.value
        await diskActor.removeLoadingTask(for: url)
        return result
    }

    // MARK: - Save to Permanent Cache

    /// 将临时图片文件持久化到磁盘缓存（用于发送图片消息）
    ///
    /// 流程：下采样 → JPEG 压缩 → 写磁盘 → 更新内存缓存
    ///
    /// - Parameter tempURL: 临时文件 URL（PHPicker 返回的路径或 Photos 导出路径）
    /// - Returns: 磁盘缓存中的永久路径（存储到 ChatMessage.kind 里）
    func saveAndCacheImage(from tempURL: URL) async throws -> URL {
        let fileName = UUID().uuidString + ".jpg"
        let cacheURL = diskCacheURL.appendingPathComponent(fileName)

        let thumbnailSize = CGSize(width: 250, height: 350)
        guard let thumbnail = await downsampleImage(at: tempURL, to: thumbnailSize) else {
            throw ImageCacheError.loadFailed
        }
        guard let data = thumbnail.jpegData(compressionQuality: 0.8) else {
            throw ImageCacheError.encodingFailed
        }

        try data.write(to: cacheURL)

        let key = memoryCacheKey(for: cacheURL)
        writeToMemoryCache(image: thumbnail, key: key)

        VoiceIM.logger.info("💾 Saved image: \(fileName)")
        return cacheURL
    }

    // MARK: - Temporary Cache

    /// 缓存临时图片到内存（选图预览、处理期间使用）
    ///
    /// 临时缓存不写磁盘，内存警告时优先清除。
    nonisolated func cacheTemporary(_ image: UIImage, for url: URL) {
        let key = memoryCacheKey(for: url)
        let cost = Int(image.size.width * image.size.height * 4)
        tempMemoryCache.setObject(image, forKey: key as NSString, cost: cost)
    }

    /// 清理临时内存缓存（发送完成或取消后调用）
    nonisolated func clearTemporaryCache() {
        tempMemoryCache.removeAllObjects()
    }

    // MARK: - Management

    /// 预加载图片（后台加载，不等待结果）
    func preloadImage(from url: URL, targetSize: CGSize? = nil) {
        Task {
            _ = await loadImage(from: url, targetSize: targetSize)
        }
    }

    /// 清理所有内存缓存
    nonisolated func clearMemoryCache() {
        memoryCache.removeAllObjects()
        tempMemoryCache.removeAllObjects()
        VoiceIM.logger.info("Cleared image memory cache")
    }

    /// 清理磁盘缓存
    func clearDiskCache() async {
        await diskActor.clearDirectory(diskCacheURL)
    }

    /// 获取缓存占用大小
    func getCacheSize() async -> (memory: Int, disk: Int) {
        let diskSize = await diskActor.directorySize(diskCacheURL)
        return (memory: 0, disk: diskSize)
    }

    /// 按文件名拼接磁盘缓存路径（兼容旧代码路径回退逻辑）
    nonisolated func fileURL(for fileName: String) -> URL {
        diskCacheURL.appendingPathComponent(fileName)
    }

    // MARK: - Private: Load

    private func loadLocalImage(url: URL, targetSize: CGSize?) async -> UIImage? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            VoiceIM.logger.warning("Image not found: \(url.lastPathComponent)")
            return nil
        }
        guard let image = await downsampleImage(at: url, to: targetSize) else { return nil }
        writeToMemoryCache(image: image, key: memoryCacheKey(for: url))
        return image
    }

    private func loadRemoteImage(url: URL, targetSize: CGSize?) async -> UIImage? {
        let diskFileName = stableDiskFileName(for: url)
        let diskURL = diskCacheURL.appendingPathComponent(diskFileName)

        // 磁盘缓存命中
        if FileManager.default.fileExists(atPath: diskURL.path),
           let image = await downsampleImage(at: diskURL, to: targetSize) {
            writeToMemoryCache(image: image, key: memoryCacheKey(for: url))
            VoiceIM.logger.debug("💿 Disk hit: \(url.lastPathComponent)")
            return image
        }

        // 下载
        VoiceIM.logger.info("⬇️ Downloading: \(url.absoluteString)")
        guard let data = await downloadData(from: url) else {
            VoiceIM.logger.error("Download failed: \(url.absoluteString)")
            return nil
        }
        guard let image = await downsampleImageFromData(data, to: targetSize) else { return nil }

        writeToMemoryCache(image: image, key: memoryCacheKey(for: url))

        // 异步写磁盘，不阻塞返回
        Task.detached(priority: .background) {
            guard let cacheData = image.jpegData(compressionQuality: 0.8) else { return }
            try? cacheData.write(to: diskURL)
        }

        VoiceIM.logger.info("✅ Downloaded: \(url.lastPathComponent)")
        return image
    }

    // MARK: - Private: Image Processing

    private func downsampleImage(at url: URL, to targetSize: CGSize?) async -> UIImage? {
        await Task.detached {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return self.createThumbnail(from: source, targetSize: targetSize)
        }.value
    }

    private func downsampleImageFromData(_ data: Data, to targetSize: CGSize?) async -> UIImage? {
        await Task.detached {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return self.createThumbnail(from: source, targetSize: targetSize)
        }.value
    }

    private nonisolated func createThumbnail(from source: CGImageSource, targetSize: CGSize?) -> UIImage? {
        var options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if let size = targetSize {
            let scale: CGFloat = 3.0
            let maxPx = max(size.width, size.height) * scale
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
            options[kCGImageSourceCreateThumbnailWithTransform] = true
            options[kCGImageSourceThumbnailMaxPixelSize] = maxPx
        }
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private func downloadData(from url: URL) async -> Data? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                VoiceIM.logger.error("HTTP \(http.statusCode): \(url.absoluteString)")
                return nil
            }
            return data
        } catch {
            VoiceIM.logger.error("Network error: \(error)")
            return nil
        }
    }

    // MARK: - Private: Cache Helpers

    private func writeToMemoryCache(image: UIImage, key: String) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)
    }

    /// 内存缓存键：本地文件用规范路径，远程用完整 URL 字符串
    private nonisolated func memoryCacheKey(for url: URL) -> String {
        url.isFileURL ? url.standardized.path : url.absoluteString
    }

    /// 磁盘缓存文件名（本地和远程 URL 通用）
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
        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
        return "\(hash).\(ext)"
    }
}

// MARK: - DiskCacheActor

/// 磁盘缓存操作 actor（串行执行，保证并发安全）
private actor DiskCacheActor {

    private var loadingTasks: [URL: Task<UIImage?, Error>] = [:]

    func getLoadingTask(for url: URL) -> Task<UIImage?, Error>? {
        loadingTasks[url]
    }

    func setLoadingTask(_ task: Task<UIImage?, Error>, for url: URL) {
        loadingTasks[url] = task
    }

    func removeLoadingTask(for url: URL) {
        loadingTasks.removeValue(forKey: url)
    }

    func clearDirectory(_ url: URL) {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
            VoiceIM.logger.info("Cleared directory: \(url.lastPathComponent) (\(files.count) files)")
        } catch {
            VoiceIM.logger.error("Failed to clear directory: \(error)")
        }
    }

    func directorySize(_ url: URL) -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }

        return files.reduce(0) { total, file in
            total + ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
