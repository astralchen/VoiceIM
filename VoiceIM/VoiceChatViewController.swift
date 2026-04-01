import UIKit
import AVFoundation

/// IM 聊天页面（支持语音消息与文本消息）
final class VoiceChatViewController: UIViewController {

    // MARK: - 常量

    private let cancelThreshold: CGFloat = 80
    private let maxRecordSeconds = 30

    // MARK: - Section

    private enum Section { case main }

    // MARK: - UI

    private var collectionView: UICollectionView!
    private let chatInputView = ChatInputView()
    private let overlayView   = RecordingOverlayView()
    private var inputViewBottomConstraint: NSLayoutConstraint!

    // MARK: - DiffableDataSource

    private var dataSource: UICollectionViewDiffableDataSource<Section, ChatMessage>!

    // MARK: - 录音状态

    private enum RecordState { case idle, recording, cancelReady }
    private var recordState: RecordState = .idle

    private var touchStartY: CGFloat = 0
    private var countdownTimer: Timer?
    private var elapsedSeconds = 0
    /// 长按手势是否仍处于激活状态（.began → true，.ended/.cancelled/.failed → false）
    /// 用于检测：权限弹窗期间用户已松手，授权回调返回后不应启动录音
    private var isGestureActive = false

    // MARK: - 消息数据
    //
    // 独立维护 messages 数组的原因：
    //   DiffableDataSource 内部 snapshot 存储的是插入时的 item 副本，
    //   后续对 isPlayed 的修改不会同步到 snapshot 内的 item。
    //   使用 reloadItems（方案 B）触发 cell provider 重新执行时，
    //   cell provider 收到的参数仍是 snapshot 内的旧 item（isPlayed: false），
    //   因此必须有 messages 数组作为可变状态的真实来源，供 cell provider 查询。
    //
    //   升级到 iOS 15 并改用 reconfigureItems（方案 C）后，
    //   可通过 insertItems + deleteItems 将新 item 写入 snapshot，
    //   届时 cell provider 直接从新 item 读取状态，messages 数组可移除。

    private var messages: [ChatMessage] = []

    // MARK: - 管理器（单例引用）

