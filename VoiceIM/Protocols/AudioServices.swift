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
protocol AudioPlaybackService: AnyObject {

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

    /// 当前解码得到的音频总时长（秒）；仅当正在播放指定消息时非零，用于与消息内嵌时长对齐展示
    func playbackDuration(for id: UUID) -> TimeInterval

    /// 当前播放剩余时长（秒）；与 `currentTime` 同源，避免用进度反推时出现尾段显示 0" 而条仍在动
    func playbackRemaining(for id: UUID) -> TimeInterval

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

/// 远程媒体文件落盘缓存协议（当前用于：**仅有远程 URL 的语音消息**在播放前下载到本地）。
///
/// # 典型调用链
/// 1. 用户点击播放 → `ChatViewModel.playVoiceMessage` 发现本地文件不存在、但有 `remoteURL`
/// 2. 调用 `voiceFileCache.resolve(remoteURL)` 得到可交给 `AVAudioPlayer` 的 **file URL**（目录一般为 `Caches/.../VoiceIM/IMVoiceCache`）
/// 3. 再次播放同一远程 URL 时，实现应命中已有文件，避免重复下载（生产实现委托 `RemoteFileCache`）
///
/// # 与「用户录音」的区别
/// 用户录制的语音保存在 **Documents**（`FileStorageManager`），**不在**本协议管理范围内；本协议只处理**可再从服务器拉取**的远程文件缓存。
///
/// # 依赖注入
/// - 生产：`AppDependencies.cacheService`（`VoiceCacheManager`）经 `makeChatViewModel(voiceFileCache:)` 传入 `ChatViewModel`
/// - 测试：注入不触网的 `Sendable` 实现，或固定返回临时文件 URL
///
/// # 实现者
/// - `VoiceCacheManager`：生产环境
protocol FileCacheService: Sendable {

    /// 若磁盘已有对应稳定哈希文件则直接返回其 URL；否则下载并移动到缓存目录后再返回。
    ///
    /// - Parameter remoteURL: 远程资源地址（通常为 HTTPS）
    /// - Returns: 本地 `file://` URL，供播放器打开
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
