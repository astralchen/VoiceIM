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
    let sender: Sender
    let sentAt: Date
    /// 是否已播放；仅 voice 有意义，text 固定为 true
    var isPlayed: Bool

    /// 是否为当前用户发出的消息（决定气泡靠右/靠左）
    var isOutgoing: Bool { sender.id == Sender.me.id }

    // MARK: - Hashable（仅基于 id，与原 VoiceMessage 策略一致）
    //
    // isPlayed 变化不影响 item 唯一性，避免 DiffableDataSource 产生 delete/insert 动画。
    // 详细说明见原 VoiceMessage.swift 注释。

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // MARK: - 工厂方法

    /// 本地录制的语音消息（发送方固定为自己）
    static func voice(localURL: URL, duration: TimeInterval,
                      sentAt: Date = Date()) -> Self {
        ChatMessage(id: UUID(),
                    kind: .voice(localURL: localURL, remoteURL: nil, duration: duration),
                    sender: .me, sentAt: sentAt, isPlayed: false)
    }

    /// 来自服务器的远程语音消息
    static func remoteVoice(id: UUID = UUID(),
                            remoteURL: URL,
                            duration: TimeInterval,
                            isPlayed: Bool = false,
                            sender: Sender = .peer,
                            sentAt: Date = Date()) -> Self {
        ChatMessage(id: id,
                    kind: .voice(localURL: nil, remoteURL: remoteURL, duration: duration),
                    sender: sender, sentAt: sentAt, isPlayed: isPlayed)
    }

    /// 文本消息（无未读概念，isPlayed 固定 true）
    static func text(_ content: String,
                     sender: Sender = .me,
                     sentAt: Date = Date()) -> Self {
        ChatMessage(id: UUID(), kind: .text(content),
                    sender: sender, sentAt: sentAt, isPlayed: true)
    }
}

// MARK: - Cell 路由

extension ChatMessage.Kind {

    /// 与此消息类型对应的 Cell 复用 ID。
    ///
    /// 新增消息类型时在此追加 `case`；若遗漏，编译器会在 `switch` 处报错，
    /// 确保 cell provider 与注册列表始终保持同步。
    var reuseID: String {
        switch self {
        case .voice: return VoiceMessageCell.reuseID
        case .text:  return TextMessageCell.reuseID
        }
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
