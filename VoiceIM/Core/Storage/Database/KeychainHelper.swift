import Foundation
import Security

/// Keychain 密钥管理
///
/// 生产环境用于存储/读取数据库加密密钥。
/// 密钥存放在应用 Keychain 中，受 iOS 数据保护等级控制。
/// SQLCipher 接入后，由 `DatabaseManager` 在打开连接前调用 `loadOrCreatePassphrase`。
enum KeychainHelper {

    private static let service = "com.voiceim.db"
    private static let account = "db_encryption_key"

    /// 获取已有密钥或生成新密钥（32 字节随机数 → Base64 编码字符串）
    static func loadOrCreatePassphrase() throws -> String {
        if let existing = try loadPassphrase() {
            return existing
        }
        let newKey = generateRandomKey(length: 32)
        try savePassphrase(newKey)
        return newKey
    }

    /// 轮换密钥：生成新密钥并覆盖旧密钥
    /// 调用方负责在数据库层执行 `PRAGMA rekey`
    static func rotatePassphrase() throws -> String {
        let newKey = generateRandomKey(length: 32)
        try deletePassphrase()
        try savePassphrase(newKey)
        return newKey
    }

    // MARK: - 读

    private static func loadPassphrase() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let str = String(data: data, encoding: .utf8) else {
                return nil
            }
            return str
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unhandledError(status: status)
        }
    }

    // MARK: - 写

    private static func savePassphrase(_ passphrase: String) throws {
        guard let data = passphrase.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandledError(status: status)
        }
    }

    // MARK: - 删

    private static func deletePassphrase() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledError(status: status)
        }
    }

    // MARK: - 随机密钥

    private static func generateRandomKey(length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return Data(bytes).base64EncodedString()
    }

    // MARK: - 错误类型

    enum KeychainError: Error {
        case encodingFailed
        case unhandledError(status: OSStatus)
    }
}
