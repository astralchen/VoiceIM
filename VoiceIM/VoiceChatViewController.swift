import UIKit
import AVFoundation

/// IM 语音聊天页面
final class VoiceChatViewController: UIViewController {

    // MARK: - 常量

    private let cancelThreshold: CGFloat = 80
    private let maxRecordSeconds = 30

    // MARK: - Section

    private enum Section { case main }

    // MARK: - UI

    private var collectionView: UICollectionView!
    private let bottomBar    = UIView()
    private let recordButton = UIButton(type: .system)
    private let overlayView  = RecordingOverlayView()

    // MARK: - DiffableDataSource

    private var dataSource: UICollectionViewDiffableDataSource<Section, VoiceMessage>!

    // MARK: - 录音状态

    private enum RecordState { case idle, recording, cancelReady }
    private var recordState: RecordState = .idle

    private var touchStartY: CGFloat = 0
    private var countdownTimer: Timer?
    private var elapsedSeconds = 0

    // MARK: - 消息数据（可变，isPlayed 在此更新，DiffableDataSource 从这里读取最新状态）

    private var messages: [VoiceMessage] = []

    // MARK: - 管理器（单例引用）

    private let recorder = VoiceRecordManager.shared
    private let player   = VoicePlaybackManager.shared

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "语音消息"
        view.backgroundColor = .systemBackground
        setupCollectionView()
        setupBottomBar()
        setupOverlay()
        setupPlaybackCallbacks()
    }

    // MARK: - UI 搭建

    private func setupCollectionView() {
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.backgroundColor = .systemBackground
        collectionView.keyboardDismissMode = .onDrag
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.register(VoiceMessageCell.self,
                                forCellWithReuseIdentifier: VoiceMessageCell.reuseID)
        view.addSubview(collectionView)

        // DiffableDataSource
        dataSource = UICollectionViewDiffableDataSource<Section, VoiceMessage>(
            collectionView: collectionView
        ) { [weak self] cv, indexPath, message in
            guard let self else { return UICollectionViewCell() }
            let cell = cv.dequeueReusableCell(
                withReuseIdentifier: VoiceMessageCell.reuseID,
                for: indexPath) as! VoiceMessageCell    // swiftlint:disable:this force_cast
            // 从 messages 数组取最新状态，保证 isPlayed 始终准确
            let current = self.messages.first(where: { $0.id == message.id }) ?? message
            cell.configure(with: current,
                           isPlaying: self.player.isPlaying(id: current.id),
                           progress: 0,
                           isUnread: !current.isPlayed)
            cell.delegate = self
            return cell
        }

        // 初始化空 snapshot
        var snapshot = NSDiffableDataSourceSnapshot<Section, VoiceMessage>()
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

    private func setupBottomBar() {
        bottomBar.backgroundColor = .secondarySystemBackground
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 72),
        ])

        recordButton.setTitle("按住说话", for: .normal)
        recordButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        recordButton.backgroundColor = .systemBackground
        recordButton.setTitleColor(.label, for: .normal)
        recordButton.layer.cornerRadius = 8
        recordButton.layer.borderWidth = 1
        recordButton.layer.borderColor = UIColor.separator.cgColor
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(recordButton)

        NSLayoutConstraint.activate([
            recordButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 20),
            recordButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -20),
            recordButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            recordButton.heightAnchor.constraint(equalToConstant: 44),
        ])

        let lp = UILongPressGestureRecognizer(target: self,
                                              action: #selector(handleLongPress(_:)))
        lp.minimumPressDuration = 0.3
        lp.allowableMovement = 2000
        recordButton.addGestureRecognizer(lp)
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

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {

        case .began:
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
            switch recordState {
            case .idle:        break
            case .recording:   finishAndSend()
            case .cancelReady: cancelAndDiscard()
            }

        case .cancelled, .failed:
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
            do {
                _ = try self.recorder.startRecording()
                self.recordState = .recording
                self.elapsedSeconds = 0
                self.showOverlay()
                self.updateButtonAppearance()
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
        appendMessage(VoiceMessage(localURL: url, duration: actualDuration))
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
        updateButtonAppearance()
    }

    private func enterNormalRecording() {
        recordState = .recording
        overlayView.setState(.recording)
        updateButtonAppearance()
    }

    private func resetToIdle() {
        recordState = .idle
        hideOverlay()
        updateButtonAppearance()
    }

    // MARK: - UI 更新

    private func showOverlay() {
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

    private func updateButtonAppearance() {
        switch recordState {
        case .idle:
            recordButton.setTitle("按住说话", for: .normal)
            recordButton.backgroundColor = .systemBackground
            recordButton.layer.borderColor = UIColor.separator.cgColor
        case .recording:
            recordButton.setTitle("松开 发送", for: .normal)
            recordButton.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.08)
            recordButton.layer.borderColor = UIColor.systemBlue.cgColor
        case .cancelReady:
            recordButton.setTitle("松开 取消", for: .normal)
            recordButton.backgroundColor = UIColor.systemRed.withAlphaComponent(0.08)
            recordButton.layer.borderColor = UIColor.systemRed.cgColor
        }
    }

    // MARK: - 消息列表

    private func appendMessage(_ message: VoiceMessage) {
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

    /// 将指定消息标记为已播放，并同步更新 cell 红点
    ///
    /// isPlayed 更新策略（对应 VoiceMessage 中的 Hashable 设计说明）：
    ///
    /// - 方案 A（未采用）：将更新后的 item 写入新 snapshot 并 apply。
    ///   由于 Hashable 仅基于 id，DiffableDataSource 无法感知 isPlayed 变化，
    ///   即使 apply 新 snapshot，cell provider 拿到的仍是 snapshot 内旧 item，
    ///   cell 不会刷新。若改为 id+isPlayed 的 Hashable，则会触发 delete+insert 闪烁。
    ///
    /// - 方案 B（当前采用）：在 messages 数组中直接修改 isPlayed，
    ///   不触发 snapshot diff，再通过 cellForMessage 直接调用 cell.markAsRead()。
    ///   cell provider 从 messages 数组查最新状态，保证复用时 isPlayed 也正确。
    ///
    /// - 方案 C（iOS 15+ 可升级）：用 snapshot.reconfigureItems 替代直接操作 cell。
    ///   将更新后的 item 替换进 snapshot（insertItems(afterItem:) + deleteItems），
    ///   调用 snapshot.reconfigureItems([newItem]) 后 apply，
    ///   DiffableDataSource 原地重新调用 cell provider，cell 从新 item 读取 isPlayed，
    ///   无需 messages 数组，也无需直接调用 cell.markAsRead()，数据驱动更彻底。
    ///   升级时只需重写本方法，其余代码不变：
    ///
    ///   ```swift
    ///   // iOS 15+ 实现示例
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
        cellForMessage(id: id)?.markAsRead()
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

    private func handlePlayTap(message: VoiceMessage) {
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

    private func resolveURL(for message: VoiceMessage) async throws -> URL {
        if let local = message.localURL  { return local }
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

    func cellDidTapPlay(_ cell: VoiceMessageCell, message: VoiceMessage) {
        handlePlayTap(message: message)
    }

    func cellDidSeek(_ cell: VoiceMessageCell, message: VoiceMessage, progress: Float) {
        guard player.isPlaying(id: message.id) else { return }
        player.seek(to: progress)
    }
}
