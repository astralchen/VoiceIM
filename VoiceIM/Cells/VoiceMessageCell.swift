import UIKit

@MainActor
protocol VoiceMessageCellDelegate: AnyObject {
    func cellDidTapPlay(_ cell: VoiceMessageCell, message: ChatMessage)
    func cellDidSeek(_ cell: VoiceMessageCell, message: ChatMessage, progress: Float)
    func cellDidLongPress(_ cell: VoiceMessageCell, message: ChatMessage)
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
    /// 进度滑块，播放时可见，支持拖拽跳转
    private let seekSlider   = UISlider()
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
        playBtn.setImage(UIImage(systemName: "play.circle.fill"), for: .normal)
        playBtn.tintColor = .systemBlue
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

        // 时长标签
        durationLabel.font      = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        durationLabel.textColor = .label
        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(durationLabel)

        // 进度滑块（播放时才显示）
        seekSlider.minimumValue          = 0
        seekSlider.maximumValue          = 1
        seekSlider.value                 = 0
        seekSlider.minimumTrackTintColor = .systemBlue
        seekSlider.maximumTrackTintColor = UIColor.label.withAlphaComponent(0.12)
        let thumbSize = CGSize(width: 14, height: 14)
        seekSlider.setThumbImage(makeThumbImage(size: thumbSize, color: .systemBlue), for: .normal)
        seekSlider.setThumbImage(makeThumbImage(size: thumbSize, color: .systemBlue), for: .highlighted)
        seekSlider.isHidden = true
        seekSlider.translatesAutoresizingMaskIntoConstraints = false
        // 手指按下：标记用户正在拖拽，暂停接收播放器进度更新
        seekSlider.addTarget(self, action: #selector(sliderTouchDown), for: .touchDown)
        // 拖动中：实时刷新剩余时长标签
        seekSlider.addTarget(self, action: #selector(sliderValueChanged), for: .valueChanged)
        // 手指抬起（无论是否在 slider 内）：执行 seek
        seekSlider.addTarget(self, action: #selector(sliderTouchUp),
                             for: [.touchUpInside, .touchUpOutside, .touchCancel])
        bubble.addSubview(seekSlider)

        // 长按气泡触发删除菜单
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(bubbleLongPressed))
        lp.minimumPressDuration = 0.5
        bubble.addGestureRecognizer(lp)

        NSLayoutConstraint.activate([
            // 语音气泡最小宽度，保证播放按钮 + 时长标签不被压缩
            bubble.widthAnchor.constraint(greaterThanOrEqualToConstant: 130),

            // 播放按钮
            playBtn.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 10),
            playBtn.centerYAnchor.constraint(equalTo: bubble.centerYAnchor),
            playBtn.widthAnchor.constraint(equalToConstant: 32),
            playBtn.heightAnchor.constraint(equalToConstant: 32),

            // 未读红点：直径 10pt，吸附在播放按钮右上角
            // unreadDot 与 playBtn 同属 contentView 下，跨子树约束合法
            unreadDot.widthAnchor.constraint(equalToConstant: 10),
            unreadDot.heightAnchor.constraint(equalToConstant: 10),
            unreadDot.centerXAnchor.constraint(equalTo: playBtn.trailingAnchor, constant: -2),
            unreadDot.centerYAnchor.constraint(equalTo: playBtn.topAnchor, constant: 2),

            // 时长标签
            durationLabel.leadingAnchor.constraint(equalTo: playBtn.trailingAnchor, constant: 8),
            durationLabel.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 10),
            durationLabel.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),

            // 进度滑块
            seekSlider.leadingAnchor.constraint(equalTo: playBtn.trailingAnchor, constant: 4),
            seekSlider.topAnchor.constraint(equalTo: durationLabel.bottomAnchor, constant: 2),
            seekSlider.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -8),
            seekSlider.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -8),
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
    func configure(with message: ChatMessage, isPlaying: Bool, progress: Float, isUnread: Bool) {
        self.message = message
        applyPlayState(isPlaying: isPlaying, progress: progress)
        if !isUnread && !unreadDot.isHidden {
            // 未读 → 已读：淡出动画
            UIView.animate(withDuration: 0.2) {
                self.unreadDot.alpha = 0
            } completion: { _ in
                self.unreadDot.isHidden = true
                self.unreadDot.alpha = 1
            }
        } else {
            // 初次配置 / 复用 / 已读状态：直接显隐，不触发动画
            unreadDot.isHidden = !isUnread
        }
    }

    func applyPlayState(isPlaying: Bool, progress: Float) {
        let icon = isPlaying ? "stop.circle.fill" : "play.circle.fill"
        playBtn.setImage(UIImage(systemName: icon), for: .normal)
        seekSlider.isHidden = !isPlaying

        if isPlaying {
            // 用户拖拽期间不更新滑块位置，避免抖动；但始终刷新剩余时长
            if !isSeeking {
                seekSlider.value = progress
            }
            updateRemainingLabel(progress: seekSlider.value)
        } else {
            isSeeking = false
            seekSlider.value = 0
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

    // MARK: - Slider 事件

    @objc private func sliderTouchDown() {
        isSeeking = true
    }

    @objc private func sliderValueChanged() {
        updateRemainingLabel(progress: seekSlider.value)
    }

    @objc private func sliderTouchUp() {
        guard let msg = message else {
            isSeeking = false
            return
        }
        isSeeking = false
        delegate?.cellDidSeek(self, message: msg, progress: seekSlider.value)
    }

    // MARK: - 播放按钮事件

    @objc private func playTapped() {
        guard let msg = message else { return }
        delegate?.cellDidTapPlay(self, message: msg)
    }

    @objc private func bubbleLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let msg = message else { return }
        delegate?.cellDidLongPress(self, message: msg)
    }

    // MARK: - 私有工具

    private func makeThumbImage(size: CGSize, color: UIColor) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            color.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }
    }
}

// MARK: - MessageCellConfigurable

extension VoiceMessageCell: MessageCellConfigurable {

    func configure(with message: ChatMessage, deps: MessageCellDependencies) {
        // 先调基类方法更新时间分隔行、头像和收/发方向
        configureCommon(message: message, showTimeHeader: deps.showTimeHeader)
        // 再更新语音播放状态
        delegate = deps.voiceDelegate
        configure(with: message,
                  isPlaying: deps.isPlaying(message.id),
                  progress: 0,
                  isUnread: !message.isPlayed)
    }
}
