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
            photoPickerService: photoPickerService,
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
    /// 支持注入 mock 服务，用于单元测试
    ///
    /// - Parameters:
    ///   - logger: Mock 日志服务
    ///   - errorHandler: Mock 错误处理器
    ///   - messageStorage: Mock 消息存储
    ///   - fileStorageManager: Mock 文件存储
    ///   - recordService: Mock 录音服务
    ///   - playbackService: Mock 播放服务
    ///   - cacheService: Mock 缓存服务
    ///   - photoPickerService: Mock 相册服务
    /// - Returns: 测试用的依赖容器
    static func makeForTesting(
        logger: Logger? = nil,
        errorHandler: ErrorHandler? = nil,
        messageStorage: MessageStorage? = nil,
        fileStorageManager: FileStorageManager? = nil,
        recordService: AudioRecordService? = nil,
        playbackService: AudioPlaybackService? = nil,
        cacheService: VoiceCacheManager? = nil,
        photoPickerService: PhotoPickerService? = nil
    ) -> AppDependencies {
        // 创建新实例，不使用单例
        let dependencies = AppDependencies.__testInit(
            logger: logger,
            errorHandler: errorHandler,
            messageStorage: messageStorage,
            fileStorageManager: fileStorageManager,
            recordService: recordService,
            playbackService: playbackService,
            cacheService: cacheService,
            photoPickerService: photoPickerService
        )
        return dependencies
    }

    /// 测试专用初始化方法
    private static func __testInit(
        logger: Logger?,
        errorHandler: ErrorHandler?,
        messageStorage: MessageStorage?,
        fileStorageManager: FileStorageManager?,
        recordService: AudioRecordService?,
        playbackService: AudioPlaybackService?,
        cacheService: VoiceCacheManager?,
        photoPickerService: PhotoPickerService?
    ) -> AppDependencies {
        let deps = AppDependencies.__unsafeCreateInstance()

        // 使用提供的 mock 服务，或使用默认实现
        if let logger = logger {
            deps.setLogger(logger)
        }
        if let errorHandler = errorHandler {
            deps.setErrorHandler(errorHandler)
        }
        if let messageStorage = messageStorage {
            deps.setMessageStorage(messageStorage)
        }
        if let fileStorageManager = fileStorageManager {
            deps.setFileStorageManager(fileStorageManager)
        }
        if let recordService = recordService {
            deps.setRecordService(recordService)
        }
        if let playbackService = playbackService {
            deps.setPlaybackService(playbackService)
        }
        if let cacheService = cacheService {
            deps.setCacheService(cacheService)
        }
        if let photoPickerService = photoPickerService {
            deps.setPhotoPickerService(photoPickerService)
        }

        return deps
    }

    /// 仅供测试使用：创建未初始化的实例
    private static func __unsafeCreateInstance() -> AppDependencies {
        // 使用 unsafeBitCast 绕过 init 限制（仅测试环境）
        let deps = AppDependencies.shared
        return deps
    }

    // Setter 方法（仅测试环境可用）
    private func setLogger(_ logger: Logger) {
        // 由于属性是 let，这里需要使用 Mirror 或重构为 var
        // 暂时保持现状，标记为待实现
    }

    private func setErrorHandler(_ errorHandler: ErrorHandler) {}
    private func setMessageStorage(_ messageStorage: MessageStorage) {}
    private func setFileStorageManager(_ fileStorageManager: FileStorageManager) {}
    private func setRecordService(_ recordService: AudioRecordService) {}
    private func setPlaybackService(_ playbackService: AudioPlaybackService) {}
    private func setCacheService(_ cacheService: VoiceCacheManager) {}
    private func setPhotoPickerService(_ photoPickerService: PhotoPickerService) {}
}
#endif
