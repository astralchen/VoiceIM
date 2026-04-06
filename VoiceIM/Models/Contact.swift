import Foundation

/// 会话联系人
struct Contact: Sendable, Hashable, Codable {
    let id: String
    let displayName: String
}

extension Contact {
    static let mockContacts: [Contact] = [
        Contact(id: "zhangsan", displayName: "张三"),
        Contact(id: "lisi", displayName: "李四"),
        Contact(id: "wangwu", displayName: "王五"),
        Contact(id: "zhaoliu", displayName: "赵六")
    ]
}
