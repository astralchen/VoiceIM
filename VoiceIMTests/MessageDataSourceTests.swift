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

    // MARK: - Append Message Tests

    @Test("追加单条消息")
    func testAppendMessage() {
        let collectionView = makeTestCollectionView()
        let dataSource = MessageDataSource(collectionView: collectionView)

        let message = makeTestMessage(text: "第一条消息")
        dataSource.appendMessage(message, animatingDifferences: false)

        #expect(dataSource.messages.count == 1)
        #expect(dataSource.messages[0].id == message.id)
    }

    @Test("追加多条消息")
    func testAppendMultipleMessages() {
        let collectionView = makeTestCollectionView()
        let dataSource = MessageDataSource(collectionView: collectionView)

        let message1 = makeTestMessage(text: "消息1")
        let message2 = makeTestMessage(text: "消息2")
        let message3 = makeTestMessage(text: "消息3")

        dataSource.appendMessage(message1, animatingDifferences: false)
        dataSource.appendMessage(message2, animatingDifferences: false)
        dataSource.appendMessage(message3, animatingDifferences: false)

        #expect(dataSource.messages.count == 3)
        #expect(dataSource.messages[0].id == message1.id)
        #expect(dataSource.messages[1].id == message2.id)
        #expect(dataSource.messages[2].id == message3.id)
    }

    // MARK: - Prepend Messages Tests

    @Test("在头部插入历史消息")
    func testPrependMessages() {
        let collectionView = makeTestCollectionView()
        let dataSource = MessageDataSource(collectionView: collectionView)

        // 先添加一条消息
        let currentMessage = makeTestMessage(text: "当前消息")
        dataSource.appendMessage(currentMessage, animatingDifferences: false)

        // 在头部插入历史消息
        let historyMessage1 = makeTestMessage(text: "历史消息1")
        let historyMessage2 = makeTestMessage(text: "历史消息2")
        dataSource.prependMessages([historyMessage1, historyMessage2])

        #expect(dataSource.messages.count == 3)
        #expect(dataSource.messages[0].id == historyMessage1.id)
        #expect(dataSource.messages[1].id == historyMessage2.id)
        #expect(dataSource.messages[2].id == currentMessage.id)
    }

    // MARK: - Delete Message Tests

    @Test("删除消息")
    func testDeleteMessage() {
        let collectionView = makeTestCollectionView()
        let dataSource = MessageDataSource(collectionView: collectionView)

        let message1 = makeTestMessage(text: "消息1")
        let message2 = makeTestMessage(text: "消息2")
        let message3 = makeTestMessage(text: "消息3")

        dataSource.appendMessage(message1, animatingDifferences: false)
        dataSource.appendMessage(message2, animatingDifferences: false)
        dataSource.appendMessage(message3, animatingDifferences: false)

        // 删除中间的消息
        let deleted = dataSource.deleteMessage(id: message2.id)

        #expect(deleted?.id == message2.id)
        #expect(dataSource.messages.count == 2)
        #expect(dataSource.messages[0].id == message1.id)
        #expect(dataSource.messages[1].id == message3.id)
    }

    @Test("删除不存在的消息")
    func testDeleteNonExistentMessage() {
        let collectionView = makeTestCollectionView()
        let dataSource = MessageDataSource(collectionView: collectionView)

        let message = makeTestMessage(text: "消息")
        dataSource.appendMessage(message, animatingDifferences: false)

        // 尝试删除不存在的消息
        let deleted = dataSource.deleteMessage(id: MessageIDGenerator.next())

        #expect(deleted == nil)
        #expect(dataSource.messages.count == 1)
    }

    // MARK: - Replace Message Tests

    @Test("替换消息（撤回场景）")
    func testReplaceMessage() {
        let collectionView = makeTestCollectionView()
        let dataSource = MessageDataSource(collectionView: collectionView)

        let originalMessage = makeTestMessage(text: "原始消息")
        dataSource.appendMessage(originalMessage, animatingDifferences: false)

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

        dataSource.replaceMessage(id: originalMessage.id, with: recalledMessage)

        #expect(dataSource.messages.count == 1)
        if case .recalled(let text) = dataSource.messages[0].kind {
            #expect(text == "原始消息")
        } else {
            Issue.record("消息类型应该是 recalled")
        }
    }

    // MARK: - Mark As Played Tests

    @Test("标记消息为已播放")
    func testMarkAsPlayed() {
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

        dataSource.appendMessage(message, animatingDifferences: false)

        // 标记为已播放
        dataSource.markAsPlayed(id: message.id)

        #expect(dataSource.messages[0].isPlayed == true)
    }

    // MARK: - Update Send Status Tests

    @Test("更新消息发送状态")
    func testUpdateSendStatus() {
        let collectionView = makeTestCollectionView()
        let dataSource = MessageDataSource(collectionView: collectionView)

        var message = makeTestMessage(text: "发送中的消息")
        message.sendStatus = .sending

        dataSource.appendMessage(message, animatingDifferences: false)

        // 更新为已送达
        dataSource.updateSendStatus(id: message.id, status: ChatMessage.SendStatus.delivered)

        #expect(dataSource.messages[0].sendStatus == ChatMessage.SendStatus.delivered)
    }

    @Test("更新为发送失败状态")
    func testUpdateSendStatusToFailed() {
        let collectionView = makeTestCollectionView()
        let dataSource = MessageDataSource(collectionView: collectionView)

        var message = makeTestMessage(text: "发送失败的消息")
        message.sendStatus = .sending

        dataSource.appendMessage(message, animatingDifferences: false)

        // 更新为失败
        dataSource.updateSendStatus(id: message.id, status: ChatMessage.SendStatus.failed)

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

        dataSource.appendMessage(message1, animatingDifferences: false)
        dataSource.appendMessage(message2, animatingDifferences: false)
        dataSource.appendMessage(message3, animatingDifferences: false)

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

        dataSource.appendMessage(message1, animatingDifferences: false)
        dataSource.appendMessage(message2, animatingDifferences: false)

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

        // 删除不存在的消息
        let deleted = dataSource.deleteMessage(id: MessageIDGenerator.next())
        #expect(deleted == nil)

        // 查找不存在的索引
        let index = dataSource.index(of: MessageIDGenerator.next())
        #expect(index == nil)

        // 获取越界的消息
        let message = dataSource.message(at: 0)
        #expect(message == nil)
    }
}
