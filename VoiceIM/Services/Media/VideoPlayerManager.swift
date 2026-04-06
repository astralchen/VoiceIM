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

/// 视频播放管理器（MainActor 隔离，因为 AVPlayer 是 MainActor 隔离的）
@MainActor
final class VideoPlayerManager {

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?

    private(set) var state: VideoPlaybackState = .idle

    private var _onProgress: ((TimeInterval, TimeInterval) -> Void)?
    private var _onStateChange: ((VideoPlaybackState) -> Void)?
    private var _onFinish: (() -> Void)?

    /// 一次性原子设置所有回调（须在 load 之前调用，保证不会漏掉早期状态变化）
    func configureCallbacks(
        onStateChange: @escaping (VideoPlaybackState) -> Void,
        onProgress: @escaping (TimeInterval, TimeInterval) -> Void,
        onFinish: @escaping () -> Void
    ) {
        _onStateChange = onStateChange
        _onProgress = onProgress
        _onFinish = onFinish
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
            Task { @MainActor in
                self?.handleStatusChange(item.status)
            }
        }

        // 监听播放完成
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.handlePlaybackFinished()
                }
            }

        // 添加进度监听（每 0.1 秒回调一次）
        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                self?.handleProgressUpdate(time)
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
        _onStateChange?(newState)
    }

    private func handleStatusChange(_ status: AVPlayerItem.Status) {
        switch status {
        case .readyToPlay:
            // play() 已先被调用时保持 .playing，不强制覆盖为 .paused
            if case .playing = state { break }
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
        _onProgress?(current, duration)
    }

    private func handlePlaybackFinished() {
        // 回到开头
        let startTime = CMTime(seconds: 0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player?.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)

        updateState(.paused)
        _onFinish?()
    }
}
