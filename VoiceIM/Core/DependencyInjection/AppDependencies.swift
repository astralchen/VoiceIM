import Foundation

/// 依赖注入容器：统一管理所有服务实例
///
/// # 职责
/// - 创建和管理所有服务的单例
/// - 提供依赖注入接口
/// - 支持测试环境替换 mock 服务
///
/// # 使用方式
/// ```swift
/// // 在 SceneDelegate 中初始化
/// let dependencies = AppDependencies.shared
///
/// // 创建 ViewModel
/// let viewModel = dependencies.makeChatViewModel()
///
/// // 创建 ViewController
/// let viewController = VoiceChatViewController(viewModel: viewModel)
/// ```
@MainActor
final class AppDependencies {

    // MARK: - Singleton

    static let shared = AppDependencies()

    // MARK: - Core Services

    /// 日志服务
    let logger: Logger

    /// 错误处理器
    let errorHandler: ErrorHandler

    // MARK: - Storage Services

    /// 消息存储
    let messageStorage: MessageStorage

    /// 文件存储管理器
    let fileStorageManager: FileStorageManager

    // MARK: - Audio Services

    /// 录音服务
    let recordService: AudioRecordService

    /// 播放服务
    let playbackService: AudioPlaybackService

    /// 缓存服务
    let cacheService: VoiceCacheManager

    // MARK: - Photo Services

    /// 相册选择服务
    let photoPickerService: PhotoPickerService

    // MARK: - Repository

    /// 消息仓库
    private(set) lazy var messageRepository: MessageRepository = {
        MessageRepository(
            storage: messageStorage,
            fileStorage: fileStorageManager,
            logger: logger
        )
    }()

    // MARK: - Init

    private init() {
        // 初始化日志服务
        #if DEBUG
        self.logger = CompositeLogger(loggers: [
            ConsoleLogger(minimumLevel: .debug),
            FileLogger(minimumLevel: .info)
        ])
        #else
        self.logger = FileLogger(minimumLevel: .warning)
        #endif

        // 初始化核心服务
        self.errorHandler = ErrorHandler.shared
        self.messageStorage = MessageStorage.shared
        self.fileStorageManager = FileStorageManager.shared

        // 初始化音频服务
        self.recordService = VoiceRecordManager.shared
        self.playbackService = VoicePlaybackManager.shared
        self.cacheService = VoiceCacheManager.shared

        // 初始化相册服务
        self.photoPickerService = PhotoPickerManager.shared

        logger.info("AppDependencies initialized")
    }

    // MARK: - Factory Methods

    /// 创建 ChatViewModel
    ///
    /// - Returns: ChatViewModel 实例
    func makeChatViewModel() -> ChatViewModel {
        ChatViewModel(
            repository: messageRepository,
            playbackService: playbackService,
            recordService: recordService,
            logger: logger
        )
    }

    /// 创建 InputCoordinator
    ///
    /// - Returns: InputCoordinator 实例
    func makeInputCoordinator() -> InputCoordinator {
        InputCoordinator(
            recorder: recordService,
            player: playbackService,
            photoPicker: photoPickerService
        )
    }

    /// 创建 MessageActionHandler
    ///
    /// - Returns: MessageActionHandler 实例
    func makeMessageActionHandler() -> MessageActionHandler {
        MessageActionHandler(player: playbackService)
    }
}

// MARK: - Test Support

#if DEBUG
extension AppDependencies {
    /// 创建测试用的依赖容器
    ///
    /// - Parameters:
    ///   - recordService: Mock 录音服务
    ///   - playbackService: Mock 播放服务
    /// - Returns: 测试用的依赖容器
    static func makeForTesting(
        recordService: AudioRecordService? = nil,
        playbackService: AudioPlaybackService? = nil
    ) -> AppDependencies {
        let dependencies = AppDependencies.shared

        // TODO: 支持注入 mock 服务
        // 当前实现使用单例，无法替换
        // 需要重构为非单例模式才能支持测试

        return dependencies
    }
}
#endif
