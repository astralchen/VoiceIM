import Foundation

// 能力边界拆分：消息 / 会话 / 回执
extension MessageStorage: MessageStorageProtocol {}
extension MessageStorage: ConversationStorageProtocol {}
extension MessageStorage: ReceiptStorageProtocol {}
