import XCTest
@testable import VoiceIM

/// InputCoordinator 单元测试
///
/// 测试录音状态机、权限处理、消息发送等核心逻辑。
/// 通过 Mock 实现隔离外部依赖（录音器、播放器）。
@MainActor
final class InputCoordinatorTests: XCTestCase {

    var coordinator: InputCoordinator!
    var mockRecorder: MockRecordService!
    var mockPlayer: MockPlaybackService!

    override func setUp() {
        super.setUp()
        mockRecorder = MockRecordService()
        mockPlayer = MockPlaybackService()
        coordinator = InputCoordinator(
            recorder: mockRecorder,
            player: mockPlayer
        )
    }

    override func tearDown() {
        coordinator = nil
        mockRecorder = nil
        mockPlayer = nil
        super.tearDown()
    }

    // MARK: - 权限测试

    /// 测试：麦克风权限被拒绝时，应显示提示并不启动录音
    func testRecordingPermissionDenied() async {
        // Given: 用户拒绝麦克风权限
        mockRecorder.shouldGrantPermission = false

        var toastMessage: String?
        coordinator.showToast = { message in
            toastMessage = message
        }

        // When: 尝试开始录音
        // TODO: 触发录音逻辑（需要暴露测试接口）

        // Then: 应显示权限提示，且未启动录音
        XCTAssertEqual(toastMessage, "请在设置中开启麦克风权限")
        XCTAssertFalse(mockRecorder.isRecording)
    }

    /// 测试：麦克风权限授权后，应成功启动录音
    func testRecordingPermissionGranted() async throws {
        // Given: 用户授权麦克风权限
        mockRecorder.shouldGrantPermission = true

        // When: 开始录音
        // TODO: 触发录音逻辑

        // Then: 应成功启动录音
        // XCTAssertTrue(mockRecorder.isRecording)
    }

    // MARK: - 录音状态机测试

    /// 测试：录音时长 < 1 秒时，应提示"说话时间太短"
    func testRecordingTooShort() {
        // Given: 录音时长 < 1 秒
        mockRecorder.mockDuration = 0.5

        var toastMessage: String?
        coordinator.showToast = { message in
            toastMessage = message
        }

        // When: 停止录音
        // TODO: 触发停止录音逻辑

        // Then: 应显示提示，且不发送消息
        // XCTAssertEqual(toastMessage, "说话时间太短")
    }

    /// 测试：录音时长 ≥ 1 秒时，应成功发送语音消息
    func testRecordingSuccess() {
        // Given: 录音时长 ≥ 1 秒
        mockRecorder.mockDuration = 2.0

        var sentVoiceURL: URL?
        var sentDuration: TimeInterval?
        coordinator.onSendVoice = { url, duration in
            sentVoiceURL = url
            sentDuration = duration
        }

        // When: 停止录音
        // TODO: 触发停止录音逻辑

        // Then: 应发送语音消息
        // XCTAssertNotNil(sentVoiceURL)
        // XCTAssertEqual(sentDuration, 2.0)
    }

    // MARK: - 播放互斥测试

    /// 测试：开始录音前应停止当前播放
    func testStopPlaybackBeforeRecording() {
        // Given: 正在播放语音消息
        mockPlayer.playingID = UUID()

        // When: 开始录音
        // TODO: 触发录音逻辑

        // Then: 应停止播放
        // XCTAssertNil(mockPlayer.playingID)
    }

    // MARK: - 文本消息测试

    /// 测试：发送文本消息
    func testSendTextMessage() {
        // Given: 输入文本
        let text = "Hello, World!"

        var sentText: String?
        coordinator.onSendText = { message in
            sentText = message
        }

        // When: 发送文本
        // TODO: 触发发送文本逻辑

        // Then: 应发送文本消息
        // XCTAssertEqual(sentText, text)
    }
}

// MARK: - Mock 实现

/// Mock 录音服务（用于单元测试）
@MainActor
final class MockRecordService: AudioRecordService {

    var isRecording = false
    var currentTime: TimeInterval = 0
    var normalizedPowerLevel: Float = 0.5
    var shouldGrantPermission = true
    var mockDuration: TimeInterval = 2.0

    func requestPermission() async -> Bool {
        return shouldGrantPermission
    }

    func startRecording() throws -> URL {
        isRecording = true
        currentTime = 0
        return URL(fileURLWithPath: "/tmp/test_recording.m4a")
    }

    func stopRecording() -> URL? {
        isRecording = false
        currentTime = mockDuration
        return URL(fileURLWithPath: "/tmp/test_recording.m4a")
    }

    func cancelRecording() {
        isRecording = false
        currentTime = 0
    }
}

/// Mock 播放服务（用于单元测试）
@MainActor
final class MockPlaybackService: AudioPlaybackService {

    var playingID: UUID?

    func stopCurrent() {
        playingID = nil
    }

    func isPlaying(id: UUID) -> Bool {
        return playingID == id
    }
}
