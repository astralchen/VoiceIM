import Foundation

/// Cell ViewModel 基类
///
/// 封装 Cell 所需的所有数据和状态，简化 Cell 配置逻辑。
protocol MessageCellViewModel {
    var message: ChatMessage { get }
    var showTimeHeader: Bool { get }
}

/// 语音消息 Cell ViewModel
struct VoiceMessageCellViewModel: MessageCellViewModel {
    let message: ChatMessage
    let showTimeHeader: Bool
    let isPlaying: Bool
    let progress: Float
    let isUnread: Bool

    init(message: ChatMessage, context: MessageCellContext, playbackState: PlaybackState) {
        self.message = message
        self.showTimeHeader = context.showTimeHeader
        self.isPlaying = playbackState.isPlaying(message.id)
        self.progress = playbackState.currentProgress(message.id)
        self.isUnread = !message.isPlayed && !message.isOutgoing
    }
}

/// 文本消息 Cell ViewModel
struct TextMessageCellViewModel: MessageCellViewModel {
    let message: ChatMessage
    let showTimeHeader: Bool
    let content: String

    init(message: ChatMessage, context: MessageCellContext) {
        self.message = message
        self.showTimeHeader = context.showTimeHeader

        if case .text(let text) = message.kind {
            self.content = text
        } else {
            self.content = ""
        }
    }
}

/// 图片消息 Cell ViewModel
struct ImageMessageCellViewModel: MessageCellViewModel {
    let message: ChatMessage
    let showTimeHeader: Bool
    let imageURL: URL?

    init(message: ChatMessage, context: MessageCellContext) {
        self.message = message
        self.showTimeHeader = context.showTimeHeader

        if case .image(let localURL, let remoteURL) = message.kind {
            self.imageURL = localURL ?? remoteURL
        } else {
            self.imageURL = nil
        }
    }
}

/// 视频消息 Cell ViewModel
struct VideoMessageCellViewModel: MessageCellViewModel {
    let message: ChatMessage
    let showTimeHeader: Bool
    let videoURL: URL?
    let duration: TimeInterval

    init(message: ChatMessage, context: MessageCellContext) {
        self.message = message
        self.showTimeHeader = context.showTimeHeader

        if case .video(let localURL, let remoteURL, let dur) = message.kind {
            self.videoURL = localURL ?? remoteURL
            self.duration = dur
        } else {
            self.videoURL = nil
            self.duration = 0
        }
    }
}

/// 撤回消息 Cell ViewModel
struct RecalledMessageCellViewModel: MessageCellViewModel {
    let message: ChatMessage
    let showTimeHeader: Bool
    let originalText: String?
    let canReEdit: Bool

    init(message: ChatMessage, context: MessageCellContext) {
        self.message = message
        self.showTimeHeader = context.showTimeHeader

        if case .recalled(let text) = message.kind {
            self.originalText = text
            self.canReEdit = message.isOutgoing && text != nil
        } else {
            self.originalText = nil
            self.canReEdit = false
        }
    }
}

/// 位置消息 Cell ViewModel
struct LocationMessageCellViewModel: MessageCellViewModel {
    let message: ChatMessage
    let showTimeHeader: Bool
    let latitude: Double
    let longitude: Double
    let address: String?

    init(message: ChatMessage, context: MessageCellContext) {
        self.message = message
        self.showTimeHeader = context.showTimeHeader

        if case .location(let lat, let lon, let addr) = message.kind {
            self.latitude = lat
            self.longitude = lon
            self.address = addr
        } else {
            self.latitude = 0
            self.longitude = 0
            self.address = nil
        }
    }
}

/// 播放状态查询接口
struct PlaybackState {
    let isPlaying: (UUID) -> Bool
    let currentProgress: (UUID) -> Float
}
