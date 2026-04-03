import UIKit

/// 聊天输入栏（文字模式 / 语音模式）
///
/// # 通信方式
/// 不使用 delegate，通过闭包向外暴露事件，ViewController 按需注入：
/// - `onSend`：用户点击发送或 return 键，携带文本内容
/// - `onLongPress`：长按"按住说话"按钮，将手势对象透传给 ViewController 处理录音逻辑
/// - `onHeightChange`：输入栏高度变化后通知 ViewController 滚动列表，防止消息被遮挡
///
/// # 外部调用接口
/// - `updateVoiceButton(title:backgroundColor:borderColor:)`：ViewController 根据录音状态更新按钮外观
/// - `setTextInputEnabled(_:)`：录音期间禁用文字输入
@MainActor
final class ChatInputView: UIView {

    // MARK: - 回调

    var onSend: ((String) -> Void)?
    /// 长按手势透传给 ViewController，由其负责录音状态机；
    /// ChatInputView 不持有录音逻辑，保持职责单一
    var onLongPress: ((UILongPressGestureRecognizer) -> Void)?
    /// 输入栏高度发生变化时回调（动画结束后触发）
    /// 注意：回调在动画 completion 里执行，此时 collectionView 已完成重新布局，
    /// scrollToItem 才能拿到正确的目标位置；若在动画开始前调用会定位偏移
    var onHeightChange: (() -> Void)?
    /// 扩展功能按钮点击回调（类似 iMessage 的 + 按钮）
    var onExtensionTap: (() -> Void)?

    // MARK: - 子视图

    /// 左侧扩展功能按钮（类似 iMessage 的 + 按钮）
    private let extensionButton = UIButton(type: .system)
    private let textView         = UITextView()
    private let placeholderLabel = UILabel()
    private let sendButton       = UIButton(type: .system)
    /// 切换按钮：文字模式显示 mic.fill，语音模式显示 keyboard
    private let toggleButton     = UIButton(type: .system)
    /// 语音模式下的"按住说话"按钮，替换 textView + sendButton；
    /// internal 级别供 ViewController 在 updateVoiceButton 中访问其外观属性
    let voiceInputButton         = UIButton(type: .system)

    // MARK: - 内部状态

    private enum InputMode { case text, voice }
    /// 注意：inputMode 仅在 ChatInputView 内部管理，外部通过 setTextInputEnabled / updateVoiceButton
    /// 等接口影响状态，不直接读写 inputMode，保持封装性
    private var inputMode: InputMode = .text

    /// textView 高度约束，由 textViewDidChange 动态更新，上限 120pt（约 5 行）；
    /// 注意：必须持有强引用，否则从 AutoLayout 引擎取出后为 nil
    private var textViewHeightConstraint: NSLayoutConstraint!
    /// textView 的 top/bottom 约束，语音模式下停用以避免撑开 ChatInputView
    private var textViewTopConstraint: NSLayoutConstraint!
    private var textViewBottomConstraint: NSLayoutConstraint!
    /// voiceInputButton 的 top/bottom 约束，文字模式下停用
    private var voiceTopConstraint: NSLayoutConstraint!
    private var voiceBottomConstraint: NSLayoutConstraint!
    private var voiceHeightConstraint: NSLayoutConstraint!
    /// toggleButton 的 trailing 约束：文字模式相对于 sendButton，语音模式相对于父视图
    private var toggleTrailingToSendButton: NSLayoutConstraint!
    private var toggleTrailingToSuperview: NSLayoutConstraint!
    /// 上次 layout 时 textView 的宽度，用于检测旋转引起的宽度变化
    private var lastLayoutWidth: CGFloat = 0

    // MARK: - 初始化

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 旋转适配
    //
    // 旋转时 textView 宽度变化，同样数量的文字在新宽度下所需行数不同，
    // textViewHeightConstraint 的旧值不再准确，需重新计算。
    // 使用 layoutSubviews + lastLayoutWidth 检测宽度变化，避免每次 layout 都重算。
    // 不加动画：旋转本身已有系统动画上下文，强加动画反而会造成跳变。

