import Foundation

/// 依赖注入容器：统一管理所有服务实例
@MainActor
final class AppDependencies {

    static let shared = AppDependencies()

    let logger: Logger
    let errorHandler: ErrorHandler
    let messageStorage: any MessageStorageProtocol
    let conversationStorage: any ConversationStorageProtocol
    let receiptStorage: any ReceiptStorageProtocol
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
        // 三个 Store 共用同一队列，保证多表更新与查询看到一致快照；对外以协议类型注入便于单测替换实现。
        let db = DatabaseManager.shared
        self.messageStorage = MessageStore(db: db)
        self.conversationStorage = ConversationStore(db: db)
        self.receiptStorage = ReceiptStore(db: db)
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
            messageStorage: messageStorage,
            receiptStorage: receiptStorage,
            fileStorage: fileStorageManager,
            contactID: contactID,
            imageCache: ImageCacheManager.shared,
            videoCache: VideoCacheManager.shared,
            logger: logger
        )
    }

    func makeConversationListViewModel(contacts: [Contact] = Contact.mockContacts) -> ConversationListViewModel {
        ConversationListViewModel(
            contacts: contacts,
            messageStorage: messageStorage,
            conversationStorage: conversationStorage,
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
