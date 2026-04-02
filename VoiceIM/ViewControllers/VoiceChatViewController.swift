import UIKit
import AVFoundation
import PhotosUI

/// IM 聊天页面（支持语音消息、文本消息、图片消息和视频消息）
final class VoiceChatViewController: UIViewController {

    // MARK: - 常量

    private let cancelThreshold: CGFloat = 80
    private let maxRecordSeconds = 30

    // MARK: - Section

    private enum Section { case main }

    // MARK: - UI

    private var collectionView: UICollectionView!
    private let chatInputView = ChatInputView()
    private let overlayVC     = RecordingOverlayViewController()
    private var inputViewBottomConstraint: NSLayoutConstraint!

    // MARK: - DiffableDataSource

    private var dataSource: UICollectionViewDiffableDataSource<Section, ChatMessage>!

    // MARK: - 录音状态

    private enum RecordState { case idle, recording, cancelReady }
    private var recordState: RecordState = .idle

    private var touchStartY: CGFloat = 0
    private var countdownTimer: Timer?
    private var audioLevelTimer: Timer?
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

    // MARK: - 历史记录加载

    private var isLoadingHistory = false    // 防重复触发
    private var historyPage = 0             // 已加载页数
    private let maxHistoryPages = 3         // mock 数据最多 3 页
    private let historyRefreshControl = UIRefreshControl()

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
        // 注册所有消息 Cell 类型；新增类型时在此追加一行即可
        VoiceMessageCell.register(in: collectionView)
        TextMessageCell.register(in: collectionView)
        ImageMessageCell.register(in: collectionView)
        VideoMessageCell.register(in: collectionView)
        view.addSubview(collectionView)

        // DiffableDataSource
        // cell provider 通过 MessageCellConfigurable 协议统一分发，
        // 不再含 switch 分支，新增消息类型无需修改此处。
        dataSource = UICollectionViewDiffableDataSource<Section, ChatMessage>(
            collectionView: collectionView
        ) { [weak self] cv, indexPath, message in
            guard let self else { return UICollectionViewCell() }
            // 从 messages 数组取最新状态，保证 isPlayed 等可变字段始终准确
            let current = self.messages.first(where: { $0.id == message.id }) ?? message

            // 计算是否在此消息上方显示时间分隔行：
            //   - 第一条消息（prev == nil）始终显示（?? true）
            //   - 与上一条间隔 >5 分钟时显示
            //
            // 注意：用 UUID 查找 currentIdx 而非直接使用 indexPath.item。
            // prependMessages 插入历史消息时，dataSource.apply 是同步的，
            // 但 CompositionalLayout 的 cell provider 可能在下一个布局周期被再次调用，
            // 此时 indexPath.item 与 messages 数组下标的对应关系仍然正确；
            // 不过 UUID 查找方式更健壮，不依赖二者严格对应的假设。
            let currentIdx = self.messages.firstIndex(where: { $0.id == current.id }) ?? indexPath.item
            let prev = currentIdx > 0 ? self.messages[currentIdx - 1] : nil
            let showTime = prev.map { current.sentAt.timeIntervalSince($0.sentAt) > 5 * 60 } ?? true

            // 构造依赖包：各 Cell 按需取用，不关心的字段直接忽略
            let deps = MessageCellDependencies(
                isPlaying: self.player.isPlaying(id:),
                showTimeHeader: showTime,
                voiceDelegate: self,
                imageDelegate: self,
                videoDelegate: self)

            // Kind.reuseID 与注册时保持一致，强转安全
            let cell = cv.dequeueReusableCell(
                withReuseIdentifier: current.kind.reuseID,
                for: indexPath)
            (cell as! any MessageCellConfigurable).configure(with: current, deps: deps)  // swiftlint:disable:this force_cast

            // 设置重试按钮回调（仅 ChatBubbleCell 及其子类需要）
            if let bubbleCell = cell as? ChatBubbleCell {
                bubbleCell.onRetryTap = { [weak self] in
                    self?.retryMessage(id: current.id)
                }
            }

            return cell
        }

        // 初始化空 snapshot
        var snapshot = NSDiffableDataSourceSnapshot<Section, ChatMessage>()
        snapshot.appendSections([.main])
        dataSource.apply(snapshot, animatingDifferences: false)

        // 下拉加载历史
        historyRefreshControl.addTarget(self,
                                        action: #selector(handleHistoryRefresh),
                                        for: .valueChanged)
        collectionView.refreshControl = historyRefreshControl
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

