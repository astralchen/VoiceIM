import Foundation

/// 消息发送者身份。
///
/// `id` 用于区分"自己"与"对方"并生成头像颜色；`displayName` 取首字母作为头像文字。
/// 实际项目中替换为服务器返回的用户 ID 与昵称。
struct Sender: Sendable, Hashable, Codable {

    let id: String
    let displayName: String

    /// 当前用户（消息靠右显示）
    static let me   = Sender(id: "me",   displayName: "我")
    /// 对方（消息靠左显示）
    static let peer = Sender(id: "peer", displayName: "友")
}
