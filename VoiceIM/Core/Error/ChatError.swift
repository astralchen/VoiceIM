import Foundation

/// 聊天应用统一错误类型
///
/// 将所有可能的错误场景归类到统一的枚举中，便于错误处理和国际化。
enum ChatError: Error {

    // MARK: - 网络错误

    case networkUnavailable
    case requestTimeout
    case serverError(statusCode: Int)
    case invalidResponse

    // MARK: - 文件错误

    case fileNotFound(path: String)
    case fileReadFailed(path: String)
    case fileWriteFailed(path: String)
    case fileDeleteFailed(path: String)
    case insufficientStorage

    // MARK: - 权限错误

    case microphonePermissionDenied
    case cameraPermissionDenied
    case photoLibraryPermissionDenied
    case locationPermissionDenied

    // MARK: - 录音错误

    case recordingStartFailed
    case recordingTooShort
    case recordingFailed(Error)

    // MARK: - 播放错误

    case playbackStartFailed
    case playbackFailed(Error)
    case audioFileCorrupted

    // MARK: - 消息错误

    case messageSendFailed
    case messageDeleteFailed
    case messageRecallFailed
    case messageNotFound(id: UUID)

    // MARK: - 媒体错误

    case imageLoadFailed
    case videoLoadFailed
    case mediaProcessingFailed

    // MARK: - 存储错误

    case storageInitFailed
    case storageReadFailed
    case storageWriteFailed

    // MARK: - 未知错误

    case unknown(Error)
}

// MARK: - LocalizedError

extension ChatError: LocalizedError {

    /// 错误描述（用户可见）
    var errorDescription: String? {
        switch self {
        // 网络错误
        case .networkUnavailable:
            return "网络连接不可用"
        case .requestTimeout:
            return "请求超时"
        case .serverError(let statusCode):
            return "服务器错误（\(statusCode)）"
        case .invalidResponse:
            return "服务器响应无效"

        // 文件错误
        case .fileNotFound(let path):
            return "文件不存在：\(path)"
        case .fileReadFailed(let path):
            return "读取文件失败：\(path)"
        case .fileWriteFailed(let path):
            return "写入文件失败：\(path)"
        case .fileDeleteFailed(let path):
            return "删除文件失败：\(path)"
        case .insufficientStorage:
            return "存储空间不足"

        // 权限错误
        case .microphonePermissionDenied:
            return "麦克风权限被拒绝"
        case .cameraPermissionDenied:
            return "相机权限被拒绝"
        case .photoLibraryPermissionDenied:
            return "相册权限被拒绝"
        case .locationPermissionDenied:
            return "位置权限被拒绝"

        // 录音错误
        case .recordingStartFailed:
            return "录音启动失败"
        case .recordingTooShort:
            return "说话时间太短"
        case .recordingFailed(let error):
            return "录音失败：\(error.localizedDescription)"

        // 播放错误
        case .playbackStartFailed:
            return "播放启动失败"
        case .playbackFailed(let error):
            return "播放失败：\(error.localizedDescription)"
        case .audioFileCorrupted:
            return "音频文件已损坏"

        // 消息错误
        case .messageSendFailed:
            return "消息发送失败"
        case .messageDeleteFailed:
            return "消息删除失败"
        case .messageRecallFailed:
            return "消息撤回失败"
        case .messageNotFound(let id):
            return "消息不存在：\(id)"

        // 媒体错误
        case .imageLoadFailed:
            return "图片加载失败"
        case .videoLoadFailed:
            return "视频加载失败"
        case .mediaProcessingFailed:
            return "媒体处理失败"

        // 存储错误
        case .storageInitFailed:
            return "存储初始化失败"
        case .storageReadFailed:
            return "读取存储失败"
        case .storageWriteFailed:
            return "写入存储失败"

        // 未知错误
        case .unknown(let error):
            return "未知错误：\(error.localizedDescription)"
        }
    }

    /// 恢复建议（用户可见）
    var recoverySuggestion: String? {
        switch self {
        case .networkUnavailable:
            return "请检查网络连接后重试"
        case .requestTimeout:
            return "请稍后重试"
        case .serverError:
            return "请稍后重试或联系客服"
        case .microphonePermissionDenied:
            return "请在设置中开启麦克风权限"
        case .cameraPermissionDenied:
            return "请在设置中开启相机权限"
        case .photoLibraryPermissionDenied:
            return "请在设置中开启相册权限"
        case .locationPermissionDenied:
            return "请在设置中开启位置权限"
        case .insufficientStorage:
            return "请清理存储空间后重试"
        case .recordingTooShort:
            return "请长按说话"
        case .audioFileCorrupted:
            return "音频文件已损坏，无法播放"
        default:
            return "请重试或联系客服"
        }
    }
}

// MARK: - Error Categorization

extension ChatError {

    /// 错误严重程度
    enum Severity {
        case info       // 信息提示
        case warning    // 警告
        case error      // 错误
        case critical   // 严重错误
    }

    /// 获取错误严重程度
    var severity: Severity {
        switch self {
        case .recordingTooShort:
            return .info
        case .networkUnavailable, .requestTimeout:
            return .warning
        case .serverError, .storageInitFailed, .storageWriteFailed:
            return .critical
        default:
            return .error
        }
    }

    /// 是否需要记录日志
    var shouldLog: Bool {
        switch severity {
        case .info:
            return false
        case .warning, .error, .critical:
            return true
        }
    }
}
