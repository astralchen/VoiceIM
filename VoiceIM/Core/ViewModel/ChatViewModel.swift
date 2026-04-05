import Foundation
import Combine

/// 聊天 ViewModel：管理聊天页面的所有状态
///
/// # 职责
/// - 管理消息列表状态
/// - 管理播放状态
/// - 管理录音状态
/// - 处理用户交互事件
/// - 协调 Repository 和 Service
///
/// # 设计模式
/// MVVM 模式，ViewController 订阅 @Published 属性，响应式更新 UI
@MainActor
final class ChatViewModel: ObservableObject {

    // MARK: - Published Properties

    /// 消息列表
    @Published private(set) var messages: [ChatMessage] = []

    /// 正在播放的消息 ID
    @Published private(set) var playingMessageID: UUID?

    /// 播放进度（0.0 ~ 1.0）
    @Published private(set) var playbackProgress: Float = 0

    /// 是否正在录音
    @Published private(set) var isRecording: Bool = false

    /// 录音时长（秒）
    @Published private(set) var recordingDuration: Int = 0

    /// 错误信息
    @Published var error: ChatError?

    // MARK: - Dependencies

    private let repository: MessageRepository
    let playbackService: AudioPlaybackService  // 改为 internal，供 ViewController 使用
    private let recordService: AudioRecordService
    private let logger: Logger

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(
        repository: MessageRepository,
        playbackService: AudioPlaybackService,
        recordService: AudioRecordService,
        logger: Logger = VoiceIM.logger
    ) {
        self.repository = repository
        self.playbackService = playbackService
        self.recordService = recordService
        self.logger = logger

        setupPlaybackCallbacks()
        loadMessages()
    }

    // MARK: - Message Operations

    /// 加载消息列表
    func loadMessages() {
        do {
            messages = try repository.loadMessages()
            logger.info("Loaded \(messages.count) messages")

            // 调试：检查每条消息的文件路径
            for message in messages {
                switch message.kind {
                case .voice(let localURL, _, _):
                    logger.debug("Voice message: \(message.id)")
                    logger.debug("  localURL: \(String(describing: localURL))")
                    if let url = localURL {
                        let exists = FileManager.default.fileExists(atPath: url.path)
                        logger.debug("  file exists: \(exists)")
                    }
                case .image(let localURL, _):
                    logger.debug("Image message: \(message.id)")
                    logger.debug("  localURL: \(String(describing: localURL))")
                    if let url = localURL {
                        let exists = FileManager.default.fileExists(atPath: url.path)
                        logger.debug("  file exists: \(exists)")
                    }
                case .video(let localURL, _, _):
                    logger.debug("Video message: \(message.id)")
                    logger.debug("  localURL: \(String(describing: localURL))")
                    if let url = localURL {
                        let exists = FileManager.default.fileExists(atPath: url.path)
                        logger.debug("  file exists: \(exists)")
                    }
                default:
                    break
                }
            }
        } catch {
            logger.error("Failed to load messages: \(error)")
            self.error = error as? ChatError ?? .unknown(error)
        }
    }

    /// 发送文本消息
    ///
    /// - Parameter text: 文本内容
    func sendTextMessage(_ text: String) {
        do {
            let message = try repository.sendTextMessage(text: text)
            messages.append(message)
            logger.info("Sent text message: \(message.id)")

            // 模拟网络发送
            simulateSendMessage(id: message.id)
        } catch {
            logger.error("Failed to send text message: \(error)")
            self.error = error as? ChatError ?? .unknown(error)
        }
    }

    /// 发送语音消息
    ///
    /// - Parameters:
    ///   - url: 录音文件 URL
    ///   - duration: 录音时长
    func sendVoiceMessage(url: URL, duration: TimeInterval) {
        do {
            let message = try repository.sendVoiceMessage(tempURL: url, duration: duration)
            messages.append(message)
            logger.info("Sent voice message: \(message.id)")

            // 模拟网络发送
            simulateSendMessage(id: message.id)
        } catch {
            logger.error("Failed to send voice message: \(error)")
            self.error = error as? ChatError ?? .unknown(error)
        }
    }

    /// 发送图片消息
    ///
    /// - Parameter url: 图片文件 URL
    func sendImageMessage(url: URL) {
        do {
            let message = try repository.sendImageMessage(tempURL: url)
            messages.append(message)
            logger.info("Sent image message: \(message.id)")

            // 模拟网络发送
            simulateSendMessage(id: message.id)
        } catch {
            logger.error("Failed to send image message: \(error)")
            self.error = error as? ChatError ?? .unknown(error)
        }
    }

    /// 发送视频消息
    ///
    /// - Parameters:
    ///   - url: 视频文件 URL
    ///   - duration: 视频时长
    func sendVideoMessage(url: URL, duration: TimeInterval) {
        do {
            let message = try repository.sendVideoMessage(tempURL: url, duration: duration)
            messages.append(message)
            logger.info("Sent video message: \(message.id)")

            // 模拟网络发送
            simulateSendMessage(id: message.id)
        } catch {
            logger.error("Failed to send video message: \(error)")
            self.error = error as? ChatError ?? .unknown(error)
        }
    }

