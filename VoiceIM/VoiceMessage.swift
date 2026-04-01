import Foundation

/// 语音消息数据模型
struct VoiceMessage: Sendable, Hashable {

    // Hashable / Equatable 仅基于 id，满足 DiffableDataSource 的唯一性要求
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
