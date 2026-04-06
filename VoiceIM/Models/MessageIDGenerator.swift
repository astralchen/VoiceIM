import Foundation

/// 消息 ID 生成器：生产级有序唯一标识
///
/// 生成格式：`{毫秒时间戳hex(12位)}-{随机4字节hex(8位)}`
/// 示例：`018f3a2b4c00-a1b2c3d4`（共 21 字符）
///
/// # 设计要求
/// - **有序性**：前缀为毫秒时间戳的十六进制，天然按时间排序，
///   可直接用作分页游标和数据库索引排序依据
/// - **唯一性**：后缀为 4 字节随机数（约 40 亿种），同一毫秒内碰撞概率极低
/// - **紧凑性**：21 字符，远小于 UUID 的 36 字符
/// - **可读性**：纯小写十六进制 + 连字符，便于日志排查
///
/// # 与 UUID 的对比
/// | 维度 | UUID v4 | MessageIDGenerator |
/// |------|---------|-------------------|
/// | 长度 | 36 字符 | 21 字符 |
/// | 有序性 | 无序 | 毫秒级时间递增 |
/// | 排序 | 不可用 | 字符串排序 = 时间排序 |
/// | 碰撞率 | ~2^122 | ~2^32/ms（同毫秒内） |
enum MessageIDGenerator {

    /// 生成下一个消息 ID
    static func next() -> String {
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)
        var randomBytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, 4, &randomBytes)
        let randomHex = randomBytes.map { String(format: "%02x", $0) }.joined()
        return String(format: "%012llx", ms) + "-" + randomHex
    }
}