    /// 发送位置消息
    ///
    /// - Parameters:
    ///   - latitude: 纬度
    ///   - longitude: 经度
    ///   - address: 地址
    func sendLocationMessage(latitude: Double, longitude: Double, address: String?) {
        do {
            let message = try repository.sendLocationMessage(latitude: latitude, longitude: longitude, address: address)
            messages.append(message)
            logger.info("Sent location message: \(message.id)")

            // 模拟网络发送
            simulateSendMessage(id: message.id)
        } catch {
            logger.error("Failed to send location message: \(error)")
            self.error = error as? ChatError ?? .unknown(error)
        }
    }

    /// 删除消息
    ///
    /// - Parameter id: 消息 ID
    func deleteMessage(id: UUID) {
        do {
            try repository.deleteMessage(id: id)
            messages.removeAll { $0.id == id }
            logger.info("Deleted message: \(id)")
        } catch {
            logger.error("Failed to delete message: \(error)")
            self.error = error as? ChatError ?? .unknown(error)
        }
    }

    /// 撤回消息
    ///
    /// - Parameter id: 消息 ID
    func recallMessage(id: UUID) {
        do {
            try repository.recallMessage(id: id)

            // 更新本地消息列表
            if let index = messages.firstIndex(where: { $0.id == id }) {
                let originalText: String?
                if case .text(let content) = messages[index].kind {
                    originalText = content
                } else {
                    originalText = nil
                }

                messages[index].kind = .recalled(originalText: originalText)
            }

            logger.info("Recalled message: \(id)")
        } catch {
            logger.error("Failed to recall message: \(error)")
            self.error = error as? ChatError ?? .unknown(error)
        }
    }

    /// 重试发送失败的消息
    ///
    /// - Parameter id: 消息 ID
    func retryMessage(id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let message = messages[index]

        // 删除失败的消息
        messages.remove(at: index)

        // 根据类型重新发送
        switch message.kind {
        case .text(let content):
            sendTextMessage(content)
        case .voice(let localURL, _, let duration):
            if let url = localURL {
                sendVoiceMessage(url: url, duration: duration)
            }
        case .image(let localURL, _):
            if let url = localURL {
                sendImageMessage(url: url)
            }
        case .video(let localURL, _, let duration):
            if let url = localURL {
                sendVideoMessage(url: url, duration: duration)
            }
        case .location(let lat, let lon, let address):
            sendLocationMessage(latitude: lat, longitude: lon, address: address)
        case .recalled:
            break
        }
    }

    /// 标记消息为已播放
    ///
    /// - Parameter id: 消息 ID
    func markAsPlayed(id: UUID) {
        do {
            try repository.markAsPlayed(id: id)

            // 更新本地消息列表
            if let index = messages.firstIndex(where: { $0.id == id }) {
                messages[index].isPlayed = true
            }

            logger.debug("Marked message \(id) as played")
        } catch {
            logger.error("Failed to mark message as played: \(error)")
        }
    }

    // MARK: - Playback Operations

    /// 播放语音消息
    ///
    /// - Parameter id: 消息 ID
    func playVoiceMessage(id: UUID) {
        guard let message = messages.first(where: { $0.id == id }),
              case .voice(let localURL, _, _) = message.kind,
              let url = localURL else { return }

        do {
            try playbackService.play(id: id, url: url)
            playingMessageID = id

            // 标记为已播放
            if !message.isPlayed && !message.isOutgoing {
                markAsPlayed(id: id)
            }
        } catch {
            logger.error("Failed to play voice message: \(error)")
            self.error = .playbackStartFailed
        }
    }

    /// 停止播放
    func stopPlayback() {
        playbackService.stopCurrent()
        playingMessageID = nil
        playbackProgress = 0
    }

    // MARK: - Private Methods

    /// 设置播放回调
    private func setupPlaybackCallbacks() {
        // TODO: 实现播放进度回调
        // 需要 AudioPlaybackService 支持 Combine 或回调
    }

    /// 模拟网络发送（开发阶段）
    private func simulateSendMessage(id: UUID) {
        Task {
            // 模拟网络延迟
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            // 70% 成功率
            let success = Double.random(in: 0...1) < 0.7

            do {
                if success {
                    try repository.updateSendStatus(id: id, status: .delivered)
                    if let index = messages.firstIndex(where: { $0.id == id }) {
                        messages[index].sendStatus = .delivered
                    }
                } else {
                    try repository.updateSendStatus(id: id, status: .failed)
                    if let index = messages.firstIndex(where: { $0.id == id }) {
                        messages[index].sendStatus = .failed
                    }
                }
            } catch {
                logger.error("Failed to update send status: \(error)")
            }
        }
    }
}
