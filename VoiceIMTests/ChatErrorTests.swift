import Testing
import Foundation
@testable import VoiceIM

/// ChatError 单元测试
@Suite("ChatError Tests")
struct ChatErrorTests {

    @Test("网络错误描述")
    func testNetworkErrorDescription() {
        let error = ChatError.networkUnavailable
        #expect(error.errorDescription == "网络连接不可用")
    }

    @Test("文件错误描述")
    func testFileErrorDescription() {
        let url = URL(fileURLWithPath: "/tmp/test.m4a")
        let error = ChatError.fileNotFound(path: url.path)
        #expect(error.errorDescription?.contains("test.m4a") == true)
    }

    @Test("权限错误描述")
    func testPermissionErrorDescription() {
        let error = ChatError.microphonePermissionDenied
        #expect(error.errorDescription == "麦克风权限被拒绝")
        #expect(error.recoverySuggestion?.contains("设置") == true)
    }

    @Test("录音错误描述")
    func testRecordingErrorDescription() {
        let error = ChatError.recordingTooShort
        #expect(error.errorDescription?.contains("太短") == true)
        #expect(error.recoverySuggestion?.contains("长按") == true)
    }

    @Test("消息撤回错误描述")
    func testMessageRecallFailedDescription() {
        let error = ChatError.messageRecallFailed
        #expect(error.errorDescription == "消息撤回失败")
    }
}