    private let recorder = VoiceRecordManager.shared
    private let player   = VoicePlaybackManager.shared

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "消息"
        view.backgroundColor = .systemBackground
        setupCollectionView()
        setupInputView()
        setupOverlay()
        setupPlaybackCallbacks()
        setupKeyboardObservers()
        insertMockMessages()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !messages.isEmpty else { return }
        // viewDidLoad 时 AutoLayout 尚未完成首次布局，cell 未渲染，scrollToItem 无效。
        // viewDidAppear 时布局已稳定，animated: false 避免页面刚出现就触发滚动动画。
        collectionView.scrollToItem(
            at: IndexPath(item: messages.count - 1, section: 0),
            at: .bottom, animated: false)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // 初始化时将输入栏底部紧贴安全区域底部
        inputViewBottomConstraint.constant = -view.safeAreaInsets.bottom
    }

    override func viewWillTransition(to size: CGSize,
                                     with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        // 旋转时 collectionView 宽度变化，cell 高度重新计算，内容总高度随之改变；
        // 即使 ChatInputView 高度不变，底部消息也可能因滚动位置未更新而被遮挡。
        // 在旋转动画结束后滚动到最后一条消息，保证内容始终可见。
        guard !messages.isEmpty else { return }
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self else { return }
            collectionView.scrollToItem(
                at: IndexPath(item: messages.count - 1, section: 0),
                at: .bottom, animated: false)
        }
    }

    // MARK: - UI 搭建

    private func setupCollectionView() {
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.backgroundColor = .systemBackground
        collectionView.keyboardDismissMode = .onDrag
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.register(VoiceMessageCell.self,
                                forCellWithReuseIdentifier: VoiceMessageCell.reuseID)
        collectionView.register(TextMessageCell.self,
                                forCellWithReuseIdentifier: TextMessageCell.reuseID)
        view.addSubview(collectionView)

        // DiffableDataSource
        dataSource = UICollectionViewDiffableDataSource<Section, ChatMessage>(
            collectionView: collectionView
        ) { [weak self] cv, indexPath, message in
            guard let self else { return UICollectionViewCell() }
            let current = self.messages.first(where: { $0.id == message.id }) ?? message

            switch current.kind {
            case .voice:
                let cell = cv.dequeueReusableCell(
                    withReuseIdentifier: VoiceMessageCell.reuseID,
                    for: indexPath) as! VoiceMessageCell    // swiftlint:disable:this force_cast
                // 从 messages 数组取最新状态，保证 isPlayed 始终准确
                cell.configure(with: current,
                               isPlaying: self.player.isPlaying(id: current.id),
                               progress: 0,
                               isUnread: !current.isPlayed)
                cell.delegate = self
                return cell

            case .text:
                let cell = cv.dequeueReusableCell(
                    withReuseIdentifier: TextMessageCell.reuseID,
                    for: indexPath) as! TextMessageCell    // swiftlint:disable:this force_cast
                cell.configure(with: current)
                return cell
            }
        }

        // 初始化空 snapshot
        var snapshot = NSDiffableDataSourceSnapshot<Section, ChatMessage>()
        snapshot.appendSections([.main])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// iOS 13 CompositionalLayout：单列、自适应高度，模拟 TableView list 样式
    private func makeLayout() -> UICollectionViewLayout {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .estimated(62))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)

        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .estimated(62))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: groupSize, subitems: [item])

        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(
            top: 8, leading: 0, bottom: 8, trailing: 0)

        return UICollectionViewCompositionalLayout(section: section)
    }

    private func setupInputView() {
        chatInputView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(chatInputView)

        inputViewBottomConstraint = chatInputView.bottomAnchor.constraint(equalTo: view.bottomAnchor)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: chatInputView.topAnchor),

            chatInputView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chatInputView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inputViewBottomConstraint,
        ])

        // 用户发送文本
        chatInputView.onSend = { [weak self] text in
            self?.appendMessage(.text(text))
        }

        // 长按"按住说话"手势透传给 ViewController 处理录音状态机
        chatInputView.onLongPress = { [weak self] gesture in
            self?.handleLongPress(gesture)
        }

        // 输入栏增高后，若用户在底部附近则滚动列表，防止消息被遮挡
        chatInputView.onHeightChange = { [weak self] in
            guard let self, isNearBottom, !messages.isEmpty else { return }
            collectionView.scrollToItem(
                at: IndexPath(item: messages.count - 1, section: 0),
                at: .bottom, animated: true)
        }
    }

    private func setupOverlay() {
        overlayView.isHidden = true
        overlayView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlayView)

        NSLayoutConstraint.activate([
            overlayView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            overlayView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            overlayView.widthAnchor.constraint(equalToConstant: 165),
        ])
    }

    private func setupPlaybackCallbacks() {
        player.onProgress = { [weak self] id, progress in
            self?.cellForMessage(id: id)?.applyPlayState(isPlaying: true, progress: progress)
        }
        player.onStop = { [weak self] id in
            self?.cellForMessage(id: id)?.applyPlayState(isPlaying: false, progress: 0)
        }
    }

    // MARK: - 长按手势处理

    private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {

        case .began:
            isGestureActive = true
            touchStartY = gesture.location(in: view).y
            beginRecording()

        case .changed:
            guard recordState != .idle else { return }
            let deltaY = touchStartY - gesture.location(in: view).y
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

    // MARK: - 录音流程

    private func beginRecording() {
        guard !recorder.isRecording else { return }

        Task { @MainActor in
            let granted = await self.recorder.requestPermission()
            guard granted else {
                ToastView.show("请在设置中开启麦克风权限", in: self.view)
                return
            }
            // 权限弹窗期间用户已松手，不启动录音
            guard self.isGestureActive else { return }
            // 录音开始前停止当前播放，避免录音与播放同时进行
            self.player.stopCurrent()
            do {
                _ = try self.recorder.startRecording()
                self.recordState = .recording
                self.elapsedSeconds = 0
                self.showOverlay()
                self.updateVoiceButton()
                self.startCountdown()
            } catch {
                ToastView.show("录音启动失败", in: self.view)
            }
        }
    }

    private func startCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.recordState != .idle else { return }
                self.elapsedSeconds += 1
                self.overlayView.updateSeconds(self.elapsedSeconds)
                if self.elapsedSeconds >= self.maxRecordSeconds {
                    self.finishAndSend()
                }
            }
        }
    }

    private func stopCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    private func finishAndSend() {
        stopCountdown()
        let actualDuration = recorder.currentTime
        guard let url = recorder.stopRecording() else { resetToIdle(); return }
        if actualDuration < 1.0 {
            try? FileManager.default.removeItem(at: url)
            resetToIdle()
            ToastView.show("说话时间太短", in: view)
            return
        }
        appendMessage(.voice(localURL: url, duration: actualDuration))
        resetToIdle()
    }

    private func cancelAndDiscard() {
        stopCountdown()
        recorder.cancelRecording()
        resetToIdle()
    }

    private func enterCancelReady() {
        recordState = .cancelReady
        overlayView.setState(.cancelReady)
        updateVoiceButton()
    }

    private func enterNormalRecording() {
        recordState = .recording
        overlayView.setState(.recording)
        updateVoiceButton()
    }

    private func resetToIdle() {
        recordState = .idle
        hideOverlay()
        updateVoiceButton()
        chatInputView.setTextInputEnabled(true)
    }

    // MARK: - UI 更新

    private func showOverlay() {
        // 录音期间禁用文字输入（语音模式下 textView 已隐藏，setTextInputEnabled 调用无副作用）
        chatInputView.setTextInputEnabled(false)
        overlayView.setState(.recording)
        overlayView.updateSeconds(0)
        overlayView.isHidden = false
        overlayView.alpha = 0
        UIView.animate(withDuration: 0.2) { self.overlayView.alpha = 1 }
    }

    private func hideOverlay() {
        UIView.animate(withDuration: 0.2) {
            self.overlayView.alpha = 0
        } completion: { _ in
            self.overlayView.isHidden = true
        }
    }

    /// 根据录音状态更新"按住说话"按钮外观
    private func updateVoiceButton() {
        switch recordState {
        case .idle:
            chatInputView.updateVoiceButton(
                title: "按住说话",
                backgroundColor: .systemBackground,
                borderColor: UIColor.separator.cgColor)
        case .recording:
            chatInputView.updateVoiceButton(
                title: "松开 发送",
                backgroundColor: UIColor.systemBlue.withAlphaComponent(0.08),
                borderColor: UIColor.systemBlue.cgColor)
        case .cancelReady:
            chatInputView.updateVoiceButton(
                title: "松开 取消",
                backgroundColor: UIColor.systemRed.withAlphaComponent(0.08),
                borderColor: UIColor.systemRed.cgColor)
        }
    }

    // MARK: - 消息列表

    private func appendMessage(_ message: ChatMessage) {
        let shouldScroll = isNearBottom

        messages.append(message)

        var snapshot = dataSource.snapshot()
        snapshot.appendItems([message], toSection: .main)
        // animatingDifferences: false 避免插入动画异常，由 scrollToItem 提供视觉反馈
        dataSource.apply(snapshot, animatingDifferences: false)

        // 仅当用户已在底部附近时才滚动；浏览历史消息时保持原位
        if shouldScroll {
            collectionView.scrollToItem(
                at: IndexPath(item: messages.count - 1, section: 0),
                at: .bottom, animated: true)
        }
    }

    /// 将指定消息标记为已播放，触发 cell 红点消失。
    ///
    /// # isPlayed 更新策略对比（完整分析见 ChatMessage.swift Hashable 设计说明）
    ///
    /// ## 方案 A（未采用）：仅 apply 新 snapshot，不调用 reloadItems
    ///   由于 Hashable 仅基于 id，新旧 snapshot 对 DiffableDataSource 而言没有差异，
    ///   apply 不会触发任何 cell 更新，红点不会消失。
    ///   若将 Hashable 改为基于 id + isPlayed 以触发差异感知：
    ///   → DiffableDataSource 认定旧 item 被删除、新 item 被插入，产生闪烁动画。
    ///
    /// ## 方案 B（当前采用，iOS 13+）：messages 数组 + snapshot.reloadItems
    ///   步骤：
    ///     1. messages[idx].isPlayed = true（更新可变状态）
    ///     2. snapshot.reloadItems([messages[idx]])（标记该 item 需重新配置）
    ///     3. dataSource.apply(snapshot, animatingDifferences: false)
    ///     4. cell provider 重新执行，从 messages 数组读到 isPlayed: true
    ///     5. configure(isUnread: false) → cell 内部检测到状态从未读变已读，触发淡出动画
    ///   注意事项：
    ///     - reloadItems 只标记重载，不修改 snapshot 内存储的 item 本身
    ///     - cell provider 收到的参数仍是 snapshot 内的旧 item（isPlayed: false）
    ///     - 必须从 messages 数组查询最新状态，messages 数组不可省略
    ///     - animatingDifferences: false 避免 reloadItems 触发系统默认的 crossfade 动画，
    ///       红点淡出动画由 cell 内部的 configure 方法负责
    ///
    /// ## 方案 C（iOS 15+ 可升级）：insertItems + deleteItems + reconfigureItems
    ///   步骤：
    ///     1. 用 insertItems(afterItem:) + deleteItems 将新 item 写入 snapshot（替换旧值）
    ///     2. reconfigureItems([newItem]) 标记原地重配（非 delete/insert，无闪烁）
    ///     3. apply 后 cell provider 直接收到新 item（isPlayed: true），无需查外部数组
    ///   优势：snapshot 成为唯一数据源，messages 数组可完全移除。
    ///   升级时只需重写本方法，其余代码不变：
    ///
    ///   ```swift
    ///   // iOS 15+ 实现示例（messages 数组可随之移除）
    ///   var snapshot = dataSource.snapshot()
    ///   guard let old = snapshot.itemIdentifiers(inSection: .main)
    ///                           .first(where: { $0.id == id }), !old.isPlayed else { return }
    ///   var updated = old
    ///   updated.isPlayed = true
    ///   snapshot.insertItems([updated], afterItem: old)
    ///   snapshot.deleteItems([old])
    ///   snapshot.reconfigureItems([updated])
    ///   dataSource.apply(snapshot, animatingDifferences: false)
    ///   ```
    private func markAsPlayed(id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }),
              !messages[idx].isPlayed else { return }
        messages[idx].isPlayed = true
        var snapshot = dataSource.snapshot()
        snapshot.reloadItems([messages[idx]])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func deleteMessage(id: UUID) {
        // 正在播放该条消息时先停止，避免播放器持有悬空 URL
        if player.isPlaying(id: id) { player.stopCurrent() }

        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        let message = messages[idx]
        messages.remove(at: idx)

        // 本地录制的临时文件随消息一同删除
        if let url = message.localURL {
            try? FileManager.default.removeItem(at: url)
        }

        var snapshot = dataSource.snapshot()
        snapshot.deleteItems([message])
        dataSource.apply(snapshot, animatingDifferences: true)
    }

    /// 判断当前是否在底部附近（阈值 60pt）
    private var isNearBottom: Bool {
        let cv = collectionView!
        let distanceFromBottom = cv.contentSize.height
            - cv.contentOffset.y
            - cv.bounds.height
            + cv.adjustedContentInset.bottom
        return distanceFromBottom < 60
    }

    // MARK: - 播放逻辑

    private func handlePlayTap(message: ChatMessage) {
        guard recordState == .idle else { return }
        if player.isPlaying(id: message.id) {
            player.stopCurrent()
            return
        }
        markAsPlayed(id: message.id)
        Task { @MainActor in
            do {
                let url = try await self.resolveURL(for: message)
                try self.player.play(id: message.id, url: url)
            } catch {
                ToastView.show("播放失败", in: self.view)
            }
        }
    }

    private func resolveURL(for message: ChatMessage) async throws -> URL {
        if let local = message.localURL   { return local }
        if let remote = message.remoteURL { return try await VoiceCacheManager.shared.resolve(remote) }
        throw URLError(.fileDoesNotExist)
    }

    // MARK: - Cell 查找

    private func cellForMessage(id: UUID) -> VoiceMessageCell? {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return nil }
        return collectionView.cellForItem(at: IndexPath(item: idx, section: 0)) as? VoiceMessageCell
    }
}

