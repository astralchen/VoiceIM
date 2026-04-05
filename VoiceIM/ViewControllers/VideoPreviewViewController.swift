import UIKit
import AVFoundation

/// 视频预览页面，支持自定义播放控制和苹果相册风格的转场动画
///
/// 实现 `ZoomTransitionTarget` 后，`ZoomTransitionController` 会自动为本页面
/// 安装下滑关闭手势，无需在此添加任何转场相关代码。
@MainActor
final class VideoPreviewViewController: UIViewController {

    private let videoURL: URL
    private let playerManager = VideoPlayerManager()
    private var playerView: VideoPlayerView!
    private let closeButton = UIButton(type: .system)

    private var isPlaying = false
    private var hideControlsTimer: Timer?

    // MARK: - 初始化

    init(videoURL: URL) {
        self.videoURL = videoURL
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupUI()
        setupPlayer()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        hideControlsTimer?.invalidate()
        hideControlsTimer = nil
        Task { await playerManager.pause() }
    }

    deinit {
        Task { [playerManager] in await playerManager.cleanup() }
    }

    // MARK: - UI 搭建

    private func setupUI() {
        playerView = VideoPlayerView()
        playerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(playerView)

        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor          = .white
        closeButton.backgroundColor    = UIColor.black.withAlphaComponent(0.5)
        closeButton.layer.cornerRadius = 20
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)

        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: view.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 40),
            closeButton.heightAnchor.constraint(equalToConstant: 40),
        ])

        playerView.onPlayPauseTapped           = { [weak self] in self?.handlePlayPauseTapped() }
        playerView.onSeek                      = { [weak self] time in self?.handleSeek(to: time) }
        playerView.onControlsVisibilityChanged = { [weak self] v in self?.handleControlsVisibilityChanged(v) }
        playerView.onPlaybackRateChanged       = { [weak self] rate in self?.handlePlaybackRateChanged(rate) }
    }

    // MARK: - 播放器设置

    private func setupPlayer() {
        Task {
            await playerManager.configureCallbacks(
                onStateChange: { [weak self] state in self?.handleStateChange(state) },
                onProgress:    { [weak self] cur, dur in
                    self?.playerView.updateProgress(current: cur, duration: dur)
                },
                onFinish: { [weak self] in
                    self?.isPlaying = false
                    self?.playerView.updatePlaybackState(isPlaying: false)
                }
            )
            await playerManager.load(url: videoURL)
            if let player = await playerManager.getPlayer() {
                playerView.setPlayer(player)
            }
            await playerManager.play()
        }
    }

    // MARK: - 事件处理

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    private func handlePlayPauseTapped() {
        Task {
            if isPlaying { await playerManager.pause() }
            else          { await playerManager.play()  }
        }
    }

    private func handleSeek(to time: TimeInterval) {
        Task { await playerManager.seek(to: time) }
    }

    private func handlePlaybackRateChanged(_ rate: Float) {
        Task { await playerManager.setPlaybackRate(rate) }
    }

    private func handleStateChange(_ state: VideoPlaybackState) {
        switch state {
        case .idle:    playerView.showLoading(false); showControls()
        case .loading: playerView.showLoading(true);  showControls()
        case .playing:
            isPlaying = true
            playerView.showLoading(false)
            playerView.updatePlaybackState(isPlaying: true)
            scheduleHideControls()
        case .paused:
            isPlaying = false
            playerView.showLoading(false)
            playerView.updatePlaybackState(isPlaying: false)
            showControls()
        case .failed(let error):
            playerView.showLoading(false); showControls(); showError(error)
        }
    }

    private func showError(_ error: Error) {
        let alert = UIAlertController(title: "播放失败", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }

    // MARK: - 控制层显示/隐藏

    private func showControls() {
        hideControlsTimer?.invalidate()
        hideControlsTimer = nil
        setControlsVisible(true)
    }

    private func scheduleHideControls() {
        hideControlsTimer?.invalidate()
        hideControlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.hideControls() }
        }
    }

    private func hideControls() {
        guard isPlaying else { return }
        setControlsVisible(false)
    }

    private func handleControlsVisibilityChanged(_ visible: Bool) {
        hideControlsTimer?.invalidate()
        hideControlsTimer = nil
        UIView.animate(withDuration: 0.3) { self.closeButton.alpha = visible ? 1 : 0 }
        if visible && isPlaying { scheduleHideControls() }
    }

    private func setControlsVisible(_ visible: Bool) {
        UIView.animate(withDuration: 0.3) { self.closeButton.alpha = visible ? 1 : 0 }
        playerView.setControlsVisible(visible, animated: true)
    }
}

// MARK: - ZoomTransitionTarget

extension VideoPreviewViewController: ZoomTransitionTarget {

    var zoomContentView: UIView { playerView }

    /// 视频全屏展示，内容区域等于整个 view
    var zoomDisplayFrame: CGRect { view.bounds }

    // zoomDismissGestureEnabled 使用默认值 true（视频页始终允许下滑关闭）
}
