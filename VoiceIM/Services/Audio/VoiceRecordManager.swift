import AVFoundation
import Foundation

/// 录音管理器（主线程单例）
@MainActor
final class VoiceRecordManager: NSObject, AudioRecordService {

    static let shared = VoiceRecordManager()

    private var recorder: AVAudioRecorder?
    private(set) var isRecording = false

    private override init() { super.init() }

    // MARK: - 权限

    // ── 崩溃根因 ────────────────────────────────────────────────────────────────
    // Swift 6 中，定义在 @MainActor 上下文里的闭包会被推断为 @MainActor 隔离，
    // 除非显式声明为 @Sendable。requestRecordPermission 的回调闭包若被推断为
    // @MainActor，编译器会在闭包入口插入 _swift_task_checkIsolatedSwift 检查；
    // 而该回调由 TCC 私有串行队列触发（非主线程），断言失败 →
    // _dispatch_assert_queue_fail 崩溃。
    //
    // ── 两种修法 ────────────────────────────────────────────────────────────────
    // 方案 A  在回调闭包上加 @Sendable（精准修复）
    //   func requestPermission() async -> Bool {   // 方法仍是 @MainActor
    //       await withCheckedContinuation { continuation in
    //           AVAudioSession.sharedInstance().requestRecordPermission { @Sendable granted in
    //               // @Sendable 阻止编译器将此闭包推断为 @MainActor
    //               // → 不插入隔离检查 → 不崩溃
    //               continuation.resume(returning: granted)
    //           }
    //       }
    //   }
    //
    // 方案 B  在方法上加 nonisolated（当前采用，整体脱离 actor）
    //   方法本身脱离主 Actor，内部所有闭包也不再有 @MainActor 可推断，
    //   从根源消除隔离检查。该方法仅桥接回调 API，不访问任何 actor 隔离状态，
    //   声明 nonisolated 无副作用；调用方 await 后自动回到其所在 actor（主线程）。
    //
    // 两者均正确；@Sendable 粒度更小，nonisolated 更彻底。
    // ────────────────────────────────────────────────────────────────────────────
    nonisolated func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - 录音控制

    /// 开始录音，返回录音文件 URL
    func startRecording() throws -> URL {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)

        let fileName = UUID().uuidString + ".m4a"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let rec = try AVAudioRecorder(url: url, settings: settings)
        rec.delegate = self
        rec.isMeteringEnabled = true
        rec.record()
        recorder = rec
        isRecording = true
        return url
    }

    /// 当前录音时长
    var currentTime: TimeInterval {
        recorder?.currentTime ?? 0
    }

    /// 当前录音输入音量（0...1），用于驱动波形动画
    var normalizedPowerLevel: Float {
        guard let recorder else { return 0 }
        recorder.updateMeters()
        let averagePower = recorder.averagePower(forChannel: 0) // dBFS: 0...-160
        let linear = pow(10, averagePower / 20)                // 线性幅度: ~0...1
        return max(0, min(linear, 1))
    }

    /// 停止录音并返回文件 URL
    func stopRecording() -> URL? {
        guard let rec = recorder else { return nil }
        rec.delegate = nil  // 清理 delegate 引用
        let url = rec.url
        rec.stop()
        recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return url
    }

    /// 取消录音并删除临时文件
    func cancelRecording() {
        guard let rec = recorder else { return }
        rec.delegate = nil  // 清理 delegate 引用
        let url = rec.url
        rec.stop()
        try? FileManager.default.removeItem(at: url)
        recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - AVAudioRecorderDelegate

extension VoiceRecordManager: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            Task { @MainActor in
                VoiceIM.logger.error("Recording finished with error")
            }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            if let error = error {
                VoiceIM.logger.error("Recording encode error: \(error)")
            }
        }
    }
}
