import Foundation

/// 依赖注入容器：统一管理所有服务实例
@MainActor
final class AppDependencies {

    static let shared = AppDependencies()

    let logger: Logger
    let errorHandler: ErrorHandler
    let messageStorage: MessageStorage
    let fileStorageManager: any FileStorageProtocol
    let recordService: AudioRecordService
    let playbackService: AudioPlaybackService
    private(set) lazy var mediaPlaybackCoordinator: MediaPlaybackCoordinator = {
        MediaPlaybackCoordinator(audioPlayback: playbackService)
    }()
    let cacheService: VoiceCacheManager
    let photoPickerService: PhotoPickerService

    private init() {
        #if DEBUG
        self.logger = CompositeLogger(loggers: [
            ConsoleLogger(minimumLevel: .debug),
            FileLogger(minimumLevel: .info)
        ])
        #else
        self.logger = FileLogger(minimumLevel: .warning)
        #endif

        self.errorHandler = ErrorHandler.shared
        self.messageStorage = MessageStorage.shared
        self.fileStorageManager = FileStorageManager.shared
        self.recordService = VoiceRecordManager.shared
        self.playbackService = VoicePlaybackManager.shared
        self.cacheService = VoiceCacheManager.shared
        self.photoPickerService = PhotoPickerManager.shared

        logger.info("AppDependencies initialized")
    }

    // MARK: - 工厂方法

    func makeChatViewModel(contact: Contact) -> ChatViewModel {
        let repo = makeMessageRepository(contactID: contact.id)
        return ChatViewModel(
            contact: contact,
            repository: repo,
            playbackService: playbackService,
            mediaPlaybackCoordinator: mediaPlaybackCoordinator,
            recordService: recordService,
            photoPickerService: photoPickerService,
            errorHandler: errorHandler,
            voiceFileCache: cacheService,
            logger: logger
        )
    }

    func makeMessageRepository(contactID: String) -> MessageRepository {
        MessageRepository(
            storage: messageStorage,
            fileStorage: fileStorageManager,
            contactID: contactID,
            imageCache: ImageCacheManager.shared,
            videoCache: VideoCacheManager.shared,
            logger: logger
        )
    }

    func makeInputCoordinator() -> InputCoordinator {
        InputCoordinator(
            recorder: recordService,
            player: playbackService,
            photoPicker: photoPickerService
        )
    }

    func makeMessageActionHandler() -> MessageActionHandler {
        MessageActionHandler(player: playbackService)
    }
}