    override func layoutSubviews() {
        super.layoutSubviews()
        let newWidth = textView.bounds.width
        guard newWidth > 0, abs(newWidth - lastLayoutWidth) > 1 else { return }
        lastLayoutWidth = newWidth
        recalculateTextViewHeight()
    }

    private func recalculateTextViewHeight() {
        let maxHeight: CGFloat = 120
        let fitSize = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .infinity))
        let newHeight = min(fitSize.height, maxHeight)
        textView.isScrollEnabled = fitSize.height > maxHeight
        guard textViewHeightConstraint.constant != newHeight else { return }
        textViewHeightConstraint.constant = newHeight
        // layoutIfNeeded 在旋转动画上下文内执行，高度变化会随旋转一起动画
        layoutIfNeeded()
        onHeightChange?()
    }

    // MARK: - UI 搭建

    private func setupUI() {
        backgroundColor = .secondarySystemBackground

        // ── 扩展功能按钮（左下角固定，类似 iMessage 的 + 按钮）──────────────
        extensionButton.setImage(UIImage(systemName: "plus.circle.fill"), for: .normal)
        extensionButton.tintColor = .systemBlue
        extensionButton.translatesAutoresizingMaskIntoConstraints = false
        extensionButton.addTarget(self, action: #selector(extensionTapped), for: .touchUpInside)
        addSubview(extensionButton)

        NSLayoutConstraint.activate([
            extensionButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            extensionButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            extensionButton.widthAnchor.constraint(equalToConstant: 32),
            extensionButton.heightAnchor.constraint(equalToConstant: 32),
        ])

        // ── 发送按钮（右下角固定）──────────────────────────────────────────────
        sendButton.setTitle("发送", for: .normal)
        sendButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        sendButton.isEnabled = false
        sendButton.alpha = 0.4
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        sendButton.setContentHuggingPriority(.required, for: .horizontal)
        sendButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(sendButton)

        NSLayoutConstraint.activate([
            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            sendButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])

        // ── 切换按钮（发送按钮左侧）──────────────────────────────────────────────
        // 文字模式：mic.fill；语音模式：keyboard
        // 约束：文字模式时相对于 sendButton，语音模式时相对于父视图右边
        toggleButton.setImage(UIImage(systemName: "mic.fill"), for: .normal)
        toggleButton.tintColor = .systemBlue
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        toggleButton.addTarget(self, action: #selector(toggleInputMode), for: .touchUpInside)
        addSubview(toggleButton)

        // 两套 trailing 约束：文字模式用第一个，语音模式用第二个
        toggleTrailingToSendButton = toggleButton.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -8)
        toggleTrailingToSuperview = toggleButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)

        NSLayoutConstraint.activate([
            toggleTrailingToSendButton,  // 初始为文字模式，激活相对于 sendButton 的约束
            toggleButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            toggleButton.widthAnchor.constraint(equalToConstant: 32),
            toggleButton.heightAnchor.constraint(equalToConstant: 32),
        ])

        // ── 文字模式：textView + placeholderLabel + sendButton ────────────────
        // UITextView 无内建 placeholder，用叠加的 placeholderLabel 模拟；
        // placeholderLabel.isUserInteractionEnabled = false 保证触摸事件穿透到 textView
        textView.font = .systemFont(ofSize: 16)
        textView.layer.cornerRadius = 8
        textView.layer.borderWidth = 1
        textView.layer.borderColor = UIColor.separator.cgColor
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        // isScrollEnabled 初始为 false：高度随内容增长，由 textViewHeightConstraint 控制；
        // 超过 120pt 上限后切换为 true，改为内部滚动
        textView.isScrollEnabled = false
        textView.returnKeyType = .send
        textView.delegate = self
        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)

        placeholderLabel.text = "输入消息"
        placeholderLabel.font = textView.font
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.isUserInteractionEnabled = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(placeholderLabel)

        // textView 的 top/bottom 同时约束到 ChatInputView，负责撑开整体高度；
        // textViewHeightConstraint 控制单行到多行的增长，与 top/bottom 共同作用
        textViewHeightConstraint = textView.heightAnchor.constraint(equalToConstant: 36)
        textViewTopConstraint = textView.topAnchor.constraint(equalTo: topAnchor, constant: 10)
        textViewBottomConstraint = textView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)

        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: extensionButton.trailingAnchor, constant: 8),
            textViewTopConstraint,
            textViewBottomConstraint,
            textViewHeightConstraint,

            // placeholder 与 textView 文字起点对齐（inset + textContainer 偏移）
            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor,
                                                   constant: textView.textContainerInset.top),
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor,
                                                       constant: textView.textContainerInset.left + 4),

            textView.trailingAnchor.constraint(equalTo: toggleButton.leadingAnchor, constant: -8),
        ])

        // ── 语音模式："按住说话"按钮（初始隐藏）────────────────────────────
        // voiceInputButton 与 textView+sendButton 占据同一区域，通过 isHidden 互斥切换；
        // 两者同时存在于视图层级中，约束始终激活，不会产生约束冲突
        voiceInputButton.setTitle("按住说话", for: .normal)
        voiceInputButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        voiceInputButton.backgroundColor = .systemBackground
        voiceInputButton.setTitleColor(.label, for: .normal)
        voiceInputButton.layer.cornerRadius = 8
        voiceInputButton.layer.borderWidth = 1
        voiceInputButton.layer.borderColor = UIColor.separator.cgColor
        voiceInputButton.isHidden = true
        voiceInputButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(voiceInputButton)

        voiceTopConstraint = voiceInputButton.topAnchor.constraint(equalTo: topAnchor, constant: 10)
        voiceBottomConstraint = voiceInputButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        voiceHeightConstraint = voiceInputButton.heightAnchor.constraint(equalToConstant: 36)

        // 语音模式的 top/bottom/height 初始不激活，切换时再启用
        NSLayoutConstraint.activate([
            voiceInputButton.leadingAnchor.constraint(equalTo: extensionButton.trailingAnchor, constant: 8),
            voiceInputButton.trailingAnchor.constraint(equalTo: toggleButton.leadingAnchor, constant: -8),
        ])

        // 长按手势绑定在 voiceInputButton；
        // allowableMovement = 2000 保证手指上滑取消时手势不会被系统提前取消
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        lp.minimumPressDuration = 0.3
        lp.allowableMovement = 2000
        voiceInputButton.addGestureRecognizer(lp)
    }

    // MARK: - 输入模式切换

    @objc private func toggleInputMode() {
        switch inputMode {
        case .text:
            // 文字 → 语音：收起键盘，停用 textView 约束，启用 voiceInputButton 约束
            textView.resignFirstResponder()
            inputMode = .voice
            textView.isHidden = true
            sendButton.isHidden = true
            textViewTopConstraint.isActive = false
            textViewBottomConstraint.isActive = false
            voiceTopConstraint.isActive = true
            voiceBottomConstraint.isActive = true
            voiceHeightConstraint.isActive = true
            voiceInputButton.isHidden = false
            // 切换 toggleButton 约束：停用相对于 sendButton，启用相对于父视图
            toggleTrailingToSendButton.isActive = false
            toggleTrailingToSuperview.isActive = true
            toggleButton.setImage(UIImage(systemName: "keyboard"), for: .normal)
            UIView.animate(withDuration: 0.15) {
                self.layoutIfNeeded()
            } completion: { _ in
                self.onHeightChange?()
            }
        case .voice:
            // 语音 → 文字：停用 voiceInputButton 约束，启用 textView 约束
            inputMode = .text
            voiceInputButton.isHidden = true
            voiceTopConstraint.isActive = false
            voiceBottomConstraint.isActive = false
            voiceHeightConstraint.isActive = false
            textViewTopConstraint.isActive = true
            textViewBottomConstraint.isActive = true
            textView.isHidden = false
            sendButton.isHidden = false
            // 切换 toggleButton 约束：停用相对于父视图，启用相对于 sendButton
            toggleTrailingToSuperview.isActive = false
            toggleTrailingToSendButton.isActive = true
            toggleButton.setImage(UIImage(systemName: "mic.fill"), for: .normal)
            textView.becomeFirstResponder()
            UIView.animate(withDuration: 0.15) {
                self.layoutIfNeeded()
            } completion: { _ in
                self.onHeightChange?()
            }
        }
    }

    // MARK: - 发送

    @objc private func sendTapped() {
        let content = textView.text.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return }
        textView.text = nil
        // 清空 text 后 textViewDidChange 不会自动触发，需手动调用一次，
        // 以同步重置高度约束和 placeholder 显示状态
        textViewDidChange(textView)
        onSend?(content)
    }

    private func updateSendButton() {
        let hasText = !textView.text.trimmingCharacters(in: .whitespaces).isEmpty
        sendButton.isEnabled = hasText
        sendButton.alpha = hasText ? 1 : 0.4
    }

    // MARK: - 长按手势透传

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        onLongPress?(gesture)
    }

    // MARK: - 扩展功能按钮

    @objc private func extensionTapped() {
        onExtensionTap?()
    }

    // MARK: - 外部接口

    /// ViewController 根据录音状态（idle / recording / cancelReady）调用此方法更新按钮外观；
    /// 语音模式下 voiceInputButton 可见时调用才有视觉效果，文字模式下调用无副作用
    func updateVoiceButton(title: String, backgroundColor: UIColor, borderColor: CGColor) {
        voiceInputButton.setTitle(title, for: .normal)
        voiceInputButton.backgroundColor = backgroundColor
        voiceInputButton.layer.borderColor = borderColor
    }

    /// 录音期间禁用文字输入，录音结束后恢复；
    /// 语音模式下 textView 已隐藏，isEditable 变化不影响 UI，调用无副作用
    func setTextInputEnabled(_ enabled: Bool) {
        textView.isEditable = enabled
    }

    /// 切换到文字输入模式（用于撤回消息重新编辑）
    func switchToTextMode() {
        guard inputMode == .voice else { return }
        toggleInputMode()
    }

    /// 设置输入框文本（用于撤回消息重新编辑）
    func setText(_ text: String) {
        textView.text = text
        textViewDidChange(textView)
    }

    /// 聚焦输入框（用于撤回消息重新编辑）
    func focusTextInput() {
        textView.becomeFirstResponder()
    }
}

