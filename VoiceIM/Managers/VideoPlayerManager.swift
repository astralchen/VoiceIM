import AVFoundation
import Foundation

/// 视频播放状态
enum VideoPlaybackState {
    case idle
    case loading
    case playing
    case paused
    case failed(Error)
}

/// 视频播放管理器（actor 隔离，线程安全）
actor VideoPlayerManager {

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?

    private(set) var state: VideoPlaybackState = .idle

    // 使用私有存储属性 + nonisolated 计算属性包装
    private var _onProgress: (@MainActor (TimeInterval, TimeInterval) -> Void)?
    private var _onStateChange: (@MainActor (VideoPlaybackState) -> Void)?
    private var _onFinish: (@MainActor () -> Void)?

    /// 播放进度回调 (当前时间, 总时长)
    nonisolated var onProgress: (@MainActor (TimeInterval, TimeInterval) -> Void)? {
        get { nil }
        set {
            Task { await self.setOnProgress(newValue) }
        }
    }

    /// 状态变化回调
    nonisolated var onStateChange: (@MainActor (VideoPlaybackState) -> Void)? {
        get { nil }
        set {
            Task { await self.setOnStateChange(newValue) }
        }
    }

    /// 播放完成回调
    nonisolated var onFinish: (@MainActor () -> Void)? {
        get { nil }
        set {
            Task { await self.setOnFinish(newValue) }
        }
    }

    private func setOnProgress(_ callback: (@MainActor (TimeInterval, TimeInterval) -> Void)?) {
        _onProgress = callback
    }

    private func setOnStateChange(_ callback: (@MainActor (VideoPlaybackState) -> Void)?) {
        _onStateChange = callback
    }

    private func setOnFinish(_ callback: (@MainActor () -> Void)?) {
        _onFinish = callback
    }

    // MARK: - 公共接口

    /// 加载视频
    func load(url: URL) {
        cleanup()

        let playerItem = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: playerItem)
        player = p

        updateState(.loading)

        // 监听播放状态
        statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { [weak self] in
                await self?.handleStatusChange(item.status)
            }
        }

        // 监听播放完成
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main) { [weak self] _ in
                Task { [weak self] in
                    await self?.handlePlaybackFinished()
                }
            }

        // 添加进度监听（每 0.1 秒回调一次）
        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { [weak self] in
                await self?.handleProgressUpdate(time)
            }
        }
    }

    /// 播放
    func play() {
        player?.play()
        updateState(.playing)
    }

    /// 暂停
    func pause() {
        player?.pause()
        updateState(.paused)
    }

    /// 跳转到指定时间（秒）
    func seek(to time: TimeInterval) {
        let cmTime = CMTime(seconds: time, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// 设置播放速率
    func setPlaybackRate(_ rate: Float) {
        player?.rate = rate
    }

    /// 获取当前播放时间（秒）
    func currentTime() -> TimeInterval {
        player?.currentTime().seconds ?? 0
    }

    /// 获取总时长（秒）
    func duration() -> TimeInterval {
        player?.currentItem?.duration.seconds ?? 0
    }

    /// 获取 AVPlayer 实例（用于 AVPlayerLayer）
    func getPlayer() -> AVPlayer? {
        player
    }

    /// 清理资源
    func cleanup() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
        player?.pause()
        player = nil
        NotificationCenter.default.removeObserver(self)
        updateState(.idle)
    }

    // MARK: - 私有方法

    private func updateState(_ newState: VideoPlaybackState) {
        state = newState
        if let callback = _onStateChange {
            Task { @MainActor in
                callback(newState)
            }
        }
    }

    private func handleStatusChange(_ status: AVPlayerItem.Status) {
        switch status {
        case .readyToPlay:
            updateState(.paused)
        case .failed:
            if let error = player?.currentItem?.error {
                updateState(.failed(error))
            }
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func handleProgressUpdate(_ time: CMTime) {
        guard let duration = player?.currentItem?.duration.seconds,
              duration.isFinite, duration > 0 else { return }

        let current = time.seconds
        if let callback = _onProgress {
            Task { @MainActor in
                callback(current, duration)
            }
        }
    }

    private func handlePlaybackFinished() {
        // 回到开头
        let startTime = CMTime(seconds: 0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player?.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)

        updateState(.paused)
        if let callback = _onFinish {
            Task { @MainActor in
                callback()
            }
        }
    }
}
