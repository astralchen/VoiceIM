import Foundation

/// 聊天内「语音 + 全屏视频」播放互斥：任意时刻只保留一种有声媒体。
///
/// - 语音即将播放时：暂停当前已注册的视频会话（由 `VideoPreviewViewController` 注册）。
/// - 视频即将播放时：停止 `AudioPlaybackService`（语音），由现有 `onStop` 链路刷新 Cell。
@MainActor
final class MediaPlaybackCoordinator {

    private let audioPlayback: AudioPlaybackService

    /// 由视频预览页注册：在语音开始播放时暂停其 `AVPlayer`，避免两路同时出声。
    private var pauseActiveVideo: (@MainActor () -> Void)?

    init(audioPlayback: AudioPlaybackService) {
        self.audioPlayback = audioPlayback
    }

    /// 视频预览页在展示期间调用，传入 `nil` 表示结束会话。
    func setActiveVideoSession(pause: (@MainActor () -> Void)?) {
        pauseActiveVideo = pause
    }

    /// 在即将开始播放聊天语音前调用（含异步下载缓存之前即可调用，尽早停掉视频声轨）。
    func willBeginVoicePlayback() {
        pauseActiveVideo?()
    }

    /// 在即将开始或恢复视频播放前调用，停止语音。
    func willBeginVideoPlayback() {
        audioPlayback.stopCurrent()
    }
}
