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

    /// 错误信息
    @Published var error: ChatError?
    let contact: Contact
    let conversationID: String

    // MARK: - Dependencies

    private let repository: MessageRepository
    let playbackService: AudioPlaybackService  // internal，供 ViewController 使用
    /// 语音与全屏视频互斥；供视频预览页注册/视频起播前停语音
    let mediaPlaybackCoordinator: MediaPlaybackCoordinator
    let recordService: AudioRecordService  // internal，供 ViewController 使用
    let photoPickerService: PhotoPickerService  // internal，供 ViewController 使用
    let errorHandler: ErrorHandler  // internal，供 ViewController 使用
    /// 远程语音落盘缓存（本地文件存在时不会调用）
    private let voiceFileCache: any FileCacheService
    private let logger: Logger

    // MARK: - Private Properties

    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var hasLoadedInitialMessages = false
    private var isLoadingMessages = false
    private let initialRecentMessageLimit = 5

    // MARK: - Init

    /// - Parameter voiceFileCache: 仅用于「仅有 `remoteURL`」的语音：`resolve` 下载到缓存目录后再交给 `playbackService`。由 `AppDependencies.makeChatViewModel` 传入 `VoiceCacheManager`。
    init(
        contact: Contact,
        repository: MessageRepository,
        playbackService: AudioPlaybackService,
        mediaPlaybackCoordinator: MediaPlaybackCoordinator,
        recordService: AudioRecordService,
        photoPickerService: PhotoPickerService,
        errorHandler: ErrorHandler,
        voiceFileCache: any FileCacheService = VoiceCacheManager.shared,
        logger: Logger = VoiceIM.logger
    ) {
        self.contact = contact
        self.repository = repository
        self.conversationID = repository.conversationID
        self.playbackService = playbackService
        self.mediaPlaybackCoordinator = mediaPlaybackCoordinator
        self.recordService = recordService
        self.photoPickerService = photoPickerService
        self.errorHandler = errorHandler
        self.voiceFileCache = voiceFileCache
        self.logger = logger

        setupPlaybackCallbacks()
    }

    // MARK: - Message Operations

    /// 首次进入会话时加载消息；已加载过则跳过，避免重复全量拉取。
    func loadInitialIfNeeded() {
        guard !hasLoadedInitialMessages else { return }
        performLoadMessages(force: false)
    }

    /// 显式刷新消息（例如手动下拉刷新/重连后同步）。
    func refreshMessages() {
        performLoadMessages(force: true)
    }

    /// 兼容旧调用，等价于首次按需加载。
    func loadMessages() {
        loadInitialIfNeeded()
    }

    private func performLoadMessages(force: Bool) {
        guard force || !hasLoadedInitialMessages else { return }
        guard !isLoadingMessages else { return }
        isLoadingMessages = true
        let taskID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                isLoadingMessages = false
                activeTasks.removeValue(forKey: taskID)
            }
            do {
                // 生产化策略：首屏先拉最近 N 条，历史通过分页逐步补齐。
                let loaded = try await repository.loadRecentMessages(limit: initialRecentMessageLimit)
                guard !Task.isCancelled else { return }
                messages = loaded
                hasLoadedInitialMessages = true
                try? await repository.markConversationAsRead()
                for index in messages.indices where !messages[index].isOutgoing {
                    messages[index].isRead = true
                }
                logger.info("Loaded \(messages.count) messages")
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("Failed to load messages: \(error)")
                self.error = error as? ChatError ?? .unknown(error)
            }
        }
        activeTasks[taskID] = task
    }

    /// 取消所有进行中的异步任务（页面销毁时调用）
    func cancelActiveTasks() {
        activeTasks.values.forEach { $0.cancel() }
        activeTasks.removeAll()
    }

    /// 发送文本消息
    ///
    /// - Parameter text: 文本内容
    func sendTextMessage(_ text: String) {
        Task {
            do {
                let message = try await repository.sendTextMessage(text: text)
                messages.append(message)
                logger.info("Sent text message: \(message.id)")

                // 发送到服务器
                sendMessageToServer(id: message.id)
            } catch {
                logger.error("Failed to send text message: \(error)")
                self.error = error as? ChatError ?? .unknown(error)
            }
        }
    }

    /// 发送语音消息
    ///
    /// - Parameters:
    ///   - url: 录音文件 URL
    ///   - duration: 录音时长
    func sendVoiceMessage(url: URL, duration: TimeInterval) {
        Task {
            do {
                let message = try await repository.sendVoiceMessage(tempURL: url, duration: duration)
                messages.append(message)
                logger.info("Sent voice message: \(message.id)")

                // 发送到服务器
                sendMessageToServer(id: message.id)
            } catch {
                logger.error("Failed to send voice message: \(error)")
                self.error = error as? ChatError ?? .unknown(error)
            }
        }
    }

    /// 发送图片消息
    ///
    /// - Parameter url: 图片文件 URL
    func sendImageMessage(url: URL) {
        Task {
            do {
                let message = try await repository.sendImageMessage(tempURL: url)
                messages.append(message)
                logger.info("Sent image message: \(message.id)")

                // 发送到服务器
                sendMessageToServer(id: message.id)
            } catch {
                logger.error("Failed to send image message: \(error)")
                self.error = error as? ChatError ?? .unknown(error)
            }
        }
    }

    /// 发送视频消息
    ///
    /// - Parameters:
    ///   - url: 视频文件 URL
    ///   - duration: 视频时长
    func sendVideoMessage(url: URL, duration: TimeInterval) {
        Task {
            do {
                let message = try await repository.sendVideoMessage(tempURL: url, duration: duration)
                messages.append(message)
                logger.info("Sent video message: \(message.id)")

                // 发送到服务器
                sendMessageToServer(id: message.id)
            } catch {
                logger.error("Failed to send video message: \(error)")
                self.error = error as? ChatError ?? .unknown(error)
            }
        }
    }

    /// 发送位置消息
    ///
    /// - Parameters:
    ///   - latitude: 纬度
    ///   - longitude: 经度
    ///   - address: 地址
    func sendLocationMessage(latitude: Double, longitude: Double, address: String?) {
        Task {
            do {
                let message = try await repository.sendLocationMessage(latitude: latitude, longitude: longitude, address: address)
                messages.append(message)
                logger.info("Sent location message: \(message.id)")

                // 发送到服务器
                sendMessageToServer(id: message.id)
            } catch {
                logger.error("Failed to send location message: \(error)")
                self.error = error as? ChatError ?? .unknown(error)
            }
        }
    }

    /// 删除消息
    ///
    /// - Parameter id: 消息 ID
    func deleteMessage(id: String) {
        Task {
            do {
                try await repository.deleteMessage(id: id)
                messages.removeAll { $0.id == id }
                logger.info("Deleted message: \(id)")
            } catch {
                logger.error("Failed to delete message: \(error)")
                self.error = error as? ChatError ?? .unknown(error)
            }
        }
    }

    /// 撤回消息
    ///
    /// - Parameter id: 消息 ID
    func recallMessage(id: String) {
        Task {
            do {
                try await repository.recallMessage(id: id)

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
    }

    /// 重试发送失败的消息
    ///
    /// - Parameter id: 消息 ID
    func retryMessage(id: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let message = messages[index]

        switch message.kind {
        case .voice(let localURL, _, _), .image(let localURL, _), .video(let localURL, _, _):
            if localURL == nil {
                Task {
                    try? await repository.updateSendStatus(id: id, status: .failed)
                    if let i = messages.firstIndex(where: { $0.id == id }) {
                        messages[i].sendStatus = .failed
                    }
                }
                return
            }
        case .recalled:
            return
        default:
            break
        }

        messages[index].sendStatus = .sending

        Task {
            do {
                try await repository.updateSendStatus(id: id, status: .sending)
            } catch {
                logger.error("Failed to update send status to sending: \(error)")
                if let i = messages.firstIndex(where: { $0.id == id }) {
                    messages[i].sendStatus = .failed
                }
                return
            }

            let msg = message
            var tempResendURL: URL?
            defer {
                if let t = tempResendURL {
                    try? FileManager.default.removeItem(at: t)
                }
            }

            do {
                switch msg.kind {
                case .voice(let localURL, _, _), .image(let localURL, _), .video(let localURL, _, _):
                    if let src = localURL {
                        let ext = src.pathExtension.isEmpty ? "dat" : src.pathExtension
                        let dst = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString)
                            .appendingPathExtension(ext)
                        try FileManager.default.copyItem(at: src, to: dst)
                        tempResendURL = dst
                    }
                default:
                    break
                }

                try await repository.deleteMessage(id: id)
                messages.removeAll { $0.id == id }

                let newMessage: ChatMessage
                switch msg.kind {
                case .text(let content):
                    newMessage = try await repository.sendTextMessage(text: content)
                case .voice(_, _, let duration):
                    guard let url = tempResendURL else { throw ChatError.messageSendFailed }
                    newMessage = try await repository.sendVoiceMessage(tempURL: url, duration: duration)
                case .image:
                    guard let url = tempResendURL else { throw ChatError.messageSendFailed }
                    newMessage = try await repository.sendImageMessage(tempURL: url)
                case .video(_, _, let duration):
                    guard let url = tempResendURL else { throw ChatError.messageSendFailed }
                    newMessage = try await repository.sendVideoMessage(tempURL: url, duration: duration)
                case .location(let lat, let lon, let address):
                    newMessage = try await repository.sendLocationMessage(
                        latitude: lat,
                        longitude: lon,
                        address: address
                    )
                case .recalled:
                    return
                }

                messages.append(newMessage)
                sendMessageToServer(id: newMessage.id)
            } catch {
                logger.error("Failed to retry message: \(error)")
                self.error = error as? ChatError ?? .unknown(error)
                try? await repository.updateSendStatus(id: id, status: .failed)
                if let i = messages.firstIndex(where: { $0.id == id }) {
                    messages[i].sendStatus = .failed
                }
            }
        }
    }

    /// 标记消息为已播放
    ///
    /// - Parameter id: 消息 ID
    func markAsPlayed(id: String) {
        Task {
            do {
                try await repository.markAsPlayed(id: id)

                // 更新本地消息列表
                if let index = messages.firstIndex(where: { $0.id == id }) {
                    messages[index].isPlayed = true
                    messages[index].isRead = true
                }

                logger.debug("Marked message \(id) as played")
            } catch {
                logger.error("Failed to mark message as played: \(error)")
            }
        }
    }

    // MARK: - History Loading

    /// 按锚点加载历史消息
    ///
    /// - Parameter beforeMessageID: 当前最老可见消息 ID；为 nil 时返回最近一页
    /// - Returns: 历史消息列表（旧 -> 新）
    func loadHistory(beforeMessageID: String?, limit: Int = 20) async throws -> [ChatMessage] {
        do {
            let historyMessages = try await repository.loadHistory(
                beforeMessageID: beforeMessageID,
                limit: limit
            )
            logger.info("Loaded \(historyMessages.count) history messages before \(beforeMessageID ?? "nil")")
            return historyMessages
        } catch {
            logger.error("Failed to load history: \(error)")
            throw error
        }
    }

    /// 将历史消息并入当前列表头部（去重），保持 `messages` 作为唯一真相源。
    func prependHistoryMessages(_ historyMessages: [ChatMessage]) {
        guard !historyMessages.isEmpty else { return }
        let existingIDs = Set(messages.map(\.id))
        let deduped = historyMessages.filter { !existingIDs.contains($0.id) }
        guard !deduped.isEmpty else { return }
        messages.insert(contentsOf: deduped, at: 0)
    }

    // MARK: - Playback Operations

    /// 播放语音消息
    ///
    /// 优先播放本地文件；本地不存在且有 `remoteURL` 时先经 `voiceFileCache` 下载再播放。
    ///
    /// - Parameter id: 消息 ID
    func playVoiceMessage(id: String) {
        guard let message = messages.first(where: { $0.id == id }),
              case .voice(let localURL, let remoteURL, _) = message.kind else { return }

        // `resolve` 为异步下载，必须在 Task 中执行；播放与 UI 状态仍在主 actor 上更新
        Task {
            mediaPlaybackCoordinator.willBeginVoicePlayback()

            let playURL: URL
            // 发送方本地 m4a 或已落盘的接收方文件
            if let local = localURL, FileManager.default.fileExists(atPath: local.path) {
                playURL = local
            } else if let remote = remoteURL {
                // 仅远程 URL：经 `FileCacheService`（默认 `VoiceCacheManager`）下载到 `Caches/.../IMVoiceCache` 再播
                do {
                    playURL = try await voiceFileCache.resolve(remote)
                } catch {
                    logger.error("远程语音缓存失败: \(error)")
                    self.error = .playbackStartFailed
                    return
                }
            } else {
                logger.error("语音消息无可用本地或远程 URL")
                return
            }

            do {
                try playbackService.play(id: id, url: playURL)

                if !message.isPlayed && !message.isOutgoing {
                    markAsPlayed(id: id)
                }
            } catch {
                logger.error("Failed to play voice message: \(error)")
                self.error = .playbackStartFailed
            }
        }
    }

    /// 停止播放
    func stopPlayback() {
        playbackService.stopCurrent()
    }

    /// 播放器 `onStop` 时同步 ViewModel 状态（含被视频互斥打断的场景）
    func handlePlaybackStopped(id _: String) {}

    // MARK: - Private Methods

    /// 设置播放回调
    private func setupPlaybackCallbacks() {
        // 播放进度回调已通过 VoicePlaybackManager 的 onProgressUpdate 实现
        // ViewController 直接订阅播放器的进度更新
        // 这里不需要额外实现
    }

    /// 发送消息到服务器
    ///
    /// 替代原来的 simulateSendMessage，使用真实的网络请求
    /// 当前实现：直接标记为已送达（待接入真实 API）
    private func sendMessageToServer(id: String) {
        Task {
            do {
                // TODO: 接入真实的网络 API
                // let response = try await networkService.sendMessage(id: id)

                // 临时实现：直接标记为已送达
                try await repository.updateSendStatus(id: id, status: .delivered)
                if let index = messages.firstIndex(where: { $0.id == id }) {
                    messages[index].sendStatus = .delivered
                }

                logger.info("Message sent successfully: \(id)")
            } catch {
                // 发送失败，标记为失败状态
                try? await repository.updateSendStatus(id: id, status: .failed)
                if let index = messages.firstIndex(where: { $0.id == id }) {
                    messages[index].sendStatus = .failed
                }

                logger.error("Failed to send message: \(error)")
                self.error = .messageSendFailed
            }
        }
    }
}