        // 扩展功能按钮点击（类似 iMessage 的 + 按钮）
        chatInputView.onExtensionTap = { [weak self] in
            self?.handleExtensionTap()
        }
    }

    /// 处理扩展功能按钮点击
    private func handleExtensionTap() {
        let alert = UIAlertController(title: "扩展功能", message: "选择一个功能", preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: "相册", style: .default) { [weak self] _ in
            self?.openPhotoPicker()
        })

        alert.addAction(UIAlertAction(title: "拍照", style: .default) { [weak self] _ in
            ToastView.show("拍照功能开发中", in: self?.view ?? UIView())
        })

        alert.addAction(UIAlertAction(title: "位置", style: .default) { [weak self] _ in
            ToastView.show("位置功能开发中", in: self?.view ?? UIView())
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))

        present(alert, animated: true)
    }

    /// 打开系统相册选择器
    private func openPhotoPicker() {
        var config = PHPickerConfiguration()
        config.selectionLimit = 1
        config.filter = .any(of: [.images, .videos])

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
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

    private func finishAndSend() {
        stopCountdown()
        // AVAudioRecorder.currentTime 在到达上限附近可能略超 30（如 30.01）；
        // 这里做上限钳制，避免列表向上取整后显示 31"。
        let actualDuration = min(recorder.currentTime, TimeInterval(maxRecordSeconds))
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
        overlayVC.setState(.cancelReady)
        updateVoiceButton()
    }

    private func enterNormalRecording() {
        recordState = .recording
        overlayVC.setState(.recording)
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
        // 录音期间禁用文字输入（语音模式下 textView 已隐藏，调用无副作用）
        chatInputView.setTextInputEnabled(false)
        overlayVC.setState(.recording)
        overlayVC.updateSeconds(0)
        overlayVC.updateAudioLevel(0)
        present(overlayVC, animated: true)
    }

    private func hideOverlay() {
        overlayVC.dismiss(animated: true)
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

        // 模拟发送：自己发送的消息需要模拟网络发送过程
        if message.isOutgoing {
            simulateSendMessage(id: message.id)
        }
    }

    /// 模拟消息发送过程（开发阶段使用，生产环境替换为真实网络请求）
    ///
    /// # 模拟逻辑
    /// - 延迟 1-2 秒模拟网络请求
    /// - 70% 成功率（状态变为 `.delivered`）
    /// - 30% 失败率（状态变为 `.failed`，可点击重试）
    ///
    /// # 状态更新机制
    /// 通过修改 `messages` 数组中的 `sendStatus` 字段，然后调用 `snapshot.reloadItems` 触发 cell 重新配置。
    /// 这与 `isPlayed` 更新策略一致，详见 `ChatMessage.swift` 中的 Hashable 设计说明。
    private func simulateSendMessage(id: UUID) {
        // 模拟网络延迟 1-2 秒
        let delay = Double.random(in: 1.0...2.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard let idx = self.messages.firstIndex(where: { $0.id == id }) else { return }

            // 70% 成功率
            let success = Double.random(in: 0...1) < 0.7
            self.messages[idx].sendStatus = success ? .delivered : .failed

            var snapshot = self.dataSource.snapshot()
            snapshot.reloadItems([self.messages[idx]])
            self.dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    /// 重试发送失败的消息：删除失败的消息，然后根据消息内容重新发送一份
    ///
    /// # 重试流程
    /// 1. 验证消息存在且状态为 `.failed`
    /// 2. 从列表中删除失败的消息（带删除动画）
    /// 3. 根据消息类型重新创建新消息：
    ///    - 语音消息：使用原 `localURL` 重新发送（若文件丢失则提示用户）
    ///    - 文本消息：使用原文本内容重新发送
    /// 4. 调用 `appendMessage` 将新消息追加到列表底部，自动触发 `simulateSendMessage`
    ///
    /// # 设计考量
    /// 采用"删除 + 重新发送"而非"原地更新状态"的原因：
    /// - 符合常见 IM 应用的交互习惯（重试后消息出现在列表底部）
    /// - 避免时间戳混乱（失败消息的 `sentAt` 可能是几分钟前，重试后应显示当前时间）
    /// - 简化状态管理（新消息有新 ID，不会与旧消息的播放状态等产生冲突）
    private func retryMessage(id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }),
              messages[idx].sendStatus == .failed else { return }

        let failedMessage = messages[idx]

        // 先删除失败的消息
        messages.remove(at: idx)
        var snapshot = dataSource.snapshot()
        snapshot.deleteItems([failedMessage])
        dataSource.apply(snapshot, animatingDifferences: true)

        // 根据消息类型重新创建并发送
        let newMessage: ChatMessage
        switch failedMessage.kind {
        case .voice(let localURL, _, let duration):
            // 语音消息：使用原来的本地文件重新发送
            if let url = localURL {
                newMessage = .voice(localURL: url, duration: duration, sentAt: Date())
            } else {
                ToastView.show("无法重试：原始文件已丢失", in: view)
                return
            }
        case .text(let content):
            // 文本消息：使用原来的文本内容重新发送
            newMessage = .text(content, sender: .me, sentAt: Date())
        case .image(let localURL, _):
            // 图片消息：使用原来的本地文件重新发送
            if let url = localURL {
                newMessage = .image(localURL: url, sentAt: Date())
            } else {
                ToastView.show("无法重试：原始文件已丢失", in: view)
                return
            }
        case .video(let localURL, _, let duration):
            // 视频消息：使用原来的本地文件重新发送
            if let url = localURL {
                newMessage = .video(localURL: url, duration: duration, sentAt: Date())
            } else {
                ToastView.show("无法重试：原始文件已丢失", in: view)
                return
            }
        }

        // 追加新消息并触发发送
        appendMessage(newMessage)
    }

    /// UIRefreshControl 触发回调（用户在列表顶部下拉时调用）。
    ///
    /// 防重：`isLoadingHistory` 为 true 时直接结束刷新，避免下拉过程中再次触发。
    /// 分页边界：加载完 `maxHistoryPages` 页后提示用户，不再发起请求。
    @objc private func handleHistoryRefresh() {
        // 上一次请求尚未完成，直接收起刷新指示器
        guard !isLoadingHistory else {
            historyRefreshControl.endRefreshing()
            return
        }
        // 已加载所有 mock 页，告知用户没有更多历史
        guard historyPage < maxHistoryPages else {
            historyRefreshControl.endRefreshing()
            ToastView.show("没有更多历史消息", in: view)
            return
        }
        isLoadingHistory = true
        // 模拟网络延迟（实际项目替换为网络/数据库请求）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.prependMessages(self.makeMockHistoryBatch())
        }
    }

    /// 将一批历史消息插入列表头部，并保持用户当前阅读位置不跳动。
    ///
    /// # 滚动位置锚定原理
    /// 在头部插入 N 条消息后，内容总高度会增加 ΔH。
    /// 若不修正 contentOffset，UICollectionView 会将原来可见的内容向下推移 ΔH，
    /// 造成屏幕内容"跳动"。解决方式：
    ///   1. 记录 apply 前的 contentOffset.y 和 contentSize.height
    ///   2. apply(animatingDifferences: false) 同步完成后调用 layoutIfNeeded()
    ///      强制立即计算新 contentSize（否则 contentSize 在下一个 RunLoop 才更新）
    ///   3. 将 contentOffset.y 增加 ΔH，抵消内容下移，用户视线锚定不变
    private func prependMessages(_ newMessages: [ChatMessage]) {
        isLoadingHistory = false
        historyRefreshControl.endRefreshing()
        guard !newMessages.isEmpty else { return }

        // 步骤 1：记录插入前的布局状态
        let oldHeight  = collectionView.contentSize.height
        let oldOffsetY = collectionView.contentOffset.y

        // 同步更新可变状态真实来源（与 appendMessage 保持对称）
        messages.insert(contentsOf: newMessages, at: 0)

        // 步骤 2：在 snapshot 头部插入
        // insertItems(beforeItem:) 要求 beforeItem 已存在于 snapshot；
        // 若列表为空（极端情况）则退化为 appendItems
        var snapshot = dataSource.snapshot()
        let existing = snapshot.itemIdentifiers(inSection: .main)
        if let first = existing.first {
            snapshot.insertItems(newMessages, beforeItem: first)
        } else {
            snapshot.appendItems(newMessages, toSection: .main)
        }
        // animatingDifferences: false → apply 在当前 RunLoop 同步执行，无插入/删除动画
        dataSource.apply(snapshot, animatingDifferences: false)

        // 步骤 3：强制立即布局，确保 contentSize 已反映新内容
        collectionView.layoutIfNeeded()

        // 步骤 4：偏移补偿，锚定用户视线
        let heightDiff = collectionView.contentSize.height - oldHeight
        collectionView.contentOffset.y = oldOffsetY + heightDiff
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

// MARK: - ImageMessageCellDelegate

extension VoiceChatViewController: ImageMessageCellDelegate {

    func cellDidTapImage(_ cell: ImageMessageCell, message: ChatMessage) {
        guard case .image(let localURL, let remoteURL) = message.kind,
              let imageURL = localURL ?? remoteURL else { return }

        let previewVC = ImagePreviewViewController(imageURL: imageURL)
        present(previewVC, animated: true)
    }
}

// MARK: - VideoMessageCellDelegate

extension VoiceChatViewController: VideoMessageCellDelegate {

    func cellDidTapVideo(_ cell: VideoMessageCell, message: ChatMessage) {
        guard case .video(let localURL, let remoteURL, _) = message.kind,
              let videoURL = localURL ?? remoteURL else { return }

        let previewVC = VideoPreviewViewController(videoURL: videoURL)
        present(previewVC, animated: true)
    }
}

// MARK: - PHPickerViewControllerDelegate

extension VoiceChatViewController: PHPickerViewControllerDelegate {

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)

        guard let result = results.first else { return }

        let itemProvider = result.itemProvider

        // 检查是否为图片
        if itemProvider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] url, error in
                guard let self, let url = url, error == nil else { return }

                // 复制到临时目录
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(url.pathExtension)

                do {
                    try FileManager.default.copyItem(at: url, to: tempURL)
                    DispatchQueue.main.async {
                        self.appendMessage(.image(localURL: tempURL))
                    }
                } catch {
                    DispatchQueue.main.async {
                        ToastView.show("图片加载失败", in: self.view)
                    }
                }
            }
        }
        // 检查是否为视频
        else if itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, error in
                guard let self, let url = url, error == nil else { return }

                // 复制到临时目录
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(url.pathExtension)

                do {
                    try FileManager.default.copyItem(at: url, to: tempURL)

                    // 获取视频时长
                    let asset = AVAsset(url: tempURL)
                    let duration = asset.duration.seconds

                    DispatchQueue.main.async {
                        self.appendMessage(.video(localURL: tempURL, duration: duration))
                    }
                } catch {
                    DispatchQueue.main.async {
                        ToastView.show("视频加载失败", in: self.view)
                    }
                }
            }
        }
    }
}

