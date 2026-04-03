import AVFoundation
import UIKit

/// 自定义视频播放视图
@MainActor
final class VideoPlayerView: UIView {

    // MARK: - 子视图

    private let playerLayer = AVPlayerLayer()

    private let controlsContainerView: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.3)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let playPauseButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 44, weight: .medium)
        button.setImage(UIImage(systemName: "play.fill", withConfiguration: config), for: .normal)
        button.tintColor = .white
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let progressSlider: UISlider = {
        let slider = UISlider()
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.minimumTrackTintColor = .systemBlue
        slider.maximumTrackTintColor = .white.withAlphaComponent(0.5)
        slider.translatesAutoresizingMaskIntoConstraints = false
        return slider
    }()

    private let currentTimeLabel: UILabel = {
        let label = UILabel()
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .white
        label.text = "00:00"
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let durationLabel: UILabel = {
        let label = UILabel()
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .white
        label.text = "00:00"
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let loadingIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .large)
        indicator.color = .white
        indicator.hidesWhenStopped = true
        indicator.translatesAutoresizingMaskIntoConstraints = false
        return indicator
    }()

    private let playbackRateButton: UIButton = {
        let button = UIButton(type: .system)
        button.tintColor = .white
        button.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        button.layer.cornerRadius = 4
        button.translatesAutoresizingMaskIntoConstraints = false

        if #available(iOS 15.0, *) {
            var config = UIButton.Configuration.plain()
            config.title = "1.0x"
            config.baseForegroundColor = .white
            config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
            button.configuration = config
        } else {
            button.setTitle("1.0x", for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
            button.contentEdgeInsets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        }

        return button
    }()

    // MARK: - 属性

    private var isSeeking = false
    private var currentPlaybackRate: Float = 1.0

    /// 播放/暂停按钮点击回调
    var onPlayPauseTapped: (() -> Void)?
    /// 进度条拖动回调（目标时间，秒）
    var onSeek: ((TimeInterval) -> Void)?
    /// 控制层显示/隐藏回调
    var onControlsVisibilityChanged: ((Bool) -> Void)?
    /// 倍速切换回调
    var onPlaybackRateChanged: ((Float) -> Void)?

    // MARK: - 初始化

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }

    // MARK: - 公共接口

    /// 设置 AVPlayer
    func setPlayer(_ player: AVPlayer?) {
        playerLayer.player = player
    }

    /// 更新播放状态
    func updatePlaybackState(isPlaying: Bool) {
        let iconName = isPlaying ? "pause.fill" : "play.fill"
        let config = UIImage.SymbolConfiguration(pointSize: 44, weight: .medium)
        playPauseButton.setImage(UIImage(systemName: iconName, withConfiguration: config), for: .normal)
    }

    /// 更新进度（仅在非拖动状态下更新）
    func updateProgress(current: TimeInterval, duration: TimeInterval) {
        guard !isSeeking else { return }

        currentTimeLabel.text = formatTime(current)
        durationLabel.text = formatTime(duration)

        if duration > 0 {
            progressSlider.value = Float(current / duration)
        }
    }

    /// 显示加载指示器
    func showLoading(_ show: Bool) {
        if show {
            loadingIndicator.startAnimating()
        } else {
            loadingIndicator.stopAnimating()
        }
    }

    /// 显示/隐藏控制层
    func setControlsVisible(_ visible: Bool, animated: Bool = true) {
        let alpha: CGFloat = visible ? 1 : 0
        if animated {
            UIView.animate(withDuration: 0.3) {
                self.controlsContainerView.alpha = alpha
            }
        } else {
            controlsContainerView.alpha = alpha
        }
    }

    // MARK: - 私有方法

    private func setupUI() {
        backgroundColor = .black

        // 添加 playerLayer
        layer.addSublayer(playerLayer)
        playerLayer.videoGravity = .resizeAspect

        // 添加控制层容器
        addSubview(controlsContainerView)
        addSubview(loadingIndicator)

        // 添加控制元素到容器
        controlsContainerView.addSubview(playPauseButton)
        controlsContainerView.addSubview(progressSlider)
        controlsContainerView.addSubview(currentTimeLabel)
        controlsContainerView.addSubview(durationLabel)
        controlsContainerView.addSubview(playbackRateButton)

        // 布局约束
        NSLayoutConstraint.activate([
            // 控制层容器填充整个视图
            controlsContainerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            controlsContainerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            controlsContainerView.topAnchor.constraint(equalTo: topAnchor),
            controlsContainerView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // 加载指示器居中
            loadingIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),

            // 播放/暂停按钮居中
            playPauseButton.centerXAnchor.constraint(equalTo: controlsContainerView.centerXAnchor),
            playPauseButton.centerYAnchor.constraint(equalTo: controlsContainerView.centerYAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 60),
            playPauseButton.heightAnchor.constraint(equalToConstant: 60),

            // 倍速按钮在右上角
            playbackRateButton.topAnchor.constraint(equalTo: controlsContainerView.safeAreaLayoutGuide.topAnchor, constant: 16),
            playbackRateButton.leadingAnchor.constraint(equalTo: controlsContainerView.leadingAnchor, constant: 16),
            playbackRateButton.heightAnchor.constraint(equalToConstant: 28),

            // 进度条在底部
            progressSlider.leadingAnchor.constraint(equalTo: currentTimeLabel.trailingAnchor, constant: 8),
            progressSlider.trailingAnchor.constraint(equalTo: durationLabel.leadingAnchor, constant: -8),
            progressSlider.bottomAnchor.constraint(equalTo: controlsContainerView.bottomAnchor, constant: -20),

            // 当前时间标签
            currentTimeLabel.leadingAnchor.constraint(equalTo: controlsContainerView.leadingAnchor, constant: 16),
            currentTimeLabel.centerYAnchor.constraint(equalTo: progressSlider.centerYAnchor),

            // 总时长标签
            durationLabel.trailingAnchor.constraint(equalTo: controlsContainerView.trailingAnchor, constant: -16),
            durationLabel.centerYAnchor.constraint(equalTo: progressSlider.centerYAnchor),
        ])

        // 添加手势和事件
        playPauseButton.addTarget(self, action: #selector(handlePlayPauseTapped), for: .touchUpInside)
        playbackRateButton.addTarget(self, action: #selector(handlePlaybackRateTapped), for: .touchUpInside)
        progressSlider.addTarget(self, action: #selector(handleSliderTouchDown), for: .touchDown)
        progressSlider.addTarget(self, action: #selector(handleSliderValueChanged), for: .valueChanged)
        progressSlider.addTarget(self, action: #selector(handleSliderTouchUp), for: [.touchUpInside, .touchUpOutside])

        // 点击视图切换控制层显示/隐藏
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tapGesture)
    }

    @objc private func handlePlayPauseTapped() {
        onPlayPauseTapped?()
    }

    @objc private func handlePlaybackRateTapped() {
        // 循环切换倍速：1.0x -> 1.25x -> 1.5x -> 2.0x -> 1.0x
        let rates: [Float] = [1.0, 1.25, 1.5, 2.0]
        if let currentIndex = rates.firstIndex(of: currentPlaybackRate) {
            let nextIndex = (currentIndex + 1) % rates.count
            currentPlaybackRate = rates[nextIndex]
        } else {
            currentPlaybackRate = 1.0
        }

        updatePlaybackRateButton()
        onPlaybackRateChanged?(currentPlaybackRate)
    }

    private func updatePlaybackRateButton() {
        let title = String(format: "%.2fx", currentPlaybackRate).replacingOccurrences(of: ".00", with: ".0")

        if #available(iOS 15.0, *) {
            var config = playbackRateButton.configuration
            config?.title = title
            playbackRateButton.configuration = config
        } else {
            playbackRateButton.setTitle(title, for: .normal)
        }
    }

    @objc private func handleSliderTouchDown() {
        isSeeking = true
    }

    @objc private func handleSliderValueChanged() {
        guard let duration = playerLayer.player?.currentItem?.duration.seconds,
              duration.isFinite, duration > 0 else { return }
        let targetTime = TimeInterval(progressSlider.value) * duration
        currentTimeLabel.text = formatTime(targetTime)
    }

    @objc private func handleSliderTouchUp() {
        guard let duration = playerLayer.player?.currentItem?.duration.seconds,
              duration.isFinite, duration > 0 else {
            isSeeking = false
            return
        }
        let targetTime = TimeInterval(progressSlider.value) * duration
        onSeek?(targetTime)
        isSeeking = false
    }

    @objc private func handleTap() {
        let isVisible = controlsContainerView.alpha > 0.5
        setControlsVisible(!isVisible, animated: true)
        onControlsVisibilityChanged?(!isVisible)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "00:00" }
        let totalSeconds = Int(seconds)
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, secs)
    }
}
