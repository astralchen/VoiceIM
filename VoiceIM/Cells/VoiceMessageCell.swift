import UIKit

@MainActor
protocol VoiceMessageCellDelegate: AnyObject {
    func cellDidTapPlay(_ cell: VoiceMessageCell, message: ChatMessage)
    func cellDidSeek(_ cell: VoiceMessageCell, message: ChatMessage, progress: Float)
}

/// 语音消息气泡 Cell，继承 ChatBubbleCell 获得时间分隔行、头像和收/发方向布局。
/// 本类只负责语音播放控件（播放按钮、进度滑块、时长标签、未读红点）。
final class VoiceMessageCell: ChatBubbleCell {

    nonisolated static let reuseID = "VoiceMessageCell"

    weak var delegate: VoiceMessageCellDelegate?
    private(set) var message: ChatMessage?

    // MARK: - 子视图（均添加到基类的 bubble 容器内，unreadDot 除外）

    private let playBtn      = UIButton(type: .system)
    private let durationLabel = UILabel()
    /// 音量条进度视图，播放时可见，支持拖拽跳转
    private let waveformView = WaveformProgressView()
    /// 用户正在拖拽时为 true，屏蔽来自播放器的进度推送，避免抖动
    private var isSeeking    = false
    /// 未播放红点（加到 contentView 层，避免被 bubble.masksToBounds 裁掉一半）
    private let unreadDot    = UIView()

    // MARK: - 初始化

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupVoiceUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - UI 搭建

