import UIKit
import AVFoundation

/// 输入协调器：处理 ChatInputView 的所有回调逻辑
///
/// # 职责
/// - 管理录音状态机（idle → recording → cancelReady → idle）
/// - 处理长按手势的录音流程（权限请求、录音启动、倒计时、音频电平更新）
/// - 处理扩展功能菜单（相册、拍照、位置等）
/// - 协调录音与播放的互斥（录音前停止播放）
/// - 处理文本消息发送
///
/// # 录音状态机
/// ```
/// .idle ──(长按开始)──> .recording ──(上滑 80pt)──> .cancelReady
///   ↑                      │                           │
///   │                      │ (松手)                    │ (下滑)
///   │                      ↓                           ↓
///   └──────────────────  发送  ←──────────────────  取消
/// ```
///
/// # 长按手势处理
/// - `.began`：请求麦克风权限，启动录音，开始倒计时
/// - `.changed`：检测手指位置，上滑 > 80pt 进入取消状态
/// - `.ended`：根据当前状态决定发送或取消
/// - `.cancelled/.failed`：取消录音
///
/// # 设计考量
/// 将录音相关的所有逻辑从 ViewController 中提取出来，通过回调与 ViewController 通信。
/// ViewController 只需在初始化时设置回调，无需关心录音状态机的具体实现。
@MainActor
final class InputCoordinator {

    // MARK: - Dependencies

    weak var viewController: UIViewController?
    private let recorder: VoiceRecordManager
    private let player: VoicePlaybackManager

    // MARK: - Recording State

    /// 录音状态
    private enum RecordState {
        case idle         // 空闲状态
        case recording    // 正常录音中
        case cancelReady  // 上滑进入取消状态
    }
    private var recordState: RecordState = .idle

    private var touchStartY: CGFloat = 0       // 长按开始时的 Y 坐标
    private var countdownTimer: Timer?          // 1 秒倒计时 Timer
    private var audioLevelTimer: Timer?         // 50ms 音频电平更新 Timer
    private var elapsedSeconds = 0              // 已录制秒数
    private var isGestureActive = false         // 长按手势是否仍处于激活状态

    private let cancelThreshold: CGFloat = 80   // 上滑取消阈值（80pt）
    private let maxRecordSeconds = 30           // 最长录音时长（30 秒）

    // MARK: - UI References

    private weak var chatInputView: ChatInputView?
    private let overlayVC = RecordingOverlayViewController()

    // MARK: - Callbacks

    /// 发送文本消息回调
    var onSendText: ((String) -> Void)?
    /// 发送语音消息回调（参数：URL, 时长）
    var onSendVoice: ((URL, TimeInterval) -> Void)?
    /// 发送图片消息回调（参数：URL）
    var onSendImage: ((URL) -> Void)?
    /// 发送视频消息回调（参数：URL, 时长）
    var onSendVideo: ((URL, TimeInterval) -> Void)?
    /// Toast 显示回调
    var showToast: ((String) -> Void)?

    // MARK: - Init

    init(recorder: VoiceRecordManager = .shared,
         player: VoicePlaybackManager = .shared) {
        self.recorder = recorder
        self.player = player
    }

    // MARK: - Setup

    /// 设置输入视图并绑定回调
    ///
    /// 将 ChatInputView 的所有回调绑定到 InputCoordinator 的处理方法。
    /// ViewController 只需调用此方法一次即可完成所有输入相关的配置。
    ///
    /// - Parameter inputView: ChatInputView 实例
    func setup(with inputView: ChatInputView) {
        self.chatInputView = inputView

        inputView.onSend = { [weak self] text in
            self?.handleSendText(text)
        }

        inputView.onLongPress = { [weak self] gesture in
            self?.handleLongPress(gesture)
        }

        inputView.onExtensionTap = { [weak self] in
            self?.handleExtensionTap()
        }

        // 设置扩展功能菜单提供者
        inputView.extensionMenuProvider = { [weak self] in
            self?.buildExtensionMenu()
        }
    }

    // MARK: - Text Input

    private func handleSendText(_ text: String) {
        onSendText?(text)
    }

    // MARK: - Extension Menu

    /// 构建扩展功能菜单
    ///
    /// 使用 UIMenu 提供以下功能：
    /// - 相册：调用 PhotoPickerManager 选择图片/视频
    /// - 拍照：开发中
    /// - 位置：开发中
    private func buildExtensionMenu() -> UIMenu {
        let photoAction = UIAction(title: "相册", image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in
            self?.openPhotoPicker()
        }

        let cameraAction = UIAction(title: "拍照", image: UIImage(systemName: "camera")) { [weak self] _ in
            self?.showToast?("拍照功能开发中")
        }

        let locationAction = UIAction(title: "位置", image: UIImage(systemName: "location")) { [weak self] _ in
            self?.showToast?("位置功能开发中")
        }

        return UIMenu(children: [photoAction, cameraAction, locationAction])
    }