// MARK: - Mock 数据

extension VoiceChatViewController {

    /// 生成一批 mock 历史消息，时间比当前列表更早，触发时间分隔行（上线前删除）。
    private func makeMockHistoryBatch() -> [ChatMessage] {
        historyPage += 1
        let now = Date()
        // 每页使用更早的时间段，确保加载后能出现时间分隔行
        let batches: [[(String, Sender, TimeInterval)]] = [
            [   // 约 3 小时前
                ("早上好！",        .peer, 3 * 3600),
                ("bug 修好了吗？",   .me,   3 * 3600 - 120),
                ("修好了，并发问题", .peer, 3 * 3600 - 240),
                ("actor 确实好用",  .me,   3 * 3600 - 360),
                ("下次注意",        .peer, 3 * 3600 - 480),
            ],
            [   // 约 6 小时前
                ("周末有空吗？",   .me,   6 * 3600),
                ("周六可以",       .peer, 6 * 3600 - 120),
                ("讨论新需求",     .me,   6 * 3600 - 240),
                ("没问题",         .peer, 6 * 3600 - 360),
            ],
            [   // 昨天
                ("好久不见！",       .peer, 25 * 3600),
                ("新功能快上线了吗？", .me,  25 * 3600 - 120),
                ("还差一点",         .peer, 25 * 3600 - 240),
                ("加油，期待！",      .me,  25 * 3600 - 360),
            ],
        ]
        return batches[(historyPage - 1) % batches.count].map { text, sender, ago in
            .text(text, sender: sender, sentAt: now - ago)
        }
    }

