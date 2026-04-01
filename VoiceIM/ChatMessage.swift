import Foundation

/// 通用消息数据模型
///
/// # 扩展新消息类型
/// 在 `Kind` 中追加 case，并在 `VoiceChatViewController` 的 cell provider 加对应分支即可。
/// 现有代码无需改动。
struct ChatMessage: Sendable, Hashable {

    // MARK: - 消息类型

    enum Kind: Sendable {
        case voice(localURL: URL?, remoteURL: URL?, duration: TimeInterval)
        case text(String)
        // 未来可追加：case image(URL)、case file(URL, name: String) …
    }

    // MARK: - 字段

    let id: UUID
    let kind: Kind
    /// 是否已播放；仅 voice 有意义，text 固定为 true
    var isPlayed: Bool

    // MARK: - Hashable（仅基于 id，与原 VoiceMessage 策略一致）
    //
    // isPlayed 变化不影响 item 唯一性，避免 DiffableDataSource 产生 delete/insert 动画。
    // 详细说明见原 VoiceMessage.swift 注释。

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // MARK: - 工厂方法

    /// 本地录制的语音消息
    static func voice(localURL: URL, duration: TimeInterval) -> Self {
        ChatMessage(id: UUID(),
                    kind: .voice(localURL: localURL, remoteURL: nil, duration: duration),
                    isPlayed: false)
    }

    /// 来自服务器的远程语音消息
    static func remoteVoice(id: UUID = UUID(),
                            remoteURL: URL,
                            duration: TimeInterval,
                            isPlayed: Bool = false) -> Self {
        ChatMessage(id: id,
                    kind: .voice(localURL: nil, remoteURL: remoteURL, duration: duration),
                    isPlayed: isPlayed)
    }

    /// 文本消息（无未读概念，isPlayed 固定 true）
    static func text(_ content: String) -> Self {
        ChatMessage(id: UUID(), kind: .text(content), isPlayed: true)
    }
}

// MARK: - 便利属性

extension ChatMessage {

    /// 语音时长（非语音消息返回 0）
    var duration: TimeInterval {
        if case .voice(_, _, let d) = kind { return d }
        return 0
    }

    /// 本地录音文件 URL
    var localURL: URL? {
        if case .voice(let u, _, _) = kind { return u }
        return nil
    }

    /// 远程语音 URL
    var remoteURL: URL? {
        if case .voice(_, let u, _) = kind { return u }
        return nil
    }
}
