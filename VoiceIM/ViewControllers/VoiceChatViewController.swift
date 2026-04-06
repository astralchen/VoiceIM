import UIKit
import AVFoundation
import MapKit
import Combine

/// IM 聊天页面（支持语音消息、文本消息、图片消息和视频消息）
///
/// 使用 MVVM 架构，通过 ChatViewModel 管理状态
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

    // MARK: - 消息预加载

    private let messagePreloader = MessagePreloader.shared

    // MARK: - MVVM

    private let viewModel: ChatViewModel
    private var cancellables = Set<AnyCancellable>()

    // MARK: - 依赖注入

    private var messageDataSource: MessageDataSource!
    private var actionHandler: MessageActionHandler!
    private var inputCoordinator: InputCoordinator!
    private var keyboardManager: KeyboardManager!


    // MARK: - 初始化

    /// 初始化聊天视图控制器
    ///
    /// 使用 MVVM 架构，通过 ChatViewModel 管理状态。
    ///
    /// - Parameter viewModel: 聊天 ViewModel
    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        title = viewModel.contact.displayName
        view.backgroundColor = .systemBackground

        // 初始化依赖组件
        setupCollectionView()
        messageDataSource = MessageDataSource(collectionView: collectionView)
        actionHandler = MessageActionHandler(player: viewModel.playbackService)
        inputCoordinator = InputCoordinator(
            recorder: viewModel.recordService,
            player: viewModel.playbackService,
            photoPicker: viewModel.photoPickerService
        )

        setupInputView()
        setupManagers()
        setupPlaybackCallbacks()
        setupAppLifecycleObservers()

        // 订阅 ViewModel 状态
        bindViewModel()

        // 加载消息
        viewModel.loadMessages()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !messageDataSource.messages.isEmpty else { return }
        scrollToBottom(animated: false)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        viewModel.stopPlayback()
        viewModel.cancelActiveTasks()
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

    // MARK: - ViewModel Binding

    /// 订阅 ViewModel 的状态变化
    private func bindViewModel() {
        // 订阅消息列表变化
        viewModel.$messages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] messages in
                self?.updateMessages(messages)
            }
            .store(in: &cancellables)

        // 订阅错误
        viewModel.$error
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                self?.handleError(error)
            }
            .store(in: &cancellables)
    }

    /// 更新消息列表
    private func updateMessages(_ messages: [ChatMessage]) {
        // 使用增量更新策略，避免清空重建导致的动画问题

        let currentIDs = Set(messageDataSource.messages.map { $0.id })
        let newIDs = Set(messages.map { $0.id })

        // 如果是首次加载，直接批量添加
        if currentIDs.isEmpty {
            for message in messages {
                messageDataSource.appendMessage(message, animatingDifferences: false)
            }
            if !messages.isEmpty {
                scrollToBottom(animated: false)
            }
            return
        }

        // 增量更新：找出新增、删除、更新的消息
        let toDelete = currentIDs.subtracting(newIDs)
        let toAdd = messages.filter { !currentIDs.contains($0.id) }

        // 先删除不存在的消息（批量删除，关闭动画）
        for id in toDelete {
            _ = messageDataSource.deleteMessage(id: id)
        }

        // 添加新消息（开启动画）
        for message in toAdd {
            messageDataSource.appendMessage(message, animatingDifferences: true)
        }

        // 更新已存在消息的状态（kind, isPlayed, sendStatus）
        for message in messages where currentIDs.contains(message.id) {
            if let index = messageDataSource.messages.firstIndex(where: { $0.id == message.id }) {
                let current = messageDataSource.messages[index]

                // kind 变化（撤回/编辑）→ 整体替换 cell
                if current.kind.reuseID != message.kind.reuseID {
                    messageDataSource.replaceMessage(id: message.id, with: message)
                    continue
                }

                if current.isPlayed != message.isPlayed {
                    messageDataSource.markAsPlayed(id: message.id)
                }

                if current.sendStatus != message.sendStatus {
                    messageDataSource.updateSendStatus(id: message.id, status: message.sendStatus)
                }
            }
        }

        // 如果有新消息添加，滚动到底部
        if !toAdd.isEmpty {
            scrollToBottom(animated: true)
        }
    }

    /// 处理错误
    private func handleError(_ error: ChatError) {
        viewModel.errorHandler.handle(error, in: self)
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
        LocationMessageCell.register(in: collectionView)
        collectionView.delegate = self
        view.addSubview(collectionView)

        // 点击空白处收起键盘
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false  // 不阻止 cell 点击事件
        collectionView.addGestureRecognizer(tap)

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
        // 配置 MessageDataSource 的依赖注入
        messageDataSource.dependencies = MessageCellDependencies(
            isPlaying: { [weak self] id in
                guard let self else { return false }
                return self.viewModel.playbackService.isPlaying(id: id)
            },
            currentProgress: { [weak self] id in
                guard let self else { return 0 }
                return self.viewModel.playbackService.currentProgress(for: id)
            },
            playbackDuration: { [weak self] id in
                guard let self else { return 0 }
                return self.viewModel.playbackService.playbackDuration(for: id)
            },
            playbackRemaining: { [weak self] id in
                guard let self else { return 0 }
                return self.viewModel.playbackService.playbackRemaining(for: id)
            },
            voiceDelegate: self,
            imageDelegate: self,
            videoDelegate: self,
            locationDelegate: self,
            onLinkTapped: { [weak self] url, type in
                self?.handleLinkTapped(url: url, type: type)
            })

        // 配置 Cell 回调（重试按钮、上下文菜单、撤回消息点击）
        messageDataSource.cellConfigurator = { [weak self] cell, message in
            guard let self else { return }

            // 通过协议统一设置交互回调
            if let interactiveCell = cell as? MessageCellInteractive {
                interactiveCell.setRetryHandler { [weak self] in
                    self?.viewModel.retryMessage(id: message.id)
                }
                interactiveCell.setContextMenuProvider { [weak self] msg in
                    self?.actionHandler.buildContextMenu(for: msg)
                }
            }

            if let recalledCell = cell as? RecalledMessageCellInteractive {
                recalledCell.setTapHandler { [weak self] in
                    self?.actionHandler.handleRecalledMessageTap(message)
                }
            }
        }

        // 配置 ActionHandler
        actionHandler.viewController = self
        actionHandler.onDelete = { [weak self] id in
            self?.viewModel.deleteMessage(id: id)
        }
        actionHandler.onRecall = { [weak self] id in
            self?.viewModel.recallMessage(id: id)
        }
        actionHandler.onRetry = { [weak self] id in
            self?.viewModel.retryMessage(id: id)
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
            self?.viewModel.sendTextMessage(text)
        }
        inputCoordinator.onSendVoice = { [weak self] url, duration in
            self?.viewModel.sendVoiceMessage(url: url, duration: duration)
        }
        inputCoordinator.onSendImage = { [weak self] url in
            self?.viewModel.sendImageMessage(url: url)
        }
        inputCoordinator.onSendVideo = { [weak self] url, duration in
            self?.viewModel.sendVideoMessage(url: url, duration: duration)
        }
        inputCoordinator.onSendLocation = { [weak self] latitude, longitude, address in
            self?.viewModel.sendLocationMessage(latitude: latitude, longitude: longitude, address: address)
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

    // MARK: - 播放回调

    private func setupPlaybackCallbacks() {
        // 直接使用协议类型，无需向下转型
        viewModel.playbackService.onStart = { [weak self] (id: String) in
            VoiceIM.logger.debug("Playback started for message: \(id)")
            guard let self = self else { return }

            // 刷新正在播放的 Cell，让播放按钮变成暂停图标
            self.messageDataSource.reloadMessage(id: id)
        }

        viewModel.playbackService.onProgress = { [weak self] (id: String, progress: Float) in
            guard let self = self else { return }
            // 刷新正在播放的 Cell，更新进度条和剩余时长
            self.messageDataSource.reloadMessage(id: id)
        }

        viewModel.playbackService.onStop = { [weak self] (id: String) in
            VoiceIM.logger.debug("Playback stopped for message: \(id)")
            guard let self = self else { return }

            self.viewModel.handlePlaybackStopped(id: id)
            // 刷新 Cell，让播放按钮恢复
            self.messageDataSource.reloadMessage(id: id)
        }
    }

    // MARK: - 应用生命周期

    private func setupAppLifecycleObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil)
    }

    @objc private func handleAppDidEnterBackground() {
        viewModel.stopPlayback()
    }

    // MARK: - 历史消息加载

    @objc private func handleHistoryRefresh() {
        guard !isLoadingHistory, historyPage < maxHistoryPages else {
            historyRefreshControl.endRefreshing()
            return
        }

        isLoadingHistory = true
        historyPage += 1

        // 从 ViewModel 加载历史消息
        Task { [weak self] in
            guard let self else { return }

            do {
                let historyMessages = try await self.viewModel.loadHistory(page: self.historyPage)

                await MainActor.run {
                    // 将历史消息插入到列表头部
                    if !historyMessages.isEmpty {
                        self.messageDataSource.prependMessages(historyMessages)
                        VoiceIM.logger.info("Prepended \(historyMessages.count) history messages")
                    }

                    self.historyRefreshControl.endRefreshing()
                    self.isLoadingHistory = false
                }
            } catch {
                await MainActor.run {
                    VoiceIM.logger.error("Failed to load history: \(error)")
                    ToastView.show("加载历史消息失败", in: self.view)
                    self.historyRefreshControl.endRefreshing()
                    self.isLoadingHistory = false
                }
            }
        }
    }

    // MARK: - 滚动控制

    private var isNearBottom: Bool {
        let contentHeight = collectionView.contentSize.height
        let scrollViewHeight = collectionView.bounds.height
        let offsetY = collectionView.contentOffset.y
        let bottomInset = collectionView.contentInset.bottom

        return offsetY + scrollViewHeight + bottomInset >= contentHeight - 100
    }

    private func scrollToBottom(animated: Bool) {
        guard !messageDataSource.messages.isEmpty else { return }
        let lastIndex = messageDataSource.messages.count - 1
        let indexPath = IndexPath(item: lastIndex, section: 0)
        collectionView.scrollToItem(at: indexPath, at: .bottom, animated: animated)
    }

    // MARK: - 链接处理

    private func handleLinkTapped(url: URL, type: NSTextCheckingResult.CheckingType) {
        if type == .link {
            UIApplication.shared.open(url)
        } else if type == .phoneNumber {
            UIApplication.shared.open(url)
        } else {
            // 银行卡号等其他类型
            let alert = UIAlertController(
                title: "链接",
                message: url.absoluteString,
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "复制", style: .default) { _ in
                UIPasteboard.general.string = url.absoluteString
            })
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            present(alert, animated: true)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - VoiceMessageCellDelegate

extension VoiceChatViewController: VoiceMessageCellDelegate {
    func cellDidTapPlay(_ cell: VoiceMessageCell, message: ChatMessage) {
        VoiceIM.logger.debug("cellDidTapPlay called for message: \(message.id)")

        guard case .voice(let localURL, let remoteURL, _) = message.kind else {
            VoiceIM.logger.error("Not a voice message")
            ToastView.show("不是语音消息", in: view)
            return
        }

        if localURL == nil, remoteURL == nil {
            ToastView.show("语音文件不存在", in: view)
            return
        }

        // 统一走 ViewModel：本地直播 + 远程 `voiceFileCache.resolve` + 已播标记，避免此处重复调用 `playbackService` 导致逻辑分叉
        viewModel.playVoiceMessage(id: message.id)
    }

    func cellDidSeek(_ cell: VoiceMessageCell, message: ChatMessage, progress: Float) {
        viewModel.playbackService.seek(to: progress)
    }
}

// MARK: - ImageMessageCellDelegate

extension VoiceChatViewController: ImageMessageCellDelegate {
    func cellDidTapImage(_ cell: ImageMessageCell, message: ChatMessage) {
        guard case .image(let localURL, let remoteURL) = message.kind else {
            ToastView.show("消息类型错误", in: view)
            return
        }

        // resolveImageURL：与 Cell 显示逻辑保持一致
        // 本地路径 → 磁盘缓存回退（重启后路径失效场景）→ 远程 URL
        guard let resolvedURL = ImageCacheManager.shared.resolveImageURL(local: localURL, remote: remoteURL) else {
            ToastView.show("图片文件不存在", in: view)
            return
        }

        if resolvedURL.isFileURL {
            // 本地文件：预览时不限制尺寸，加载原始分辨率
            if let image = UIImage(contentsOfFile: resolvedURL.path) {
                presentImagePreview(image: image, imageURL: resolvedURL, sourceCell: cell)
            } else {
                ToastView.show("图片加载失败", in: view)
            }
        } else {
            // 远程图片：先查内存缓存，命中直接展示；否则异步加载
            if let cached = ImageCacheManager.shared.cachedImage(for: resolvedURL) {
                presentImagePreview(image: cached, imageURL: resolvedURL, sourceCell: cell)
                return
            }

            ToastView.show("正在加载图片...", in: view)
            Task {
                let image = await ImageCacheManager.shared.loadImage(from: resolvedURL)
                await MainActor.run {
                    if let image {
                        self.presentImagePreview(image: image, imageURL: resolvedURL, sourceCell: cell)
                    } else {
                        ToastView.show("图片加载失败", in: view)
                    }
                }
            }
        }
    }

    private func presentImagePreview(image: UIImage, imageURL: URL, sourceCell: ImageMessageCell) {
        let previewVC = ImagePreviewViewController(image: image, imageURL: imageURL)
        previewVC.setZoomTransition(from: { [weak sourceCell] in sourceCell?.bubble }, image: image)
        present(previewVC, animated: true)
    }

    func cellDidLoadImage(_ cell: ImageMessageCell, heightDelta: CGFloat) {
        // 【智能滚动策略】根据用户当前位置决定是否调整滚动
        // 目标：在图片加载导致高度变化时，提供最佳用户体验

        // 【策略 1】用户在底部：自动滚动到最新消息
        // 原因：用户正在查看最新消息，期望看到完整的图片
        // 效果：图片加载完成后，自动滚动显示完整内容
        // 场景：发送图片消息后，或者收到新的图片消息
        if isNearBottom {
            VoiceIM.logger.debug("Image loaded at bottom, scrolling to bottom")
            scrollToBottom(animated: true)
            return
        }

        // 【策略 2 & 3】检查图片 Cell 是否在可见区域
        // 原因：只有可见区域的图片高度变化才会影响用户体验
        guard let indexPath = collectionView.indexPath(for: cell) else { return }
        let visibleIndexPaths = collectionView.indexPathsForVisibleItems

        if visibleIndexPaths.contains(indexPath) {
            // 【策略 2】图片在可见区域：保持当前阅读位置不变
            // 原因：用户正在阅读历史消息，突然跳动会打断阅读体验
            // 效果：通过调整 contentOffset 补偿高度变化，用户看到的内容位置不变
            // 场景：向上滚动查看历史消息时，图片加载完成

            // 计算 Cell 在 CollectionView 中的位置
            let cellFrame = collectionView.layoutAttributesForItem(at: indexPath)?.frame ?? .zero
            let cellTop = cellFrame.minY
            let currentOffset = collectionView.contentOffset.y

            // 【关键判断】只有图片在当前可见区域上方时才需要补偿
            // 原因：如果图片在下方（还未滚动到），高度变化不影响当前可见内容
            // 效果：避免不必要的滚动调整
            if cellTop < currentOffset + collectionView.bounds.height {
                VoiceIM.logger.debug("Image loaded in visible area, adjusting offset by \(heightDelta)")

                // 【关键操作】平滑调整滚动位置，保持用户当前阅读内容不动
                // 原理：图片高度增加 heightDelta，contentOffset 也增加 heightDelta
                //      这样可见区域的内容位置保持不变
                // 动画：0.2 秒平滑过渡，避免突兀的跳动
                UIView.animate(withDuration: 0.2) {
                    self.collectionView.contentOffset.y += heightDelta
                }
            }
        } else {
            // 【策略 3】图片不在可见区域：直接更新，不影响用户
            // 原因：图片在屏幕外，高度变化不会影响用户当前看到的内容
            // 效果：静默更新，用户无感知
            // 场景：图片在很远的历史消息中，或者在下方未滚动到的位置
            VoiceIM.logger.debug("Image loaded outside visible area, no adjustment needed")
        }
    }
}

// MARK: - VideoMessageCellDelegate

extension VoiceChatViewController: VideoMessageCellDelegate {
    func cellDidTapVideo(_ cell: VideoMessageCell, message: ChatMessage) {
        guard case .video(let localURL, let remoteURL, _) = message.kind else {
            ToastView.show("消息类型错误", in: view)
            return
        }

        // resolveVideoURL：与 Cell 显示逻辑保持一致
        // 本地路径 → 视频缓存目录回退（重启后路径失效场景）→ 远程 URL
        guard let resolvedURL = VideoCacheManager.shared.resolveVideoURL(local: localURL, remote: remoteURL) else {
            ToastView.show("视频文件不存在", in: view)
            return
        }

        let previewVC = VideoPreviewViewController(
            videoURL: resolvedURL,
            mediaCoordinator: viewModel.mediaPlaybackCoordinator)
        previewVC.setZoomTransition(from: { [weak cell] in cell?.bubble }, image: cell.currentThumbnailImage)
        present(previewVC, animated: true)
    }
}

// MARK: - LocationMessageCellDelegate

extension VoiceChatViewController: LocationMessageCellDelegate {
    func cellDidTapLocation(_ cell: LocationMessageCell, message: ChatMessage) {
        guard case .location(let latitude, let longitude, _) = message.kind else { return }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        mapItem.openInMaps(launchOptions: nil)
    }
}

// MARK: - UIScrollViewDelegate (消息预加载)

extension VoiceChatViewController: UICollectionViewDelegate {

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // 获取可见的 IndexPath
        let visibleIndexPaths = collectionView.indexPathsForVisibleItems

        // 触发消息预加载
        messagePreloader.updateVisibleRange(
            messages: messageDataSource.messages,
            visibleIndexPaths: visibleIndexPaths
        )
    }
}
