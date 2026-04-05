import Testing
import Foundation
@testable import VoiceIM

/// ChatError 单元测试
@Suite("ChatError Tests")
struct ChatErrorTests {

    @Test("网络错误描述")
    func testNetworkErrorDescription() {
        let error = ChatError.noConnection
        #expect(error.errorDescription == "无网络连接")
    }

    @Test("文件错误描述")
    func testFileErrorDescription() {
        let url = URL(fileURLWithPath: "/tmp/test.m4a")
        let error = ChatError.fileNotFound(url)
        #expect(error.errorDescription?.contains("test.m4a") == true)
    }

    @Test("权限错误描述")
    func testPermissionErrorDescription() {
        let error = ChatError.permissionDenied(.microphone)
        #expect(error.errorDescription == "需要麦克风权限以录制语音消息")
        #expect(error.recoverySuggestion?.contains("设置") == true)
    }

    @Test("录音错误描述")
    func testRecordingErrorDescription() {
        let error = ChatError.recordingTooShort(duration: 0.5)
        #expect(error.errorDescription?.contains("太短") == true)
        #expect(error.recoverySuggestion?.contains("1 秒") == true)
    }

    @Test("撤回失败原因")
    func testRecallFailureReason() {
        let reason = RecallFailureReason.timeExpired(elapsed: 240, limit: 180)
        #expect(reason.description.contains("超过撤回时限") == true)
    }
}
