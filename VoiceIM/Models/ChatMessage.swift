import Foundation

/// 通用消息数据模型
///
/// # 扩展新消息类型
/// 在 `Kind` 中追加 case，并在 `VoiceChatViewController` 的 cell provider 加对应分支即可。
/// 现有代码无需改动。
struct ChatMessage: Sendable, Hashable, Codable {

    // MARK: - 消息类型

    enum Kind: Sendable, Codable {
        case voice(localURL: URL?, remoteURL: URL?, duration: TimeInterval)
        case text(String)
        case image(localURL: URL?, remoteURL: URL?)
        case video(localURL: URL?, remoteURL: URL?, duration: TimeInterval)
        case recalled(originalText: String?)  // 撤回消息，保留原文本用于重新编辑
        case location(latitude: Double, longitude: Double, address: String?)  // 位置消息
        // 未来可追加：case file(URL, name: String) …
    }

    // MARK: - 发送状态

    /// 消息发送状态枚举
    ///
    /// 用于追踪消息从发送到送达的完整生命周期。
    /// 仅自己发送的消息（`isOutgoing = true`）会显示状态指示器，对方消息固定为 `.delivered`。
    ///
    /// # 状态流转
    /// 正常流程：`.sending` → `.delivered` → `.read`
    /// 异常流程：`.sending` → `.failed`（可重试，重新进入 `.sending`）
    ///
    /// # UI 展示
    /// - `.sending`：旋转的加载指示器（UIActivityIndicatorView）
    /// - `.delivered`：单勾（暂未实现 UI）
    /// - `.read`：双勾（暂未实现 UI）
    /// - `.failed`：红色感叹号图标，可点击重试
    enum SendStatus: Sendable, Codable {
        case sending    // 发送中 - 显示加载指示器
        case delivered  // 已送达 - 显示单勾（暂未实现 UI）
        case read       // 已读 - 显示双勾（暂未实现 UI）
        case failed     // 发送失败 - 显示错误图标，支持重试
    }

    // MARK: - 字段

    let id: UUID
    var kind: Kind  // 改为 var，支持撤回时修改
    let sender: Sender
    let sentAt: Date
    /// 是否已播放；仅 voice 有意义，text 固定为 true
    var isPlayed: Bool
    /// 发送状态；仅自己发送的消息（`isOutgoing = true`）有意义，对方消息固定为 `.delivered`
    ///
    /// # 注意事项
    /// - `sendStatus` 是可变字段，但不参与 `Hashable` 计算（仅基于 `id`）
    /// - 状态更新通过 `snapshot.reloadItems` 触发 cell 重新配置，详见 `VoiceChatViewController.simulateSendMessage`
    /// - 与 `isPlayed` 类似，需要维护独立的 `messages` 数组作为可变状态的真实来源
    var sendStatus: SendStatus

    /// 是否为当前用户发出的消息（决定气泡靠右/靠左）
    var isOutgoing: Bool { sender.id == Sender.me.id }

    // MARK: - Hashable（仅基于 id，与原 VoiceMessage 策略一致）
    //
    // isPlayed 变化不影响 item 唯一性，避免 DiffableDataSource 产生 delete/insert 动画。
    // 详细说明见原 VoiceMessage.swift 注释。

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // MARK: - 初始化

    init(
        id: UUID,
        kind: Kind,
        sender: Sender,
        sentAt: Date,
        isPlayed: Bool,
        sendStatus: SendStatus
    ) {
        self.id = id
        self.kind = kind
        self.sender = sender
        self.sentAt = sentAt
        self.isPlayed = isPlayed
        self.sendStatus = sendStatus
    }

    // MARK: - 工厂方法

