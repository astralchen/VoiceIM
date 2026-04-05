import Foundation
import AVFoundation
import UIKit

/// 音频录制服务协议
///
/// 定义录音器的核心能力，解耦 InputCoordinator 与具体实现。
/// 符合依赖倒置原则：高层模块依赖抽象，不依赖具体实现。
///
/// # 实现者
/// - `VoiceRecordManager`：生产环境使用的录音器
/// - `MockRecordService`：单元测试使用的 Mock 实现
@MainActor
protocol AudioRecordService {

    /// 是否正在录音
    var isRecording: Bool { get }

    /// 当前录音时长（秒）
    var currentTime: TimeInterval { get }

    /// 归一化音频电平（0.0 ~ 1.0），用于波形动画
    var normalizedPowerLevel: Float { get }

    /// 请求麦克风权限
    ///
    /// - Returns: 用户是否授权
    func requestPermission() async -> Bool

    /// 开始录音
    ///
    /// - Returns: 录音文件的临时 URL
    /// - Throws: 录音启动失败时抛出错误
    func startRecording() throws -> URL

    /// 停止录音并保存
    ///
    /// - Returns: 录音文件的最终 URL，失败时返回 nil
    func stopRecording() -> URL?

    /// 取消录音并删除文件
    func cancelRecording()
}

/// 音频播放服务协议
///
/// 定义播放器的核心能力，解耦依赖方与具体实现。
///
/// # 实现者
/// - `VoicePlaybackManager`：生产环境使用的播放器
/// - `MockPlaybackService`：单元测试使用的 Mock 实现
@MainActor
protocol AudioPlaybackService {

    /// 当前正在播放的消息 ID
    var playingID: UUID? { get }

    /// 开始播放回调
    var onStart: ((UUID) -> Void)? { get set }

    /// 播放进度回调 (消息ID, 进度 0~1)
    var onProgress: ((UUID, Float) -> Void)? { get set }

    /// 停止/播放完成回调
    var onStop: ((UUID) -> Void)? { get set }

    /// 播放指定 URL 的语音
    func play(id: UUID, url: URL) throws

    /// 停止当前播放
    func stopCurrent()

    /// 判断指定消息是否正在播放
    ///
    /// - Parameter id: 消息 ID
    /// - Returns: 是否正在播放
    func isPlaying(id: UUID) -> Bool

    /// 获取当前播放进度（0~1）
    func currentProgress(for id: UUID) -> Float

    /// 跳转到指定进度（0~1）
    func seek(to progress: Float)
}

/// 相册选择结果类型
enum PhotoPickerResult: Sendable {
    case image(URL)
    case video(URL, duration: TimeInterval)
}

/// 相册选择服务协议
///
/// 定义相册选择器的核心能力，解耦依赖方与具体实现。
///
/// # 实现者
/// - `PhotoPickerManager`：生产环境使用的相册选择器
/// - `MockPhotoPickerService`：单元测试使用的 Mock 实现
@MainActor
protocol PhotoPickerService {

    /// 选择图片或视频
    ///
    /// - Parameters:
    ///   - viewController: 展示选择器的 ViewController
    ///   - allowsMultiple: 是否允许多选（默认单选）
    /// - Returns: 选择的资源，用户取消时返回 nil
    func pickMedia(from viewController: UIViewController, allowsMultiple: Bool) async throws -> PhotoPickerResult?
}

/// 文件缓存服务协议
///
/// 定义文件缓存的核心能力，解耦依赖方与具体实现。
///
/// # 实现者
/// - `VoiceCacheManager`：生产环境使用的缓存管理器
/// - `MockCacheService`：单元测试使用的 Mock 实现
protocol FileCacheService {

    /// 解析远程 URL：本地缓存已存在直接返回，否则下载后缓存
    ///
    /// - Parameter remoteURL: 远程文件 URL
    /// - Returns: 本地缓存文件 URL
    func resolve(_ remoteURL: URL) async throws -> URL
}

/// 消息数据源协议
///
/// 定义消息列表数据管理的核心能力，解耦 ViewController 与具体实现。
///
/// # 实现者
/// - `MessageDataSource`：生产环境使用的数据源
/// - `MockMessageDataSource`：单元测试使用的 Mock 实现
@MainActor
protocol MessageDataSourceProtocol {

    /// 消息数组（只读）
    var messages: [ChatMessage] { get }

    /// Cell 依赖注入
    var dependencies: MessageCellDependencies? { get set }

    /// Cell 配置回调
    var cellConfigurator: ((UICollectionViewCell, ChatMessage) -> Void)? { get set }

    /// 追加消息到列表底部
    func appendMessage(_ message: ChatMessage, animatingDifferences: Bool)

    /// 在列表头部插入历史消息
    func prependMessages(_ newMessages: [ChatMessage])

    /// 删除消息
    func deleteMessage(id: UUID) -> ChatMessage?

    /// 替换消息（用于撤回）
    func replaceMessage(id: UUID, with newMessage: ChatMessage)

    /// 标记消息为已播放
    func markAsPlayed(id: UUID)

    /// 更新消息发送状态
    func updateSendStatus(id: UUID, status: ChatMessage.SendStatus)

    /// 查找消息索引
    func index(of id: UUID) -> Int?

    /// 获取消息
    func message(at index: Int) -> ChatMessage?
}
