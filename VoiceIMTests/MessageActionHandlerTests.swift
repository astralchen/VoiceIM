import Testing
import Foundation
@testable import VoiceIM

/// MessageActionHandler 单元测试
@Suite("MessageActionHandler Tests")
@MainActor
struct MessageActionHandlerTests {

    // MARK: - Mock Services

    /// Mock 播放服务
    final class MockPlaybackService: AudioPlaybackService {
        var playingID: UUID?
        var onStart: ((UUID) -> Void)?
        var onProgress: ((UUID, Float) -> Void)?
        var onStop: ((UUID) -> Void)?

        var stopCurrentCalled = false

        func play(id: UUID, url: URL) throws {
            playingID = id
        }

        func stopCurrent() {
            stopCurrentCalled = true
            if let id = playingID {
                onStop?(id)
                playingID = nil
            }
        }

        func isPlaying(id: UUID) -> Bool {
            playingID == id
        }

        func currentProgress(for id: UUID) -> Float {
            0.5
        }

        func playbackDuration(for id: UUID) -> TimeInterval { 0 }

        func playbackRemaining(for id: UUID) -> TimeInterval { 0 }

        func seek(to progress: Float) {}
    }

    // MARK: - Context Menu Tests

    @Test("构建文本消息上下文菜单")
    func testBuildContextMenuForTextMessage() {
        let player = MockPlaybackService()
        let handler = MessageActionHandler(player: player)

        let message = ChatMessage(
            id: UUID(),
            kind: .text("测试消息"),
            isOutgoing: true,
            sentAt: Date(),
            sendStatus: .delivered
        )

        let menu = handler.buildContextMenu(for: message)

        // 文本消息应该有复制、撤回、删除三个选项
        #expect(menu.children.count == 3)
    }

    @Test("构建语音消息上下文菜单")
    func testBuildContextMenuForVoiceMessage() {
        let player = MockPlaybackService()
        let handler = MessageActionHandler(player: player)

        let voiceURL = URL(fileURLWithPath: "/tmp/test.m4a")
        let message = ChatMessage(
            id: UUID(),
            kind: .voice(voiceURL, duration: 5.0),
            isOutgoing: true,
            sentAt: Date(),
            sendStatus: .delivered
        )

        let menu = handler.buildContextMenu(for: message)

        // 语音消息应该有撤回、删除两个选项（无复制）
        #expect(menu.children.count == 2)
    }

    @Test("撤回条件：超过3分钟不可撤回")
    func testCannotRecallAfter3Minutes() {
        let player = MockPlaybackService()
        let handler = MessageActionHandler(player: player)

        // 创建 4 分钟前的消息
        let oldDate = Date().addingTimeInterval(-4 * 60)
        let message = ChatMessage(
            id: UUID(),
            kind: .text("旧消息"),
            isOutgoing: true,
            sentAt: oldDate,
            sendStatus: .delivered
        )

        let menu = handler.buildContextMenu(for: message)

        // 超过 3 分钟，应该只有复制和删除，没有撤回
        #expect(menu.children.count == 2)
    }

    @Test("撤回条件：非 delivered 状态不可撤回")
    func testCannotRecallNonDeliveredMessage() {
        let player = MockPlaybackService()
        let handler = MessageActionHandler(player: player)

        let message = ChatMessage(
            id: UUID(),
            kind: .text("发送中的消息"),
            isOutgoing: true,
            sentAt: Date(),
            sendStatus: .sending
        )

        let menu = handler.buildContextMenu(for: message)

        // 发送中的消息不可撤回，只有复制和删除
        #expect(menu.children.count == 2)
    }

    @Test("撤回条件：接收的消息不可撤回")
    func testCannotRecallIncomingMessage() {
        let player = MockPlaybackService()
        let handler = MessageActionHandler(player: player)

        let message = ChatMessage(
            id: UUID(),
            kind: .text("接收的消息"),
            isOutgoing: false,
            sentAt: Date(),
            sendStatus: .delivered
        )

        let menu = handler.buildContextMenu(for: message)

        // 接收的消息不可撤回，只有复制和删除
        #expect(menu.children.count == 2)
    }

    // MARK: - Delete Message Tests

    @Test("删除消息时停止播放")
    func testDeleteMessageStopsPlayback() {
        let player = MockPlaybackService()
        let handler = MessageActionHandler(player: player)

        let messageID = UUID()
        let voiceURL = URL(fileURLWithPath: "/tmp/test.m4a")

        // 模拟正在播放
        player.playingID = messageID

        var deleteCalled = false
        handler.onDelete = { id in
            deleteCalled = true
            #expect(id == messageID)
        }

        handler.deleteMessage(messageID)

        // 验证停止播放被调用
        #expect(player.stopCurrentCalled)
        #expect(deleteCalled)
    }

    // MARK: - Recall Message Tests

    @Test("撤回消息时停止播放")
    func testRecallMessageStopsPlayback() {
        let player = MockPlaybackService()
        let handler = MessageActionHandler(player: player)

        let messageID = UUID()

        // 模拟正在播放
        player.playingID = messageID

        var recallCalled = false
        handler.onRecall = { id in
            recallCalled = true
            #expect(id == messageID)
        }

        handler.recallMessage(messageID)

        // 验证停止播放被调用
        #expect(player.stopCurrentCalled)
        #expect(recallCalled)
    }

    // MARK: - Retry Message Tests

    @Test("重试消息回调触发")
    func testRetryMessage() {
        let player = MockPlaybackService()
        let handler = MessageActionHandler(player: player)

        let messageID = UUID()

        var retryCalled = false
        handler.onRetry = { id in
            retryCalled = true
            #expect(id == messageID)
        }

        handler.retryMessage(messageID)

        #expect(retryCalled)
    }

    // MARK: - Recalled Message Tap Tests

    @Test("点击撤回消息触发回调")
    func testRecalledMessageTap() {
        let player = MockPlaybackService()
        let handler = MessageActionHandler(player: player)

        let message = ChatMessage(
            id: UUID(),
            kind: .recalled(originalText: "原始文本"),
            isOutgoing: true,
            sentAt: Date(),
            sendStatus: .delivered
        )

        var tapCalled = false
        handler.onRecalledMessageTap = { msg in
            tapCalled = true
            #expect(msg.id == message.id)
        }

        handler.handleRecalledMessageTap(message)

        #expect(tapCalled)
    }
}