    private func setupVoiceUI() {
        // 播放按钮
        playBtn.setImage(UIImage(systemName: "play.fill"), for: .normal)
        playBtn.tintColor = .label
        playBtn.contentVerticalAlignment   = .fill
        playBtn.contentHorizontalAlignment = .fill
        playBtn.translatesAutoresizingMaskIntoConstraints = false
        playBtn.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        bubble.addSubview(playBtn)

        // 未播放红点：叠加在播放按钮右上角，需在 contentView 层以免被 bubble 裁剪
        unreadDot.backgroundColor    = .systemRed
        unreadDot.layer.cornerRadius = 5
        unreadDot.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(unreadDot)

        // 音量条进度视图
        waveformView.barCount = 20
        waveformView.barWidth = 2
        waveformView.barSpacing = 3
        waveformView.playedColor = .label
        waveformView.unplayedColor = UIColor.label.withAlphaComponent(0.2)
        waveformView.progressLineColor = .label
        waveformView.progressLineWidth = 1.5
        waveformView.widthPerSecond = 12  // 每秒 12pt，会自动调整 min/max 为 48/120
        waveformView.setContentHuggingPriority(.required, for: .horizontal)
        waveformView.setContentCompressionResistancePriority(.required, for: .horizontal)
        waveformView.translatesAutoresizingMaskIntoConstraints = false
        // 手指按下：标记用户正在拖拽，暂停接收播放器进度更新
        waveformView.addTarget(self, action: #selector(waveformTouchDown), for: .touchDown)
        // 拖动中：实时刷新剩余时长标签
        waveformView.addTarget(self, action: #selector(waveformValueChanged), for: .valueChanged)
        // 手指抬起：执行 seek
        waveformView.addTarget(self, action: #selector(waveformTouchUp), for: .touchUpInside)
        bubble.addSubview(waveformView)

        // 时长标签
        durationLabel.font      = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        durationLabel.textColor = .label
        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(durationLabel)

        NSLayoutConstraint.activate([
            // 播放按钮
            playBtn.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 16),
            playBtn.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 12),
            playBtn.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -12),
            playBtn.widthAnchor.constraint(equalToConstant: 20),
            playBtn.heightAnchor.constraint(equalToConstant: 20),

            // 未读红点：直径 10pt，吸附在播放按钮右上角
            unreadDot.widthAnchor.constraint(equalToConstant: 10),
            unreadDot.heightAnchor.constraint(equalToConstant: 10),
            unreadDot.centerXAnchor.constraint(equalTo: playBtn.trailingAnchor, constant: -2),
            unreadDot.centerYAnchor.constraint(equalTo: playBtn.topAnchor, constant: 2),

            // 音量条进度视图
            waveformView.leadingAnchor.constraint(equalTo: playBtn.trailingAnchor, constant: 12),
            waveformView.centerYAnchor.constraint(equalTo: bubble.centerYAnchor),
            waveformView.heightAnchor.constraint(equalToConstant: 24),

            // 时长标签
            durationLabel.leadingAnchor.constraint(equalTo: waveformView.trailingAnchor, constant: 12),
            durationLabel.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -16),
            durationLabel.centerYAnchor.constraint(equalTo: bubble.centerYAnchor),
            durationLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 24),
        ])
    }

    // MARK: - 配置

    /// cell 配置入口，由 DiffableDataSource 的 cell provider 或 reloadItems 触发时调用。
    ///
    /// # 红点（unreadDot）更新策略
    ///
    /// ## 早期方案（已废弃）：ViewController 直接调用 cell.markAsRead()
    ///   ViewController 在 markAsPlayed 中直接拿到 cell 引用并调用 markAsRead()，
    ///   触发淡出动画。问题：绕过了数据驱动原则，ViewController 直接操作 cell 内部视图。
    ///
    /// ## 当前方案：动画逻辑内化到 configure，由状态变化驱动
    ///   markAsPlayed 通过 reloadItems 触发 configure 重新执行，
    ///   configure 根据前后状态决定是否播放动画：
    ///   - !isUnread && !unreadDot.isHidden（未读 → 已读）：播放淡出动画
    ///   - 其余情况（初次配置、已读 → 已读、cell 复用）：直接 isHidden 赋值，无动画
    ///   这样既保留了淡出效果，又避免了 cell 复用时错误触发动画。
    ///
    /// ## 红点显示规则
    ///   - 仅对方发送的消息（!isOutgoing）且未播放（!isPlayed）时显示红点
    ///   - 自己发送的消息不显示红点
    func configure(with message: ChatMessage, isPlaying: Bool, progress: Float, isUnread: Bool) {
        self.message = message

        // 设置音频时长并加载波形数据
        if case .voice(let localURL, let remoteURL, let duration) = message.kind {
            // 重要：必须先设置时长，再加载波形数据
            // 原因：
            // 1. audioDuration 会触发 invalidateIntrinsicContentSize()，立即更新视图宽度
            // 2. loadWaveform 是异步的，完成后只更新波形绘制，不影响布局
            // 3. 这个顺序避免了布局闪烁（先显示默认宽度，再跳变到正确宽度）
            waveformView.audioDuration = duration

            // 异步加载真实音频波形数据（不阻塞 UI）
            if let url = localURL ?? remoteURL {
                waveformView.loadWaveform(from: url, targetBarCount: 20)
            }
        }

        applyPlayState(isPlaying: isPlaying, progress: progress)

        // 自己发送的消息不显示红点
        let shouldShowUnread = isUnread && !message.isOutgoing

        if !shouldShowUnread && !unreadDot.isHidden {
            // 未读 → 已读：淡出动画
            UIView.animate(withDuration: 0.2) {
                self.unreadDot.alpha = 0
            } completion: { _ in
                self.unreadDot.isHidden = true
                self.unreadDot.alpha = 1
            }
        } else {
            // 初次配置 / 复用 / 已读状态：直接显隐，不触发动画
            unreadDot.isHidden = !shouldShowUnread
        }
    }

    func applyPlayState(isPlaying: Bool, progress: Float) {
        let icon = isPlaying ? "pause.fill" : "play.fill"
        playBtn.setImage(UIImage(systemName: icon), for: .normal)

        if isPlaying {
            // 用户拖拽期间不更新进度，避免抖动；但始终刷新剩余时长
            if !isSeeking {
                waveformView.progress = progress
            }
            updateRemainingLabel(progress: waveformView.progress)
        } else {
            isSeeking = false
            waveformView.progress = 0
            showTotalDuration()
        }
    }

    // MARK: - 时长标签

    private func showTotalDuration() {
        guard let msg = message else { return }
        let secs = Int(max(msg.duration, 0).rounded(.down))
        durationLabel.text = String(format: "%d\"", max(secs, 1))
    }

    private func updateRemainingLabel(progress: Float) {
        guard let msg = message else { return }
        let remaining = msg.duration * Double(1.0 - progress)
        let secs = Int(max(remaining, 0).rounded(.down))
        durationLabel.text = String(format: "%d\"", max(secs, 0))
    }

    // MARK: - Waveform 事件

    @objc private func waveformTouchDown() {
        isSeeking = true
    }

    @objc private func waveformValueChanged() {
        updateRemainingLabel(progress: waveformView.progress)
    }

    @objc private func waveformTouchUp() {
        guard let msg = message else {
            isSeeking = false
            return
        }
        isSeeking = false
        delegate?.cellDidSeek(self, message: msg, progress: waveformView.progress)
    }

    // MARK: - 播放按钮事件

    @objc private func playTapped() {
        guard let msg = message else { return }
        delegate?.cellDidTapPlay(self, message: msg)
    }
}

// MARK: - MessageCellConfigurable

extension VoiceMessageCell: MessageCellConfigurable {

    func configure(with message: ChatMessage, deps: MessageCellDependencies) {
        // 先调基类方法更新时间分隔行、头像和收/发方向
        configureCommon(message: message, showTimeHeader: deps.showTimeHeader)
        // 再更新语音播放状态
        delegate = deps.voiceDelegate
        let isPlaying = deps.isPlaying(message.id)
        let progress = isPlaying ? deps.currentProgress(message.id) : 0
        configure(with: message,
                  isPlaying: isPlaying,
                  progress: progress,
                  isUnread: !message.isPlayed)
    }
}