// MARK: - VoiceMessageCellDelegate

extension VoiceChatViewController: VoiceMessageCellDelegate {

    func cellDidTapPlay(_ cell: VoiceMessageCell, message: ChatMessage) {
        handlePlayTap(message: message)
    }

    func cellDidSeek(_ cell: VoiceMessageCell, message: ChatMessage, progress: Float) {
        guard player.isPlaying(id: message.id) else { return }
        player.seek(to: progress)
    }

    func cellDidLongPress(_ cell: VoiceMessageCell, message: ChatMessage) {
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            self?.deleteMessage(id: message.id)
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(sheet, animated: true)
    }
}

// MARK: - Mock 数据

extension VoiceChatViewController {

    /// 预填 20 条文本消息，用于开发阶段验证列表滚动、键盘遮挡等交互。
    /// 上线前删除此方法及 viewDidLoad 中的调用即可。
    private func insertMockMessages() {
        let texts = [
            "你好！", "最近怎么样？", "我在学习 Swift 并发模型", "感觉 actor 挺好用的",
            "对，隔离状态很清晰", "你用 SwiftUI 还是 UIKit？", "目前还是 UIKit",
            "等 iOS 15 最低版本要求普及再迁移", "有道理", "今天天气不错",
            "出去走走？", "下午有个会", "那改天吧", "好的", "记得发语音消息测试一下",
            "哈哈好的", "长按录音按钮", "松手发送", "上滑取消", "收到！"
        ]
        texts.forEach { appendMessage(.text($0)) }
    }
}

// MARK: - 键盘处理

extension VoiceChatViewController {

    private func setupKeyboardObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil)
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let endFrame = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
            let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue,
            let curveRaw = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue
        else { return }

        // 键盘完全收起时 endFrame.minY == view 底部
        let keyboardHeight = max(view.bounds.maxY - endFrame.minY, 0)
        // 键盘遮挡高度 = 键盘高度 - 安全区域底部（底栏已超出安全区，不能重复计算）
        let offset = keyboardHeight > 0
            ? -keyboardHeight
            : -view.safeAreaInsets.bottom

        let shouldScroll = isNearBottom
        let options = UIView.AnimationOptions(rawValue: curveRaw << 16)
        UIView.animate(withDuration: duration, delay: 0, options: options) {
            self.inputViewBottomConstraint.constant = offset
            self.view.layoutIfNeeded()
        } completion: { _ in
            if shouldScroll, !self.messages.isEmpty {
                self.collectionView.scrollToItem(
                    at: IndexPath(item: self.messages.count - 1, section: 0),
                    at: .bottom, animated: true)
            }
        }
    }
}
