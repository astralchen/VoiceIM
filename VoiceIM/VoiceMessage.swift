import Foundation

/// 语音消息数据模型
struct VoiceMessage: Sendable, Hashable {

    // MARK: - Hashable 设计说明
    //
    // VoiceMessage 含有可变字段 isPlayed，而 NSDiffableDataSourceSnapshot 要求
    // ItemIdentifierType 符合 Hashable，hash/equal 的实现方式决定了"状态更新"如何触达 cell。
    // 以下三种方案经过对比，当前采用方案 B。
    //
    // ┌─────────────────────────────────────────────────────────────────────┐
    // │ 方案 A（未采用）：Hashable 基于 id + isPlayed                        │
    // ├─────────────────────────────────────────────────────────────────────┤
    // │ isPlayed 变化 → 新旧 item hash/equal 不同                            │
    // │ → DiffableDataSource 判定为「删除旧 item + 插入新 item」              │
    // │ → cell 产生 delete/insert 动画，视觉闪烁                             │
    // │ 若用 animatingDifferences: false 规避闪烁：                          │
    // │ → 整个列表触发类似 reloadData 的全量重绘，性能代价高                  │
    // └─────────────────────────────────────────────────────────────────────┘
    //
    // ┌─────────────────────────────────────────────────────────────────────┐
    // │ 方案 B（当前采用，iOS 13+）：Hashable 仅基于 id                       │
    // │                              + snapshot.reloadItems                  │
    // ├─────────────────────────────────────────────────────────────────────┤
    // │ isPlayed 变化不影响 item 唯一性，不触发 delete/insert                 │
    // │ 更新流程：                                                            │
    // │   1. 在 ViewController.messages 数组中修改 isPlayed                  │
    // │   2. 调用 snapshot.reloadItems([updatedItem])                        │
    // │   3. apply 后 DiffableDataSource 重新调用 cell provider               │
    // │   4. cell provider 从 messages 数组查最新 isPlayed → cell 原地更新    │
    // │ 局限：reloadItems 只标记重载，不更新 snapshot 内存储的 item 本身，     │
    // │       snapshot 内的 item 始终是插入时的旧值（isPlayed: false），       │
    // │       cell provider 参数也是旧值，必须借助 messages 数组提供最新状态。 │
    // │       因此 messages 数组无法省略，存在数据双份的问题。                 │
    // └─────────────────────────────────────────────────────────────────────┘
    //
    // ┌─────────────────────────────────────────────────────────────────────┐
    // │ 方案 C（iOS 15+ 可升级）：Hashable 仅基于 id                          │
    // │                           + snapshot.reconfigureItems                │
    // ├─────────────────────────────────────────────────────────────────────┤
    // │ reconfigureItems 是 iOS 15 专为"内容变化、identity 不变"设计的 API。  │
    // │ 更新流程：                                                            │
    // │   1. insertItems(afterItem:) + deleteItems 将新 item 替换进 snapshot  │
    // │   2. reconfigureItems([newItem]) 标记原地重配                         │
    // │   3. apply 后 cell provider 收到新 item，直接读 isPlayed              │
    // │ 优势：snapshot 成为唯一数据源，messages 数组可完全移除，              │
    // │       cell provider 无需查外部数组，数据驱动更彻底。                  │
    // │ 升级时只需改动 VoiceChatViewController.markAsPlayed，其余代码不变。   │
    // └─────────────────────────────────────────────────────────────────────┘
    static func == (lhs: VoiceMessage, rhs: VoiceMessage) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    let id: UUID
    /// 本地录制文件 URL（自己录制的消息）
    let localURL: URL?
    /// 远程服务器 URL（收到的消息）
    let remoteURL: URL?
    /// 录音时长（秒）
    let duration: TimeInterval
    /// 是否已播放（默认 false，供持久化使用）
    var isPlayed: Bool

    /// 本地录制的语音消息
    init(localURL: URL, duration: TimeInterval) {
        self.id = UUID()
        self.localURL = localURL
        self.remoteURL = nil
        self.duration = duration
        self.isPlayed = false
    }

    /// 来自服务器的远程语音消息
    init(id: UUID = UUID(), remoteURL: URL, duration: TimeInterval, isPlayed: Bool = false) {
        self.id = id
        self.localURL = nil
        self.remoteURL = remoteURL
        self.duration = duration
        self.isPlayed = isPlayed
    }
}
