import Foundation
import Combine

/// 会话列表 ViewModel
///
/// 使用 `MessageStorage.loadConversationSummaries()` 一次查询获取
/// 各会话未读数与最后一条消息预览，避免对每条会话再查预览。
@MainActor
final class ConversationListViewModel: ObservableObject {
    @Published private(set) var conversations: [ConversationSummary] = []
    @Published var error: ChatError?

    private let contacts: [Contact]
    private let storage: MessageStorage
    private let logger: Logger
    #if DEBUG
    private static let seedFlagKey = "com.voiceim.debug.seeded.contacts.v1"
    #endif

    init(
        contacts: [Contact] = Contact.mockContacts,
        storage: MessageStorage = .shared,
        logger: Logger = VoiceIM.logger
    ) {
        self.contacts = contacts
        self.storage = storage
        self.logger = logger
    }

    func loadConversations() {
        Task {
            do {
                #if DEBUG
                try await ensureSeedMessagesIfNeeded()
                #endif

                // 一次聚合查询替代逐会话 N+1
                let dbSummaries = try await storage.loadConversationSummaries()
                let allConversationIDs = Set(try await storage.loadAllConversationIDs())

                var summaries: [ConversationSummary] = []
                for (conv, unread, isPinned, previewText, previewMs) in dbSummaries {
                    let contact = contacts.first { $0.id == conv.id }
                        ?? Contact(id: conv.id, displayName: conv.title ?? conv.id)
                    let lastTime = previewMs.map {
                        Date(timeIntervalSince1970: Double($0) / 1000)
                    } ?? conv.lastMessageAtMs.map {
                        Date(timeIntervalSince1970: Double($0) / 1000)
                    }
                    summaries.append(ConversationSummary(
                        contact: contact,
                        lastMessagePreview: previewText,
                        lastMessageTime: lastTime,
                        unreadCount: unread,
                        isPinned: isPinned
                    ))
                }

                // 含本地联系人但无数据库会话的（尚未聊过天），也显示空会话
                let existingIDs = allConversationIDs
                var placeholders: [ConversationSummary] = []
                for contact in contacts where !existingIDs.contains(contact.id) {
                    placeholders.append(ConversationSummary(
                        contact: contact,
                        lastMessagePreview: "",
                        lastMessageTime: nil,
                        unreadCount: 0,
                        isPinned: false
                    ))
                }

                // dbSummaries 已按会话活跃度排序（last_message_at_ms 为空时退化到 updated_at_ms）
                // 仅对"尚未建会话"的本地占位联系人按名称排序并追加到底部
                placeholders.sort {
                    $0.contact.displayName.localizedCompare($1.contact.displayName) == .orderedAscending
                }
                conversations = summaries + placeholders
            } catch {
                logger.error("加载会话列表失败: \(error)")
                self.error = error as? ChatError ?? .unknown(error)
            }
        }
    }

    /// 侧滑：标记会话已读（未读归零并写入回执）
    func markConversationAsRead(contactID: String) {
        Task {
            do {
                try await storage.markConversationAsRead(contactID: contactID)
                loadConversations()
            } catch {
                logger.error("标记已读失败: \(error)")
                self.error = error as? ChatError ?? .unknown(error)
            }
        }
    }

    func setConversationPinned(contactID: String, pinned: Bool) {
        Task {
            do {
                try await storage.setConversationPinned(contactID: contactID, pinned: pinned)
                loadConversations()
            } catch {
                logger.error("更新置顶状态失败: \(error)")
                self.error = error as? ChatError ?? .unknown(error)
            }
        }
    }

    /// 侧滑：不显示该会话（直到有新消息自动恢复）
    func setConversationHidden(contactID: String, hidden: Bool) {
        Task {
            do {
                try await storage.setConversationHidden(contactID: contactID, hidden: hidden)
                loadConversations()
            } catch {
                logger.error("更新会话显示状态失败: \(error)")
                self.error = error as? ChatError ?? .unknown(error)
            }
        }
    }

    /// 侧滑：从列表删除会话（数据库物理删除）
    func deleteConversation(contactID: String) {
        Task {
            do {
                try await storage.deleteConversation(contactID: contactID)
                loadConversations()
            } catch {
                logger.error("删除会话失败: \(error)")
                self.error = error as? ChatError ?? .unknown(error)
            }
        }
    }

    #if DEBUG
    private func ensureSeedMessagesIfNeeded() async throws {
        if UserDefaults.standard.bool(forKey: Self.seedFlagKey) {
            return
        }

        var hasExistingMessages = false
        for (index, contact) in contacts.enumerated() {
            let existing = try await storage.load(contactID: contact.id)
            if !existing.isEmpty {
                hasExistingMessages = true
                continue
            }
            let seed = makeSeedMessages(for: contact, index: index)
            try await storage.save(seed, contactID: contact.id)
        }

        // 仅首次初始化时补数据；后续尊重用户删除行为，不再自动回填
        if hasExistingMessages || !contacts.isEmpty {
            UserDefaults.standard.set(true, forKey: Self.seedFlagKey)
        }
    }

    private func makeSeedMessages(for contact: Contact, index: Int) -> [ChatMessage] {
        let now = Date()
        let peer = Sender(id: contact.id, displayName: contact.displayName)
        return [
            ChatMessage.text(
                "你好，我是\(contact.displayName)。",
                sender: peer,
                sentAt: now.addingTimeInterval(-3600),
                sendStatus: .delivered
            ),
            ChatMessage.text(
                "你好，收到。",
                sender: .me,
                sentAt: now.addingTimeInterval(-3200),
                sendStatus: .delivered
            ),
            ChatMessage(
                kind: .text("今晚有空聊下进度吗？"),
                sender: peer,
                sentAt: now.addingTimeInterval(-Double((index + 1) * 700)),
                isPlayed: true,
                isRead: index % 2 == 0 ? false : true,
                sendStatus: .delivered
            )
        ]
    }
    #endif
}