// MARK: - UITextViewDelegate

extension ChatInputView: UITextViewDelegate {

    func textView(_ textView: UITextView,
                  shouldChangeTextIn range: NSRange,
                  replacementText text: String) -> Bool {
        // 回车键（returnKeyType = .send）拦截为发送，不插入换行
        if text == "\n" {
            sendTapped()
            return false
        }
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        // placeholder 有文字时隐藏
        placeholderLabel.isHidden = !textView.text.isEmpty
        updateSendButton()

        // 动态调整高度，上限 120pt（约 5 行）；超出后切换为内部滚动
        // 注意：sizeThatFits 必须传入当前实际宽度，传 .greatestFiniteMagnitude 会导致高度计算偏低
        let maxHeight: CGFloat = 120
        let fitSize = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .infinity))
        let newHeight = min(fitSize.height, maxHeight)
        textView.isScrollEnabled = fitSize.height > maxHeight
        if textViewHeightConstraint.constant != newHeight {
            textViewHeightConstraint.constant = newHeight
            // 注意：onHeightChange 在动画 completion 里触发，
            // 此时父视图布局已完成，ViewController 的 scrollToItem 才能定位准确
            UIView.animate(withDuration: 0.15) {
                self.layoutIfNeeded()
            } completion: { _ in
                self.onHeightChange?()
            }
        }
    }
}
