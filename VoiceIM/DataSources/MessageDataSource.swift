import UIKit

/// 消息列表数据源：封装 DiffableDataSource 和 snapshot 更新逻辑
///
/// # 职责
/// - 管理 UICollectionViewDiffableDataSource 的创建和配置
/// - 保存当前渲染快照（来自 ViewModel），作为 cell provider 的读取缓存
/// - 提供列表渲染与局部重绘能力
/// - 处理历史消息插入时的滚动位置锚定
///
/// # 设计考量
/// `messages` 仅作为当前 UI 渲染缓存，业务上的唯一真相源在 `ChatViewModel.messages`。
@MainActor
final class MessageDataSource: MessageDataSourceProtocol {

    // MARK: - Section

    private enum Section { case main }

    // MARK: - Properties

    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Section, ChatMessage>!

    /// 刷新指定消息的 Cell（用于播放状态变化）
    func reloadMessage(id: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        let message = messages[idx]
        var snapshot = dataSource.snapshot()
        snapshot.reloadItems([message])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// 消息数组（可变状态的真实来源）
    ///
    /// 存储所有消息的最新状态，包括：
    /// - isPlayed：是否已播放（控制红点显示）
    /// - sendStatus：发送状态（sending/delivered/failed）
    ///
    /// cell provider 从此数组查询最新状态，而非依赖 snapshot 内的旧值。
    private(set) var messages: [ChatMessage] = []

    // MARK: - Dependencies

    /// Cell 依赖注入（由 ViewController 提供）
    ///
    /// 包含播放状态查询、事件委托等外部依赖，
    /// 通过 `MessageCellDependencies` 统一传递给各类型 Cell。
    var dependencies: MessageCellDependencies?

    /// Cell 配置回调（用于设置重试按钮、上下文菜单等交互）
    ///
    /// 在 MessageDataSource 完成基础配置后调用，
    /// 由 ViewController 设置 Cell 的事件回调（重试、撤回点击等）。
    var cellConfigurator: ((UICollectionViewCell, ChatMessage) -> Void)?

    // MARK: - Init

    init(collectionView: UICollectionView) {
        self.collectionView = collectionView
        setupDataSource()
    }

    // MARK: - Setup

    private func setupDataSource() {
        dataSource = UICollectionViewDiffableDataSource<Section, ChatMessage>(
            collectionView: collectionView
        ) { [weak self] cv, indexPath, message in
            guard let self, let deps = self.dependencies else { return UICollectionViewCell() }

            // 从 messages 数组取最新状态，保证 isPlayed 等可变字段始终准确
            let current = self.messages.first(where: { $0.id == message.id }) ?? message

            // 计算上一条消息（用于时间分隔行判断）
            let currentIdx = self.messages.firstIndex(where: { $0.id == current.id }) ?? indexPath.item
            let prev = currentIdx > 0 ? self.messages[currentIdx - 1] : nil

            // 构造动态上下文
            let context = MessageCellContext(
                showTimeHeader: prev.map { current.sentAt.timeIntervalSince($0.sentAt) > 5 * 60 } ?? true,
                previousMessage: prev
            )

            // 统一配置：通过协议调用，无需类型判断
            let cell = cv.dequeueReusableCell(
                withReuseIdentifier: current.kind.reuseID,
                for: indexPath
            )

            if let configurableCell = cell as? MessageCellConfigurable {
                configurableCell.configure(with: current, deps: deps, context: context)
            }

            // 调用外部配置回调（设置交互事件）
            self.cellConfigurator?(cell, current)

            return cell
        }

        // 初始化空 snapshot
        var snapshot = NSDiffableDataSourceSnapshot<Section, ChatMessage>()
        snapshot.appendSections([.main])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Public Methods

    /// 根据 ViewModel 全量渲染消息列表。
    func render(messages: [ChatMessage], animatingDifferences: Bool = true) {
        self.messages = messages
        var snapshot = NSDiffableDataSourceSnapshot<Section, ChatMessage>()
        snapshot.appendSections([.main])
        snapshot.appendItems(messages, toSection: .main)
        dataSource.apply(snapshot, animatingDifferences: animatingDifferences)
    }

    /// 增量渲染：对新增/删除/更新做差分 apply，保留历史动画语义。
    func renderIncrementally(messages newMessages: [ChatMessage], preserveContentOffsetOnPrepend: Bool = false) {
        let oldMessages = self.messages
        let oldIDs = Set(oldMessages.map(\.id))
        let newIDs = Set(newMessages.map(\.id))

        var oldHeight: CGFloat = 0
        var oldOffsetY: CGFloat = 0
        if preserveContentOffsetOnPrepend {
            oldHeight = collectionView.contentSize.height
            oldOffsetY = collectionView.contentOffset.y
        }

        self.messages = newMessages

        var snapshot = dataSource.snapshot()

        // 删除已不存在消息
        let idsToDelete = oldIDs.subtracting(newIDs)
        if !idsToDelete.isEmpty {
            let itemsToDelete = snapshot.itemIdentifiers(inSection: .main).filter { idsToDelete.contains($0.id) }
            if !itemsToDelete.isEmpty {
                snapshot.deleteItems(itemsToDelete)
            }
        }

        // 新增消息：按顺序插入，尽量保留位置感知
        if !newMessages.isEmpty {
            let currentItems = snapshot.itemIdentifiers(inSection: .main)
            let currentIDSet = Set(currentItems.map(\.id))
            for (index, message) in newMessages.enumerated() where !currentIDSet.contains(message.id) {
                let prevNew = index > 0 ? newMessages[index - 1] : nil
                let nextNew = index + 1 < newMessages.count ? newMessages[index + 1] : nil
                if let prev = prevNew, snapshot.indexOfItem(prev) != nil {
                    snapshot.insertItems([message], afterItem: prev)
                } else if let next = nextNew, snapshot.indexOfItem(next) != nil {
                    snapshot.insertItems([message], beforeItem: next)
                } else {
                    snapshot.appendItems([message], toSection: .main)
                }
            }
        }

        // 已存在消息：内容变化时 reload。
        // 注意不能用 `ChatMessage ==` 判断，因为该等价关系只比较 `id`，
        // `sendStatus/isPlayed/kind` 变化会被误判为“未变化”，导致 UI 不刷新。
        let oldByID = Dictionary(uniqueKeysWithValues: oldMessages.map { ($0.id, $0) })
        let currentItems = snapshot.itemIdentifiers(inSection: .main)
        let itemsToReload = currentItems.filter { item in
            guard let old = oldByID[item.id],
                  let latest = newMessages.first(where: { $0.id == item.id }) else { return false }
            return hasRenderableChanges(from: old, to: latest)
        }
        if !itemsToReload.isEmpty {
            snapshot.reloadItems(itemsToReload)
        }

        dataSource.apply(snapshot, animatingDifferences: true)

        if preserveContentOffsetOnPrepend {
            // 历史前插时补偿偏移，避免用户正在阅读的可见内容“被向下顶走”。
            collectionView.layoutIfNeeded()
            let heightDiff = collectionView.contentSize.height - oldHeight
            collectionView.contentOffset.y = oldOffsetY + heightDiff
        }
    }

    /// `ChatMessage` 的 `==` 仅比较 `id`，这里显式比较影响渲染的字段。
    private func hasRenderableChanges(from old: ChatMessage, to latest: ChatMessage) -> Bool {
        old.kind.reuseID != latest.kind.reuseID
            || String(describing: old.kind) != String(describing: latest.kind)
            || old.isPlayed != latest.isPlayed
            || old.isRead != latest.isRead
            || old.sendStatus != latest.sendStatus
            || old.sentAt != latest.sentAt
            || old.sender.id != latest.sender.id
    }

    /// 查找消息索引
    func index(of id: String) -> Int? {
        messages.firstIndex(where: { $0.id == id })
    }

    /// 获取消息
    func message(at index: Int) -> ChatMessage? {
        guard index >= 0 && index < messages.count else { return nil }
        return messages[index]
    }
}
