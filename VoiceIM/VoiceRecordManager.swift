import AVFoundation
import Foundation

/// 录音管理器（主线程单例）
@MainActor
final class VoiceRecordManager: NSObject {

    static let shared = VoiceRecordManager()

    private var recorder: AVAudioRecorder?
    private(set) var isRecording = false

    private override init() { super.init() }

    // MARK: - 权限

    func requestPermission() async -> Bool {
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
        rec.record()
        recorder = rec
        isRecording = true
        return url
    }

    /// 当前录音时长
    var currentTime: TimeInterval {
        recorder?.currentTime ?? 0
    }

    /// 停止录音并返回文件 URL
    func stopRecording() -> URL? {
        guard let rec = recorder else { return nil }
        let url = rec.url
        rec.stop()
        recorder = nil
        isRecording = false
        return url
    }

    /// 取消录音并删除临时文件
    func cancelRecording() {
        guard let rec = recorder else { return }
        let url = rec.url
        rec.stop()
        try? FileManager.default.removeItem(at: url)
        recorder = nil
        isRecording = false
    }
}

// MARK: - AVAudioRecorderDelegate

extension VoiceRecordManager: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {}
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {}
}
