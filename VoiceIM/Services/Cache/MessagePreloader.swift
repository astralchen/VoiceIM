import Foundation

/// 消息预加载器：提前加载即将显示的消息资源
///
/// # 功能特性
/// - 预加载图片：提前加载可见范围附近的图片
/// - 智能预测：根据滚动方向预加载
/// - 优先级管理：优先加载可见区域
/// - 自动取消：离开可见范围时取消预加载
///
/// # 使用方式
/// ```swift
/// let preloader = MessagePreloader.shared
/// preloader.updateVisibleRange(messages: messages, visibleIndexPaths: indexPaths)
/// ```
@MainActor
final class MessagePreloader {

    static let shared = MessagePreloader()

    // MARK: - Properties

    private let imageCache: ImageCacheManager
    private let videoCache: VideoCacheManager

    /// 预加载窗口大小（可见范围前后各预加载多少条）
    private let preloadWindow = 5

    /// 当前预加载的消息 ID
    private var preloadedMessageIDs = Set<String>()

    /// 上次可见范围（用于判断滚动方向）
    private var lastVisibleRange: Range<Int>?

    // MARK: - Init

    /// - Note: 默认参数不能写 `= .shared`（Swift 6 下默认实参非隔离，无法引用 `@MainActor` 的 `ImageCacheManager.shared`），故用 `nil` 在 init 体内回退。
    init(
        imageCache: ImageCacheManager? = nil,
        videoCache: VideoCacheManager? = nil
    ) {
        self.imageCache = imageCache ?? ImageCacheManager.shared
        self.videoCache = videoCache ?? VideoCacheManager.shared
    }

    // MARK: - Public API

    /// 更新可见范围，触发预加载
    ///
    /// - Parameters:
    ///   - messages: 所有消息列表
    ///   - visibleIndexPaths: 当前可见的 IndexPath
    func updateVisibleRange(messages: [ChatMessage], visibleIndexPaths: [IndexPath]) {
        guard !visibleIndexPaths.isEmpty else { return }

        // 计算可见范围
        let visibleIndices = visibleIndexPaths.map { $0.item }.sorted()
        guard let minIndex = visibleIndices.first,
              let maxIndex = visibleIndices.last else { return }

        let visibleRange = minIndex..<(maxIndex + 1)

        // 判断滚动方向
        let scrollDirection = detectScrollDirection(current: visibleRange, previous: lastVisibleRange)
        lastVisibleRange = visibleRange

        // 计算预加载范围
        let preloadRange = calculatePreloadRange(
            visibleRange: visibleRange,
            scrollDirection: scrollDirection,
            totalCount: messages.count
        )

        // 预加载图片
        preloadImages(in: preloadRange, messages: messages)

        // 清理不再需要的预加载
        cleanupPreloads(visibleRange: visibleRange, messages: messages)
    }

    /// 清除所有预加载
    func clearAll() {
        preloadedMessageIDs.removeAll()
        lastVisibleRange = nil
    }

    // MARK: - Private Methods

    /// 检测滚动方向
    private func detectScrollDirection(current: Range<Int>, previous: Range<Int>?) -> ScrollDirection {
        guard let previous = previous else { return .none }

        if current.lowerBound > previous.lowerBound {
            return .down  // 向下滚动（查看更新的消息）
        } else if current.lowerBound < previous.lowerBound {
            return .up    // 向上滚动（查看历史消息）
        } else {
            return .none
        }
    }

    /// 计算预加载范围
    private func calculatePreloadRange(
        visibleRange: Range<Int>,
        scrollDirection: ScrollDirection,
        totalCount: Int
    ) -> Range<Int> {
        let start: Int
        let end: Int

        switch scrollDirection {
        case .up:
            // 向上滚动，优先预加载上方
            start = max(0, visibleRange.lowerBound - preloadWindow)
            end = min(totalCount, visibleRange.upperBound + preloadWindow / 2)

        case .down:
            // 向下滚动，优先预加载下方
            start = max(0, visibleRange.lowerBound - preloadWindow / 2)
            end = min(totalCount, visibleRange.upperBound + preloadWindow)

        case .none:
            // 无滚动，均匀预加载
            start = max(0, visibleRange.lowerBound - preloadWindow)
            end = min(totalCount, visibleRange.upperBound + preloadWindow)
        }

        return start..<end
    }

    /// 预加载图片
    private func preloadImages(in range: Range<Int>, messages: [ChatMessage]) {
        for index in range {
            guard index < messages.count else { continue }

            let message = messages[index]

            // 跳过已预加载的消息
            guard !preloadedMessageIDs.contains(message.id) else { continue }

            // 标记为已预加载
            preloadedMessageIDs.insert(message.id)

            // 预加载图片消息（`Task` 脱开当前调用栈，避免在滚动回调里串行 await 阻塞 UI）
            if case .image(let localURL, _) = message.kind,
               let imageURL = localURL {
                Task {
                    let targetSize = CGSize(width: 250, height: 350)
                    imageCache.preloadImage(from: imageURL, targetSize: targetSize)
                    VoiceIM.logger.debug("Preloaded image for message: \(message.id)")
                }
            }

            // 预加载视频缩略图
            if case .video(let localURL, _, _) = message.kind,
               let videoURL = localURL {
                Task {
                    _ = await videoCache.loadThumbnail(from: videoURL)
                    VoiceIM.logger.debug("Preloaded video thumbnail for message: \(message.id)")
                }
            }
        }
    }

    /// 清理不再需要的预加载
    private func cleanupPreloads(visibleRange: Range<Int>, messages: [ChatMessage]) {
        // 计算清理范围（可见范围外 20 条以上的消息）
        let cleanupThreshold = 20
        let keepRange = max(0, visibleRange.lowerBound - cleanupThreshold)..<min(messages.count, visibleRange.upperBound + cleanupThreshold)

        // 找出需要清理的消息 ID
        var idsToRemove = Set<String>()
        for (index, message) in messages.enumerated() {
            if !keepRange.contains(index) && preloadedMessageIDs.contains(message.id) {
                idsToRemove.insert(message.id)
            }
        }

        // 从预加载集合中移除
        preloadedMessageIDs.subtract(idsToRemove)

        if !idsToRemove.isEmpty {
            VoiceIM.logger.debug("Cleaned up \(idsToRemove.count) preloaded messages")
        }
    }

    // MARK: - Types

    private enum ScrollDirection {
        case up
        case down
        case none
    }
}
