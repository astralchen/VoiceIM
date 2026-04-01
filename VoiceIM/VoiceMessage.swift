import Foundation

/// 语音消息数据模型
struct VoiceMessage: Sendable, Hashable {

    // MARK: - Hashable 设计说明
    //
    // 【方案 A - 未采用】Hashable 基于 id + isPlayed
    //   当 isPlayed 从 false 变为 true 时，新旧 item 的 hash/equal 不同，
    //   DiffableDataSource 会将其视为「删除旧 item + 插入新 item」，
    //   导致 cell 产生 delete/insert 动画，视觉上出现闪烁。
    //   若用 animatingDifferences: false 规避闪烁，则整个列表会触发 reloadData，代价较高。
    //
    // 【方案 B - 当前采用】Hashable 仅基于 id
    //   isPlayed 变化不影响 item 的唯一性，DiffableDataSource 不会产生额外的删除/插入。
    //   更新已播放状态时，在 ViewController 的 messages 数组中修改 isPlayed，
    //   再直接刷新对应 cell（markAsRead），实现原地更新、无闪烁。
    //
    // 【方案 C - iOS 15+ 可升级】Hashable 仅基于 id + snapshot.reconfigureItems
    //   reconfigureItems 是 iOS 15 引入的 API，专为"item 内容变化但 identity 不变"的场景设计。
    //   流程：将 isPlayed 更新后的新 item 替换进 snapshot（insertAfter + delete），
    //   调用 snapshot.reconfigureItems([newItem]) 再 apply，
    //   DiffableDataSource 原地调用 cell provider，cell 从新 item 读 isPlayed，无 delete/insert 动画。
    //   优势：snapshot 成为唯一数据源，可移除 ViewController 中的 messages 数组，
    //         也无需直接操作 cell（markAsRead），数据驱动更彻底。
    //   升级时只需改动 markAsPlayed 方法，其余逻辑不变。
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