    /// 本地录制的语音消息（发送方固定为自己）
    static func voice(localURL: URL, duration: TimeInterval,
                      sentAt: Date = Date()) -> Self {
        ChatMessage(id: UUID(),
                    kind: .voice(localURL: localURL, remoteURL: nil, duration: duration),
                    sender: .me, sentAt: sentAt, isPlayed: false, sendStatus: .sending)
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
                    sender: sender, sentAt: sentAt, isPlayed: isPlayed, sendStatus: .delivered)
    }

    /// 文本消息（无未读概念，isPlayed 固定 true）
    ///
    /// - Parameter sendStatus: 仅对自己发送的消息有效；为 `nil` 时自己为 `.sending`（刚发出）、对方固定 `.delivered`。历史/同步数据应传入 `.delivered`（或 `.read`）。
    static func text(
        _ content: String,
        sender: Sender = .me,
        sentAt: Date = Date(),
        sendStatus: SendStatus? = nil
    ) -> Self {
        let resolved: SendStatus
        if sender.id != Sender.me.id {
            resolved = .delivered
        } else if let sendStatus {
            resolved = sendStatus
        } else {
            resolved = .sending
        }
        return ChatMessage(
            id: UUID(),
            kind: .text(content),
            sender: sender,
            sentAt: sentAt,
            isPlayed: true,
            sendStatus: resolved
        )
    }

    /// 本地图片消息（发送方固定为自己）
    static func image(localURL: URL, sentAt: Date = Date()) -> Self {
        ChatMessage(id: UUID(),
                    kind: .image(localURL: localURL, remoteURL: nil),
                    sender: .me, sentAt: sentAt, isPlayed: true, sendStatus: .sending)
    }

    /// 来自服务器的远程图片消息
    static func remoteImage(id: UUID = UUID(),
                            remoteURL: URL,
                            sender: Sender = .peer,
                            sentAt: Date = Date()) -> Self {
        ChatMessage(id: id,
                    kind: .image(localURL: nil, remoteURL: remoteURL),
                    sender: sender, sentAt: sentAt, isPlayed: true, sendStatus: .delivered)
    }

    /// 本地视频消息（发送方固定为自己）
    static func video(localURL: URL, duration: TimeInterval, sentAt: Date = Date()) -> Self {
        ChatMessage(id: UUID(),
                    kind: .video(localURL: localURL, remoteURL: nil, duration: duration),
                    sender: .me, sentAt: sentAt, isPlayed: true, sendStatus: .sending)
    }

    /// 来自服务器的远程视频消息
    static func remoteVideo(id: UUID = UUID(),
                            remoteURL: URL,
                            duration: TimeInterval,
                            sender: Sender = .peer,
                            sentAt: Date = Date()) -> Self {
        ChatMessage(id: id,
                    kind: .video(localURL: nil, remoteURL: remoteURL, duration: duration),
                    sender: sender, sentAt: sentAt, isPlayed: true, sendStatus: .delivered)
    }

    /// 撤回消息（保留原文本用于重新编辑）
    static func recalled(originalText: String? = nil,
                         sender: Sender,
                         sentAt: Date = Date()) -> Self {
        ChatMessage(id: UUID(),
                    kind: .recalled(originalText: originalText),
                    sender: sender, sentAt: sentAt, isPlayed: true, sendStatus: .delivered)
    }

    /// 位置消息
    static func location(latitude: Double,
                         longitude: Double,
                         address: String? = nil,
                         sender: Sender = .me,
                         sentAt: Date = Date()) -> Self {
        ChatMessage(id: UUID(),
                    kind: .location(latitude: latitude, longitude: longitude, address: address),
                    sender: sender, sentAt: sentAt, isPlayed: true,
                    sendStatus: sender.id == Sender.me.id ? .sending : .delivered)
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
        case .image: return ImageMessageCell.reuseID
        case .video: return VideoMessageCell.reuseID
        case .recalled: return RecalledMessageCell.reuseID
        case .location: return LocationMessageCell.reuseID
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

// MARK: - Custom Codable Implementation

extension ChatMessage.Kind {

    enum CodingKeys: String, CodingKey {
        case type
        case fileName
        case remoteURL
        case duration
        case content
        case latitude
        case longitude
        case address
        case originalText
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .voice(let localURL, let remoteURL, let duration):
            try container.encode("voice", forKey: .type)
            // 只保存文件名，不保存完整路径
            if let localURL = localURL {
                try container.encode(localURL.lastPathComponent, forKey: .fileName)
            }
            try container.encodeIfPresent(remoteURL, forKey: .remoteURL)
            try container.encode(duration, forKey: .duration)

        case .image(let localURL, let remoteURL):
            try container.encode("image", forKey: .type)
            if let localURL = localURL {
                try container.encode(localURL.lastPathComponent, forKey: .fileName)
            }
            try container.encodeIfPresent(remoteURL, forKey: .remoteURL)

        case .video(let localURL, let remoteURL, let duration):
            try container.encode("video", forKey: .type)
            if let localURL = localURL {
                try container.encode(localURL.lastPathComponent, forKey: .fileName)
            }
            try container.encodeIfPresent(remoteURL, forKey: .remoteURL)
            try container.encode(duration, forKey: .duration)

        case .text(let content):
            try container.encode("text", forKey: .type)
            try container.encode(content, forKey: .content)

        case .recalled(let originalText):
            try container.encode("recalled", forKey: .type)
            try container.encodeIfPresent(originalText, forKey: .originalText)

        case .location(let latitude, let longitude, let address):
            try container.encode("location", forKey: .type)
            try container.encode(latitude, forKey: .latitude)
            try container.encode(longitude, forKey: .longitude)
            try container.encodeIfPresent(address, forKey: .address)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "voice":
            let fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
            let remoteURL = try container.decodeIfPresent(URL.self, forKey: .remoteURL)
            let duration = try container.decode(TimeInterval.self, forKey: .duration)

            // 根据文件名重新构建完整路径
            let localURL = fileName.map {
                FileStorageManager.getVoiceDirectory().appendingPathComponent($0)
            }

            self = .voice(localURL: localURL, remoteURL: remoteURL, duration: duration)

        case "image":
            let fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
            let remoteURL = try container.decodeIfPresent(URL.self, forKey: .remoteURL)

            let localURL = fileName.map {
                FileStorageManager.getImageDirectory().appendingPathComponent($0)
            }

            self = .image(localURL: localURL, remoteURL: remoteURL)

        case "video":
            let fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
            let remoteURL = try container.decodeIfPresent(URL.self, forKey: .remoteURL)
            let duration = try container.decode(TimeInterval.self, forKey: .duration)

            let localURL = fileName.map {
                FileStorageManager.getVideoDirectory().appendingPathComponent($0)
            }

            self = .video(localURL: localURL, remoteURL: remoteURL, duration: duration)

        case "text":
            let content = try container.decode(String.self, forKey: .content)
            self = .text(content)

        case "recalled":
            let originalText = try container.decodeIfPresent(String.self, forKey: .originalText)
            self = .recalled(originalText: originalText)

        case "location":
            let latitude = try container.decode(Double.self, forKey: .latitude)
            let longitude = try container.decode(Double.self, forKey: .longitude)
            let address = try container.decodeIfPresent(String.self, forKey: .address)
            self = .location(latitude: latitude, longitude: longitude, address: address)

        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown message type: \(type)"
            )
        }
    }
}
