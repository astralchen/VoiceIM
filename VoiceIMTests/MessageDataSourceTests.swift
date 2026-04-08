import Testing
import Foundation
import UIKit
@testable import VoiceIM

/// MessageDataSource 单元测试
@Suite("MessageDataSource Tests")
@MainActor
struct MessageDataSourceTests {

    // MARK: - Helper Methods

    /// 创建测试用的 CollectionView
    func makeTestCollectionView() -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        return UICollectionView(frame: .zero, collectionViewLayout: layout)
    }

    /// 创建测试消息
    func makeTestMessage(id: String = MessageIDGenerator.next(), text: String = "测试消息", isOutgoing: Bool = true) -> ChatMessage {
        ChatMessage(
            id: id,
            kind: .text(text),
            sender: isOutgoing ? .me : .peer,
            sentAt: Date(),
            isPlayed: true,
            isRead: true,
            sendStatus: .delivered
        )
    }

    // MARK: - Initialization Tests

    @Test("初始化 MessageDataSource")
    func testInitialization() {
        let collectionView = makeTestCollectionView()
        let dataSource = MessageDataSource(collectionView: collectionView)

        #expect(dataSource.messages.isEmpty)
    }

    // MARK: - Render Tests

    @Test("渲染单条消息")
    func testRenderSingleMessage() {
        let collectionView = makeTestCollectionView()
        let dataSource = MessageDataSource(collectionView: collectionView)

        let message = makeTestMessage(text: "第一条消息")
        dataSource.render(messages: [message], animatingDifferences: false)

        #expect(dataSource.messages.count == 1)
        #expect(dataSource.messages[0].id == message.id)
    }

    @Test("渲染多条消息")
    func testRenderMultipleMessages() {
        let collectionView = makeTestCollectionView()
        let dataSource = MessageDataSource(collectionView: collectionView)

        let message1 = makeTestMessage(text: "消息1")
        let message2 = makeTestMessage(text: "消息2")
        let message3 = makeTestMessage(text: "消息3")

        dataSource.render(messages: [message1, message2, message3], animatingDifferences: false)

        #expect(dataSource.messages.count == 3)
        #expect(dataSource.messages[0].id == message1.id)
        #expect(dataSource.messages[1].id == message2.id)
        #expect(dataSource.messages[2].id == message3.id)
    }

    @Test("重渲染历史消息在前")
    func testRenderHistoryBeforeCurrent() {
        let collectionView = makeTestCollectionView()
        let dataSource = MessageDataSource(collectionView: collectionView)

        let currentMessage = makeTestMessage(text: "当前消息")
        let historyMessage1 = makeTestMessage(text: "历史消息1")
        let historyMessage2 = makeTestMessage(text: "历史消息2")
        dataSource.render(messages: [historyMessage1, historyMessage2, currentMessage], animatingDifferences: false)

        #expect(dataSource.messages.count == 3)
        #expect(dataSource.messages[0].id == historyMessage1.id)
        #expect(dataSource.messages[1].id == historyMessage2.id)
        #expect(dataSource.messages[2].id == currentMessage.id)
    }

    @Test("重渲染可移除消息")
    func testRenderCanRemoveMessage() {
        let collectionView = makeTestCollectionView()
        let dataSource = MessageDataSource(collectionView: collectionView)

        let message1 = makeTestMessage(text: "消息1")
        let message2 = makeTestMessage(text: "消息2")
        let message3 = makeTestMessage(text: "消息3")

        dataSource.render(messages: [message1, message2, message3], animatingDifferences: false)
        dataSource.render(messages: [message1, message3], animatingDifferences: true)
        #expect(dataSource.messages.count == 2)
        #expect(dataSource.messages[0].id == message1.id)
        #expect(dataSource.messages[1].id == message3.id)
    }

    @Test("重渲染空列表")
    func testRenderEmptyList() {
        let collectionView = makeTestCollectionView()
        let dataSource = MessageDataSource(collectionView: collectionView)

        let message = makeTestMessage(text: "消息")
        dataSource.render(messages: [message], animatingDifferences: false)
        dataSource.render(messages: [], animatingDifferences: true)
        #expect(dataSource.messages.isEmpty)
    }

    // MARK: - Replace Message Tests

    @Test("替换消息（撤回场景）")
    func testReplaceMessage() {
        let collectionView = makeTestCollectionView()
        let dataSource = MessageDataSource(collectionView: collectionView)

        let originalMessage = makeTestMessage(text: "原始消息")
        dataSource.render(messages: [originalMessage], animatingDifferences: false)

        // 创建撤回消息
        let recalledMessage = ChatMessage(
            id: originalMessage.id,
            kind: .recalled(originalText: "原始消息"),
            sender: .me,
            sentAt: originalMessage.sentAt,
            isPlayed: true,
            isRead: true,
            sendStatus: .delivered
        )

        dataSource.render(messages: [recalledMessage], animatingDifferences: true)

        #expect(dataSource.messages.count == 1)
        if case .recalled(let text) = dataSource.messages[0].kind {
            #expect(text == "原始消息")
        } else {
            Issue.record("消息类型应该是 recalled")
        }
    }

    @Test("重渲染可更新已播状态")
    func testRenderUpdatesPlayedState() {
        let collectionView = makeTestCollectionView()
        let dataSource = MessageDataSource(collectionView: collectionView)

        let voiceURL = URL(fileURLWithPath: "/tmp/test.m4a")
        var message = ChatMessage(
            id: MessageIDGenerator.next(),
            kind: .voice(localURL: voiceURL, remoteURL: nil, duration: 5.0),
            sender: .peer,
            sentAt: Date(),
            isPlayed: false,
            isRead: false,
            sendStatus: .delivered
        )
        message.isPlayed = false

        dataSource.render(messages: [message], animatingDifferences: false)
        message.isPlayed = true
        dataSource.render(messages: [message], animatingDifferences: false)

        #expect(dataSource.messages[0].isPlayed == true)
    }

    @Test("重渲染可更新发送状态")
    func testRenderUpdatesSendStatus() {
        let collectionView = makeTestCollectionView()
        let dataSource = MessageDataSource(collectionView: collectionView)

        var message = makeTestMessage(text: "发送中的消息")
        message.sendStatus = .sending

        dataSource.render(messages: [message], animatingDifferences: false)
        message.sendStatus = .delivered
        dataSource.render(messages: [message], animatingDifferences: false)

        #expect(dataSource.messages[0].sendStatus == ChatMessage.SendStatus.delivered)
    }

    @Test("重渲染可更新失败状态")
    func testRenderUpdatesSendStatusToFailed() {
        let collectionView = makeTestCollectionView()
        let dataSource = MessageDataSource(collectionView: collectionView)

        var message = makeTestMessage(text: "发送失败的消息")
        message.sendStatus = .sending

        dataSource.render(messages: [message], animatingDifferences: false)
        message.sendStatus = .failed
        dataSource.render(messages: [message], animatingDifferences: false)

        #expect(dataSource.messages[0].sendStatus == ChatMessage.SendStatus.failed)
    }

    // MARK: - Index and Message Lookup Tests

    @Test("查找消息索引")
    func testIndexOf() {
        let collectionView = makeTestCollectionView()
        let dataSource = MessageDataSource(collectionView: collectionView)

        let message1 = makeTestMessage(text: "消息1")
        let message2 = makeTestMessage(text: "消息2")
        let message3 = makeTestMessage(text: "消息3")

        dataSource.render(messages: [message1, message2, message3], animatingDifferences: false)

        #expect(dataSource.index(of: message1.id) == 0)
        #expect(dataSource.index(of: message2.id) == 1)
        #expect(dataSource.index(of: message3.id) == 2)
        #expect(dataSource.index(of: MessageIDGenerator.next()) == nil)
    }

    @Test("根据索引获取消息")
    func testMessageAt() {
        let collectionView = makeTestCollectionView()
        let dataSource = MessageDataSource(collectionView: collectionView)

        let message1 = makeTestMessage(text: "消息1")
        let message2 = makeTestMessage(text: "消息2")

        dataSource.render(messages: [message1, message2], animatingDifferences: false)

        #expect(dataSource.message(at: 0)?.id == message1.id)
        #expect(dataSource.message(at: 1)?.id == message2.id)
        #expect(dataSource.message(at: 2) == nil)
        #expect(dataSource.message(at: -1) == nil)
    }

    // MARK: - Edge Cases Tests

    @Test("空数据源操作")
    func testEmptyDataSourceOperations() {
        let collectionView = makeTestCollectionView()
        let dataSource = MessageDataSource(collectionView: collectionView)

        // 查找不存在的索引
        let index = dataSource.index(of: MessageIDGenerator.next())
        #expect(index == nil)

        // 获取越界的消息
        let message = dataSource.message(at: 0)
        #expect(message == nil)
    }
}
