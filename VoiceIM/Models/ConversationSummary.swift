import Foundation

/// 会话列表摘要（用于会话页展示）
struct ConversationSummary: Sendable, Hashable {
    let contact: Contact
    let lastMessagePreview: String
    let lastMessageTime: Date?
    let unreadCount: Int
    let isPinned: Bool
}
