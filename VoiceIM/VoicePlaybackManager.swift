import AVFoundation
import Foundation

/// 语音播放管理器（主线程单例，同时只允许一条语音播放）
@MainActor
final class VoicePlaybackManager: NSObject {

    static let shared = VoicePlaybackManager()

    private var player: AVAudioPlayer?
    private var progressTimer: Timer?

    /// 正在播放的消息 ID
    private(set) var playingID: UUID?

    /// 播放进度回调 (消息ID, 进度 0~1)
    var onProgress: ((UUID, Float) -> Void)?
    /// 停止/播放完成回调
    var onStop: ((UUID) -> Void)?

    private override init() { super.init() }

    // MARK: - 公共接口

    /// 播放指定 URL 的语音，自动停止当前正在播放的语音
    func play(id: UUID, url: URL) throws {
        stopCurrent()

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)

        let p = try AVAudioPlayer(contentsOf: url)
        p.delegate = self
        p.prepareToPlay()
        p.play()
        player = p
        playingID = id

        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }

    /// 停止当前播放
    func stopCurrent() {
        progressTimer?.invalidate()
        progressTimer = nil
        player?.stop()
        player = nil
        if let id = playingID {
            playingID = nil
            onStop?(id)
        }
    }

    /// 是否正在播放指定消息
    func isPlaying(id: UUID) -> Bool {
        playingID == id
    }

    /// 跳转到指定进度（0~1）
    func seek(to progress: Float) {
        guard let p = player, p.duration > 0 else { return }
        p.currentTime = Double(progress) * p.duration
    }

    // MARK: - 私有

    private func tick() {
        guard let p = player, let id = playingID else { return }
        let progress = p.duration > 0 ? Float(p.currentTime / p.duration) : 0
        onProgress?(id, progress)
    }
}

// MARK: - AVAudioPlayerDelegate

extension VoicePlaybackManager: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.progressTimer?.invalidate()
            self.progressTimer = nil
            self.player = nil
            if let id = self.playingID {
                self.playingID = nil
                self.onStop?(id)
            }
        }
    }
}