    /// 预填 20 条消息，收发交替、时间分布触发多处时间分隔行。
    /// 上线前删除此方法及 viewDidLoad 中的调用即可。
    private func insertMockMessages() {
        let now = Date()
        // (文本, 发送者, 距今秒数)
        // 分为 4 组，组间间隔 >5 分钟，组内间隔 <1 分钟，形成 4 条时间分隔行
        let entries: [(String, Sender, TimeInterval)] = [
            // 组 1：约 1 小时前
            ("你好！",             .peer, 3600),
            ("最近怎么样？",        .me,   3555),
            ("在学 Swift 并发模型", .peer, 3510),
            ("actor 挺好用的",     .me,   3465),
            ("隔离状态很清晰",      .peer, 3420),
            // 组 2：约 30 分钟前（间隔 ~26 分钟 → 显示时间分隔行）
            ("你用 SwiftUI 还是 UIKit？", .me,   1800),
            ("目前还是 UIKit",            .peer, 1755),
            ("等 iOS 15 普及再迁移",      .me,   1710),
            ("有道理",                    .peer, 1665),
            ("今天天气不错",              .me,   1620),
            // 组 3：约 10 分钟前（间隔 ~17 分钟 → 显示时间分隔行）
            ("出去走走？",   .peer, 600),
            ("下午有个会",   .me,   555),
            ("那改天吧",     .peer, 510),
            ("好的",         .me,   465),
            ("记得测语音",   .peer, 420),
            // 组 4：约 1 分钟前（间隔 ~6 分钟 → 显示时间分隔行）
            ("哈哈好的",   .me,    60),
            ("长按录音按钮", .peer,  45),
            ("松手发送",   .me,    30),
            ("上滑取消",   .peer,  15),
            ("收到！",     .me,     0),
        ]
        entries.forEach { text, sender, ago in
            appendMessage(.text(text, sender: sender, sentAt: now - ago))
        }
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