    /// 处理扩展功能按钮点击（保留以兼容旧代码）
    ///
    /// 显示 UIAlertController 菜单，提供以下功能：
    /// - 相册：调用 PhotoPickerManager 选择图片/视频
    /// - 拍照：开发中
    /// - 位置：开发中
    private func handleExtensionTap() {
        let alert = UIAlertController(title: "扩展功能", message: "选择一个功能", preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: "相册", style: .default) { [weak self] _ in
            self?.openPhotoPicker()
        })

        alert.addAction(UIAlertAction(title: "拍照", style: .default) { [weak self] _ in
            self?.showToast?("拍照功能开发中")
        })

        alert.addAction(UIAlertAction(title: "位置", style: .default) { [weak self] _ in
            self?.showToast?("位置功能开发中")
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))

        viewController?.present(alert, animated: true)
    }

    /// 打开系统相册选择器
    ///
    /// 使用 PhotoPickerManager 的 async/await API 选择图片或视频。
    /// 选择完成后通过回调通知 ViewController 发送消息。
    private func openPhotoPicker() {
        guard let vc = viewController else { return }
        Task { @MainActor in
            do {
                guard let result = try await PhotoPickerManager.shared.pickMedia(from: vc) else {
                    return  // 用户取消
                }

                switch result {
                case .image(let url):
                    self.onSendImage?(url)
                case .video(let url, let duration):
                    self.onSendVideo?(url, duration)
                }
            } catch {
                self.showToast?("加载失败")
            }
        }
    }

    // MARK: - Voice Recording

    /// 处理长按手势
    ///
    /// 根据手势状态执行不同操作：
    /// - `.began`：标记手势激活，记录起始位置，开始录音
    /// - `.changed`：检测手指位置，上滑 > 80pt 进入取消状态，下滑恢复正常录音
    /// - `.ended`：根据当前状态决定发送或取消
    /// - `.cancelled/.failed`：取消录音
    private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {

        case .began:
            isGestureActive = true
            touchStartY = gesture.location(in: viewController?.view ?? UIView()).y
            beginRecording()

        case .changed:
            guard recordState != .idle else { return }
            let deltaY = touchStartY - gesture.location(in: viewController?.view ?? UIView()).y
            if deltaY > cancelThreshold {
                if recordState != .cancelReady { enterCancelReady() }
            } else {
                if recordState == .cancelReady { enterNormalRecording() }
            }

        case .ended:
            isGestureActive = false
            switch recordState {
            case .idle:        break
            case .recording:   finishAndSend()
            case .cancelReady: cancelAndDiscard()
            }

        case .cancelled, .failed:
            isGestureActive = false
            cancelAndDiscard()

        default:
            break
        }
    }

    /// 开始录音
    ///
    /// 流程：
    /// 1. 请求麦克风权限（异步）
    /// 2. 检查权限弹窗期间用户是否已松手（isGestureActive）
    /// 3. 停止当前播放（避免录音与播放冲突）
    /// 4. 启动 AVAudioRecorder
    /// 5. 显示录音浮层
    /// 6. 开始倒计时和音频电平更新
    private func beginRecording() {
        guard !recorder.isRecording else { return }

        Task { @MainActor in
            let granted = await self.recorder.requestPermission()
            guard granted else {
                self.showToast?("请在设置中开启麦克风权限")
                return
            }
            // 权限弹窗期间用户已松手，不启动录音
            guard self.isGestureActive else { return }
            // 录音开始前停止当前播放
            self.player.stopCurrent()
            do {
                _ = try self.recorder.startRecording()
                self.recordState = .recording
                self.elapsedSeconds = 0
                self.showOverlay()
                self.updateVoiceButton()
                self.startCountdown()
            } catch {
                self.showToast?("录音启动失败")
            }
        }
    }

    /// 启动倒计时 Timer
    ///
    /// 每秒更新一次录音时长，到达 30 秒上限时自动发送。
    /// 同时启动音频电平更新 Timer（50ms 间隔）。
    private func startCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.recordState != .idle else { return }
                self.elapsedSeconds += 1
                self.overlayVC.updateSeconds(self.elapsedSeconds)
                if self.elapsedSeconds >= self.maxRecordSeconds {
                    self.finishAndSend()
                }
            }
        }
        startAudioLevelUpdates()
    }

    private func stopCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        stopAudioLevelUpdates()
    }

    /// 启动音频电平更新 Timer
    ///
    /// 每 50ms 从 VoiceRecordManager 读取归一化电平值（0.0-1.0），
    /// 更新录音浮层的波形动画。
    private func startAudioLevelUpdates() {
        audioLevelTimer?.invalidate()

        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.recordState != .idle else { return }
                self.overlayVC.updateAudioLevel(self.recorder.normalizedPowerLevel)
            }
        }
        audioLevelTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopAudioLevelUpdates() {
        audioLevelTimer?.invalidate()
        audioLevelTimer = nil
    }

    /// 完成录音并发送
    ///
    /// 流程：
    /// 1. 停止倒计时和音频电平更新
    /// 2. 钳制录音时长到 30 秒上限（AVAudioRecorder.currentTime 可能略超）
    /// 3. 停止录音并获取文件 URL
    /// 4. 检查时长是否 < 1 秒（太短则删除文件并提示）
    /// 5. 通过回调发送语音消息
    /// 6. 重置状态到 idle
    private func finishAndSend() {
        stopCountdown()
        // AVAudioRecorder.currentTime 在到达上限附近可能略超 30（如 30.01）；
        // 这里做上限钳制，避免列表向上取整后显示 31"。
        let actualDuration = min(recorder.currentTime, TimeInterval(maxRecordSeconds))
        guard let url = recorder.stopRecording() else { resetToIdle(); return }
        if actualDuration < 1.0 {
            try? FileManager.default.removeItem(at: url)
            resetToIdle()
            showToast?("说话时间太短")
            return
        }
        onSendVoice?(url, actualDuration)
        resetToIdle()
    }

    /// 取消录音并丢弃
    private func cancelAndDiscard() {
        stopCountdown()
        recorder.cancelRecording()
        resetToIdle()
    }

    /// 进入取消状态
    ///
    /// 更新录音浮层和"按住说话"按钮的外观。
    private func enterCancelReady() {
        recordState = .cancelReady
        overlayVC.setState(.cancelReady)
        updateVoiceButton()
    }

    /// 恢复正常录音状态
    ///
    /// 从取消状态下滑回来时调用。
    private func enterNormalRecording() {
        recordState = .recording
        overlayVC.setState(.recording)
        updateVoiceButton()
    }

    /// 重置到空闲状态
    ///
    /// 隐藏录音浮层，恢复"按住说话"按钮外观，启用文字输入。
    private func resetToIdle() {
        recordState = .idle
        hideOverlay()
        updateVoiceButton()
        chatInputView?.setTextInputEnabled(true)
    }

    // MARK: - UI Updates

    /// 显示录音浮层
    ///
    /// 录音期间禁用文字输入（语音模式下 textView 已隐藏，调用无副作用）。
    private func showOverlay() {
        chatInputView?.setTextInputEnabled(false)
        overlayVC.setState(.recording)
        overlayVC.updateSeconds(0)
        overlayVC.updateAudioLevel(0)
        viewController?.present(overlayVC, animated: true)
    }

    private func hideOverlay() {
        overlayVC.dismiss(animated: true)
    }

    /// 根据录音状态更新"按住说话"按钮外观
    ///
    /// - idle：白色背景 + 灰色边框 + "按住说话"
    /// - recording：蓝色半透明背景 + 蓝色边框 + "松开 发送"
    /// - cancelReady：红色半透明背景 + 红色边框 + "松开 取消"
    private func updateVoiceButton() {
        switch recordState {
        case .idle:
            chatInputView?.updateVoiceButton(
                title: "按住说话",
                backgroundColor: .systemBackground,
                borderColor: UIColor.separator.cgColor)
        case .recording:
            chatInputView?.updateVoiceButton(
                title: "松开 发送",
                backgroundColor: UIColor.systemBlue.withAlphaComponent(0.08),
                borderColor: UIColor.systemBlue.cgColor)
        case .cancelReady:
            chatInputView?.updateVoiceButton(
                title: "松开 取消",
                backgroundColor: UIColor.systemRed.withAlphaComponent(0.08),
                borderColor: UIColor.systemRed.cgColor)
        }
    }

    // MARK: - Public Methods

    /// 填充文本到输入框（用于撤回消息重新编辑）
    ///
    /// 流程：
    /// 1. 切换到文字输入模式
    /// 2. 填充文本到输入框
    /// 3. 聚焦输入框（弹出键盘）
    func setText(_ text: String) {
        chatInputView?.switchToTextMode()
        chatInputView?.setText(text)
        chatInputView?.focusTextInput()
    }
}
