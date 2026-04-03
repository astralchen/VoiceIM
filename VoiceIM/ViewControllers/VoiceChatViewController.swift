@preconcurrency import UIKit
import AVFoundation

/// IM 聊天页面（支持语音消息、文本消息、图片消息和视频消息）
final class VoiceChatViewController: UIViewController {

    // MARK: - UI

    private var collectionView: UICollectionView!
    private let chatInputView = ChatInputView()
    private var inputViewBottomConstraint: NSLayoutConstraint!

    // MARK: - 历史记录加载

    private var isLoadingHistory = false    // 防重复触发
    private var historyPage = 0             // 已加载页数
    private let maxHistoryPages = 3         // mock 数据最多 3 页
    private let historyRefreshControl = UIRefreshControl()

    // MARK: - 管理器

    private let player = VoicePlaybackManager.shared
    private lazy var messageDataSource = MessageDataSource(collectionView: collectionView)
    private lazy var actionHandler = MessageActionHandler(player: player)
    private lazy var inputCoordinator = InputCoordinator()
    private var keyboardManager: KeyboardManager!

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "消息"
        view.backgroundColor = .systemBackground
        setupCollectionView()
        setupInputView()
        setupManagers()
        setupPlaybackCallbacks()
        setupAppLifecycleObservers()
        insertMockMessages()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !messageDataSource.messages.isEmpty else { return }
        scrollToBottom(animated: false)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        player.stopCurrent()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        inputViewBottomConstraint.constant = -view.safeAreaInsets.bottom
    }

    override func viewWillTransition(to size: CGSize,
                                     with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        guard !messageDataSource.messages.isEmpty else { return }
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.scrollToBottom(animated: false)
        }
    }

    // MARK: - UI 搭建

    private func setupCollectionView() {
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.backgroundColor = .systemBackground
        collectionView.keyboardDismissMode = .onDrag
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        // 注册所有消息 Cell 类型
        VoiceMessageCell.register(in: collectionView)
        TextMessageCell.register(in: collectionView)
        ImageMessageCell.register(in: collectionView)
        VideoMessageCell.register(in: collectionView)
        RecalledMessageCell.register(in: collectionView)
        view.addSubview(collectionView)

        // 点击空白处收起键盘
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false  // 不阻止 cell 点击事件
        collectionView.addGestureRecognizer(tap)

        // 配置 MessageDataSource 的 cell provider
        messageDataSource.cellConfigurator = { [weak self] cv, indexPath, current, prev in
            guard let self else { return UICollectionViewCell() }

            // 计算是否显示时间分隔行
            let showTime = prev.map { current.sentAt.timeIntervalSince($0.sentAt) > 5 * 60 } ?? true

            // 构造依赖包
            let deps = MessageCellDependencies(
                isPlaying: self.player.isPlaying(id:),
                showTimeHeader: showTime,
                voiceDelegate: self,
                imageDelegate: self,
                videoDelegate: self)

            let cell = cv.dequeueReusableCell(
                withReuseIdentifier: current.kind.reuseID,
                for: indexPath)
            (cell as! any MessageCellConfigurable).configure(with: current, deps: deps)  // swiftlint:disable:this force_cast

            // 设置重试按钮回调
            if let bubbleCell = cell as? ChatBubbleCell {
                bubbleCell.onRetryTap = { [weak self] in
                    self?.actionHandler.retryMessage(current.id)
                }
                bubbleCell.onLongPress = { [weak self] in
                    self?.actionHandler.handleLongPress(on: current)
                }
            }

            // 设置撤回消息点击回调
            if let recalledCell = cell as? RecalledMessageCell {
                recalledCell.onTap = { [weak self] in
                    self?.actionHandler.handleRecalledMessageTap(current)
                }
            }

            return cell
        }

        // 下拉加载历史
        historyRefreshControl.addTarget(self,
                                        action: #selector(handleHistoryRefresh),
                                        for: .valueChanged)
        collectionView.refreshControl = historyRefreshControl
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    /// iOS 13 CompositionalLayout：单列、自适应高度
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

        // 输入栏增高后，若用户在底部附近则滚动列表
        chatInputView.onHeightChange = { [weak self] in
            guard let self, isNearBottom else { return }
            scrollToBottom(animated: true)
        }
    }

    private func setupManagers() {
        // 配置 ActionHandler
        actionHandler.viewController = self
        actionHandler.onDelete = { [weak self] id in
            guard let self else { return }
            if let message = self.messageDataSource.deleteMessage(id: id),
               let url = message.localURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
        actionHandler.onRecall = { [weak self] id in
            self?.recallMessage(id: id)
        }
        actionHandler.onRetry = { [weak self] id in
            self?.retryMessage(id: id)
        }
        actionHandler.onRecalledMessageTap = { [weak self] message in
            guard case .recalled(let originalText) = message.kind,
                  let text = originalText else { return }
            self?.inputCoordinator.setText(text)
        }

        // 配置 InputCoordinator
        inputCoordinator.viewController = self
        inputCoordinator.setup(with: chatInputView)
        inputCoordinator.onSendText = { [weak self] text in
            self?.appendMessage(.text(text))
        }
        inputCoordinator.onSendVoice = { [weak self] url, duration in
            self?.appendMessage(.voice(localURL: url, duration: duration))
        }
        inputCoordinator.onSendImage = { [weak self] url in
            self?.appendMessage(.image(localURL: url))
        }
        inputCoordinator.onSendVideo = { [weak self] url, duration in
            self?.appendMessage(.video(localURL: url, duration: duration))
        }
        inputCoordinator.showToast = { [weak self] message in
            guard let self else { return }
            ToastView.show(message, in: self.view)
        }

        // 配置 KeyboardManager
        keyboardManager = KeyboardManager(
            scrollView: collectionView,
            inputViewBottomConstraint: inputViewBottomConstraint,
            safeAreaProvider: { [weak self] in self?.view.safeAreaInsets ?? .zero }
        )
        keyboardManager.isNearBottom = { [weak self] in self?.isNearBottom ?? false }
        keyboardManager.scrollToBottom = { [weak self] in self?.scrollToBottom(animated: true) }
        keyboardManager.startObserving()
    }

    private func setupPlaybackCallbacks() {
        player.onStart = { [weak self] id in
            self?.messageDataSource.markAsPlayed(id: id)
        }
        player.onProgress = { [weak self] id, progress in
            self?.cellForMessage(id: id)?.applyPlayState(isPlaying: true, progress: progress)
        }
        player.onStop = { [weak self] id in
            self?.cellForMessage(id: id)?.applyPlayState(isPlaying: false, progress: 0)
        }
    }

    private func setupAppLifecycleObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil)
    }

    @objc private func appDidEnterBackground() {
        player.stopCurrent()
    }

    // MARK: - 消息列表

    private func appendMessage(_ message: ChatMessage) {
        let shouldScroll = isNearBottom
        messageDataSource.appendMessage(message, animatingDifferences: false)

        if shouldScroll {
            scrollToBottom(animated: true)
        }

        // 模拟发送
        if message.isOutgoing {
            simulateSendMessage(id: message.id)
        }
    }

    /// 模拟消息发送过程（开发阶段使用）
    private func simulateSendMessage(id: UUID) {
        let delay = Double.random(in: 1.0...2.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let success = Double.random(in: 0...1) < 0.7
            self.messageDataSource.updateSendStatus(id: id, status: success ? .delivered : .failed)
        }
    }

    /// 重试发送失败的消息
    private func retryMessage(id: UUID) {
        guard let idx = messageDataSource.index(of: id),
              let failedMessage = messageDataSource.message(at: idx),
              failedMessage.sendStatus == .failed else { return }

        // 先删除失败的消息
        if let message = messageDataSource.deleteMessage(id: id) {
            // 根据消息类型重新创建并发送
            let newMessage: ChatMessage
            switch message.kind {
            case .voice(let localURL, _, let duration):
                if let url = localURL {
                    newMessage = .voice(localURL: url, duration: duration, sentAt: Date())
                } else {
                    ToastView.show("无法重试：原始文件已丢失", in: view)
                    return
                }
            case .text(let content):
                newMessage = .text(content, sender: .me, sentAt: Date())
            case .image(let localURL, _):
                if let url = localURL {
                    newMessage = .image(localURL: url, sentAt: Date())
                } else {
                    ToastView.show("无法重试：原始文件已丢失", in: view)
                    return
                }
            case .video(let localURL, _, let duration):
                if let url = localURL {
                    newMessage = .video(localURL: url, duration: duration, sentAt: Date())
                } else {
                    ToastView.show("无法重试：原始文件已丢失", in: view)
                    return
                }
            case .recalled:
                ToastView.show("撤回消息无法重试", in: view)
                return
            }

            appendMessage(newMessage)
        }
    }

    /// UIRefreshControl 触发回调（用户在列表顶部下拉时调用）
    @objc private func handleHistoryRefresh() {
        guard !isLoadingHistory else {
            historyRefreshControl.endRefreshing()
            return
        }
        guard historyPage < maxHistoryPages else {
            historyRefreshControl.endRefreshing()
            ToastView.show("没有更多历史消息", in: view)
            return
        }
        isLoadingHistory = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.messageDataSource.prependMessages(self.makeMockHistoryBatch())
            self.isLoadingHistory = false
            self.historyRefreshControl.endRefreshing()
        }
    }

    /// 撤回消息：将原消息替换为撤回提示消息
    private func recallMessage(id: UUID) {
        guard let idx = messageDataSource.index(of: id),
              let originalMessage = messageDataSource.message(at: idx),
              originalMessage.isOutgoing else { return }

        // 提取原文本内容（仅文本消息保留）
        let originalText: String?
        if case .text(let content) = originalMessage.kind {
            originalText = content
        } else {
            originalText = nil
        }

        // 删除原消息的本地文件
        if let url = originalMessage.localURL {
            try? FileManager.default.removeItem(at: url)
        }

        // 创建撤回消息
        let recalledMessage = ChatMessage.recalled(
            originalText: originalText,
            sender: originalMessage.sender,
            sentAt: originalMessage.sentAt)

        messageDataSource.replaceMessage(id: id, with: recalledMessage)
    }

    /// 判断当前是否在底部附近
    private var isNearBottom: Bool {
        let cv = collectionView!
        let distanceFromBottom = cv.contentSize.height
            - cv.contentOffset.y
            - cv.bounds.height
            + cv.adjustedContentInset.bottom
        return distanceFromBottom < 60
    }

    /// 滚动到底部
    private func scrollToBottom(animated: Bool) {
        guard !messageDataSource.messages.isEmpty else { return }
        collectionView.scrollToItem(
            at: IndexPath(item: messageDataSource.messages.count - 1, section: 0),
            at: .bottom, animated: animated)
    }

    // MARK: - 播放逻辑

    private func handlePlayTap(message: ChatMessage) {
        if player.isPlaying(id: message.id) {
            player.stopCurrent()
            return
        }
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
        guard let idx = messageDataSource.index(of: id) else { return nil }
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

// MARK: - Mock 数据

extension VoiceChatViewController {

    /// 生成一批 mock 历史消息
    private func makeMockHistoryBatch() -> [ChatMessage] {
        historyPage += 1
        let now = Date()
        let batches: [[(String, Sender, TimeInterval)]] = [
            [
                ("早上好！",        .peer, 3 * 3600),
                ("bug 修好了吗？",   .me,   3 * 3600 - 120),
                ("修好了，并发问题", .peer, 3 * 3600 - 240),
                ("actor 确实好用",  .me,   3 * 3600 - 360),
                ("下次注意",        .peer, 3 * 3600 - 480),
            ],
            [
                ("周末有空吗？",   .me,   6 * 3600),
                ("周六可以",       .peer, 6 * 3600 - 120),
                ("讨论新需求",     .me,   6 * 3600 - 240),
                ("没问题",         .peer, 6 * 3600 - 360),
            ],
            [
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

    /// 预填 20 条消息
    private func insertMockMessages() {
        let now = Date()
        let entries: [(String, Sender, TimeInterval)] = [
            ("你好！",             .peer, 3600),
            ("最近怎么样？",        .me,   3555),
            ("在学 Swift 并发模型", .peer, 3510),
            ("actor 挺好用的",     .me,   3465),
            ("隔离状态很清晰",      .peer, 3420),
            ("你用 SwiftUI 还是 UIKit？", .me,   1800),
            ("目前还是 UIKit",            .peer, 1755),
            ("等 iOS 15 普及再迁移",      .me,   1710),
            ("有道理",                    .peer, 1665),
            ("今天天气不错",              .me,   1620),
            ("出去走走？",   .peer, 600),
            ("下午有个会",   .me,   555),
            ("那改天吧",     .peer, 510),
            ("好的",         .me,   465),
            ("记得测语音",   .peer, 420),
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
