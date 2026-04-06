import UIKit

/// 消息列表数据源：封装 DiffableDataSource 和 snapshot 更新逻辑
///
/// # 职责
/// - 管理 UICollectionViewDiffableDataSource 的创建和配置
/// - 维护消息数组作为可变状态的真实来源（isPlayed、sendStatus 等字段）
/// - 提供消息增删改查的统一接口
/// - 处理历史消息插入时的滚动位置锚定
///
/// # 设计考量
/// 为什么需要独立的 messages 数组？
///   DiffableDataSource 的 snapshot 存储的是插入时的 item 副本，
///   后续对 isPlayed、sendStatus 的修改不会同步到 snapshot。
///   使用 reloadItems 触发 cell provider 重新执行时，
///   cell provider 收到的参数仍是 snapshot 内的旧值。
///   因此必须维护独立的 messages 数组作为可变状态的真实来源。
///
///   升级到 iOS 15 后可改用 reconfigureItems + insertItems/deleteItems，
///   届时可将新 item 写入 snapshot，messages 数组可移除。
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

    /// 追加消息到列表底部
    ///
    /// - Parameters:
    ///   - message: 要追加的消息
    ///   - animatingDifferences: 是否显示插入动画（默认 false，避免动画异常）
    func appendMessage(_ message: ChatMessage, animatingDifferences: Bool = false) {
        messages.append(message)

        var snapshot = dataSource.snapshot()
        snapshot.appendItems([message], toSection: .main)
        dataSource.apply(snapshot, animatingDifferences: animatingDifferences)
    }

    /// 在列表头部插入历史消息，并保持用户当前阅读位置不跳动
    ///
    /// # 滚动位置锚定原理
    /// 在头部插入 N 条消息后，内容总高度会增加 ΔH。
    /// 若不修正 contentOffset，UICollectionView 会将原来可见的内容向下推移 ΔH，
    /// 造成屏幕内容"跳动"。解决方式：
    ///   1. 记录 apply 前的 contentOffset.y 和 contentSize.height
    ///   2. apply(animatingDifferences: false) 同步完成后调用 layoutIfNeeded()
    ///      强制立即计算新 contentSize（否则 contentSize 在下一个 RunLoop 才更新）
    ///   3. 将 contentOffset.y 增加 ΔH，抵消内容下移，用户视线锚定不变
    func prependMessages(_ newMessages: [ChatMessage]) {
        guard !newMessages.isEmpty else { return }

        // 步骤 1：记录插入前的布局状态
        let oldHeight = collectionView.contentSize.height
        let oldOffsetY = collectionView.contentOffset.y

        // 同步更新可变状态真实来源
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

    /// 删除消息
    ///
    /// - Parameter id: 消息 ID
    /// - Returns: 被删除的消息（用于清理本地文件），若消息不存在则返回 nil
    func deleteMessage(id: String) -> ChatMessage? {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return nil }
        let message = messages[idx]
        messages.remove(at: idx)

        var snapshot = dataSource.snapshot()
        snapshot.deleteItems([message])
        dataSource.apply(snapshot, animatingDifferences: true)

        return message
    }

    /// 替换消息（用于撤回）
    ///
    /// 将原消息替换为新消息，保留在列表中的位置。
    /// 使用 insertItems + deleteItems 实现原地替换，带淡入淡出动画。
    ///
    /// - Parameters:
    ///   - id: 原消息 ID
    ///   - newMessage: 新消息（通常是 .recalled 类型）
    func replaceMessage(id: String, with newMessage: ChatMessage) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        let oldMessage = messages[idx]
        messages[idx] = newMessage

        var snapshot = dataSource.snapshot()
        if oldMessage.id == newMessage.id {
            // 同一业务主键仅更新内容时，必须走 reloadItems；
            // 直接 insert/delete 会被 Diffable 判定为同一标识冲突并崩溃。
            snapshot.reloadItems([oldMessage])
        } else {
            snapshot.insertItems([newMessage], afterItem: oldMessage)
            snapshot.deleteItems([oldMessage])
        }
        dataSource.apply(snapshot, animatingDifferences: true)
    }

    /// 标记消息为已播放
    ///
    /// # isPlayed 更新策略（iOS 13+）
    /// 步骤：
    ///   1. messages[idx].isPlayed = true（更新可变状态）
    ///   2. snapshot.reloadItems([messages[idx]])（标记该 item 需重新配置）
    ///   3. dataSource.apply(snapshot, animatingDifferences: false)
    ///   4. cell provider 重新执行，从 messages 数组读到 isPlayed: true
    ///   5. configure(isUnread: false) → cell 内部检测到状态从未读变已读，触发淡出动画
    ///
    /// 注意事项：
    ///   - reloadItems 只标记重载，不修改 snapshot 内存储的 item 本身
    ///   - cell provider 收到的参数仍是 snapshot 内的旧 item（isPlayed: false）
    ///   - 必须从 messages 数组查询最新状态，messages 数组不可省略
    ///   - animatingDifferences: false 避免 reloadItems 触发系统默认的 crossfade 动画，
    ///     红点淡出动画由 cell 内部的 configure 方法负责
    ///
    /// # iOS 15+ 可升级方案
    /// 使用 reconfigureItems + insertItems/deleteItems 将新 item 写入 snapshot：
    /// ```swift
    /// var snapshot = dataSource.snapshot()
    /// guard let old = snapshot.itemIdentifiers(inSection: .main)
    ///                         .first(where: { $0.id == id }), !old.isPlayed else { return }
    /// var updated = old
    /// updated.isPlayed = true
    /// snapshot.insertItems([updated], afterItem: old)
    /// snapshot.deleteItems([old])
    /// snapshot.reconfigureItems([updated])
    /// dataSource.apply(snapshot, animatingDifferences: false)
    /// ```
    /// 届时 messages 数组可移除。
    func markAsPlayed(id: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }),
              !messages[idx].isPlayed else { return }
        messages[idx].isPlayed = true
        var snapshot = dataSource.snapshot()
        snapshot.reloadItems([messages[idx]])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// 更新消息发送状态
    ///
    /// 用于模拟网络发送过程：sending → delivered/failed。
    /// 更新策略与 markAsPlayed 一致，通过 reloadItems 触发 cell 重新配置。
    ///
    /// - Parameters:
    ///   - id: 消息 ID
    ///   - status: 新的发送状态
    func updateSendStatus(id: String, status: ChatMessage.SendStatus) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].sendStatus = status

        var snapshot = dataSource.snapshot()
        snapshot.reloadItems([messages[idx]])
        dataSource.apply(snapshot, animatingDifferences: false)
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
