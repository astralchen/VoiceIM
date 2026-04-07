import Foundation
import GRDB

/// 数据库管理器：全局唯一的 SQLite 连接与迁移入口
///
/// # 职责
/// 1. 持有并管理 `DatabaseQueue`（GRDB 的线程安全连接池）
/// 2. 启动时自动执行版本化迁移（`DatabaseMigrations`）
/// 3. 强制开启 SQLite 外键约束（`PRAGMA foreign_keys = ON`）
/// 4. 在 SQLCipher 构建下自动从 Keychain 读取/生成密钥并启用加密
///
/// # 加密（SQLCipher）与编译宏
/// - 仅当工程 **定义 `SQLITE_HAS_CODEC`** 且链接 SQLCipher 版 GRDB 时，下方 `usePassphrase` / `cipherVersion` 才会参与编译与运行。
/// - 当前默认 SPM 包多为系统 SQLite：未定义该宏时，数据库为**明文**文件，但迁移与外键逻辑仍生效。
/// - DEBUG 下若启用 SQLCipher，会打 `PRAGMA cipher_version` 自检日志。
///
/// # 线程安全
/// `DatabaseQueue` 内部串行化所有数据库访问，`DatabaseManager` 本身是 `Sendable`，
/// 可以安全地从任意线程/actor 调用 `read`/`write`。
///
/// # 与存储层的关系
/// ```
/// DatabaseManager（连接 + 迁移）
///       ↓ 注入
/// MessageStorage（门面）→ MessageStore / ConversationStore / ReceiptStore
///       ↓ 被调用
/// MessageRepository / ConversationListViewModel（@MainActor）
/// ```
final class DatabaseManager: Sendable {

    /// GRDB 连接。所有读写操作通过此对象序列化执行。
    let dbQueue: DatabaseQueue

    /// 数据库文件在磁盘上的绝对路径，用于计算文件大小等运维操作
    let databasePath: String

    // MARK: - 单例

    /// 生产环境使用的全局实例。
    /// 路径固定为 `Documents/VoiceIM/voiceim.sqlite`。
    static let shared: DatabaseManager = {
        let path = defaultDatabasePath()
        do {
            let passphrase = try makeDatabasePassphraseIfNeeded()
            return try DatabaseManager(path: path, passphrase: passphrase)
        } catch {
            fatalError("数据库初始化失败: \(error)")
        }
    }()

    // MARK: - 初始化

    /// 创建数据库管理器
    ///
    /// - Parameters:
    ///   - path: 数据库文件路径。父目录不存在时自动创建。
    ///   - passphrase: 数据库加密密码。仅在 SQLCipher 构建下生效。
    /// - Throws: 目录创建失败或 GRDB 连接/迁移失败
    init(path: String, passphrase: String? = nil) throws {
        self.databasePath = path

        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )

        var config = Configuration()

        // 外键约束：保证 conversation_members、messages 等表的引用完整性。
        // 每次打开连接都需要执行，因为 SQLite 默认关闭外键。
        config.prepareDatabase { db in
            #if SQLITE_HAS_CODEC
            // 口令来自 Keychain；无 passphrase 时仍打开库（兼容测试路径），生产接 Cipher 后应保证有密钥。
            if let passphrase {
                try db.usePassphrase(passphrase)
                _ = try db.cipherVersion
            }
            #endif
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        dbQueue = try DatabaseQueue(path: path, configuration: config)

        // 执行版本化迁移。
        // DEBUG 模式下 eraseDatabaseOnSchemaChange = true，
        // 表结构变动时自动重建（仅开发阶段使用，生产务必关闭）。
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
        DatabaseMigrations.registerAll(in: &migrator)
        try migrator.migrate(dbQueue)

        #if DEBUG
        try logEncryptionRuntimeStatus()
        #endif
    }

    // MARK: - 读写入口

    /// 只读事务。适用于查询操作，GRDB 保证读取期间数据一致性。
    func read<T>(_ block: (Database) throws -> T) throws -> T {
        try dbQueue.read(block)
    }

    /// 读写事务。写入操作自动包裹在 `BEGIN IMMEDIATE ... COMMIT` 事务中，
    /// 保证原子性（要么全部成功，要么全部回滚）。
    func write<T>(_ block: (Database) throws -> T) throws -> T {
        try dbQueue.write(block)
    }

    // MARK: - 运维工具

    /// 返回 SQLite 数据库文件的磁盘占用（字节），用于设置页"存储空间"展示
    func databaseFileSize() -> UInt64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: databasePath),
              let size = attrs[.size] as? UInt64 else { return 0 }
        return size
    }

    /// 轮换数据库加密密钥。
    ///
    /// 流程：
    /// 1. 生成并写入 Keychain 新密钥
    /// 2. 对当前数据库执行 `PRAGMA rekey`
    /// 3. 任一步骤失败时抛错，由上层决定是否告警
    func rotateDatabasePassphrase() throws {
        #if SQLITE_HAS_CODEC
        let newPassphrase = try KeychainHelper.rotatePassphrase()
        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA rekey = ?", arguments: [newPassphrase])
        }
        #else
        throw ChatError.storageWriteFailed
        #endif
    }

    // MARK: - 默认路径

    private static func makeDatabasePassphraseIfNeeded() throws -> String? {
        #if SQLITE_HAS_CODEC
        return try KeychainHelper.loadOrCreatePassphrase()
        #else
        return nil
        #endif
    }

    private static func defaultDatabasePath() -> String {
        guard let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first else {
            fatalError("无法获取 Documents 目录")
        }
        return docs
            .appendingPathComponent("VoiceIM", isDirectory: true)
            .appendingPathComponent("voiceim.sqlite")
            .path
    }

    #if DEBUG
    /// DEBUG 启动自检：确认当前运行时是否启用 SQLCipher。
    /// 该日志用于验证“已链接且已启用”而不是仅代码路径预留。
    private func logEncryptionRuntimeStatus() throws {
        #if SQLITE_HAS_CODEC
        try dbQueue.read { db in
            let cipherVersion = try String.fetchOne(db, sql: "PRAGMA cipher_version")
            if let cipherVersion, !cipherVersion.isEmpty {
                logger.info("数据库加密已启用，SQLCipher 版本: \(cipherVersion)")
            } else {
                logger.warning("SQLITE_HAS_CODEC 已开启，但未读取到 cipher_version")
            }
        }
        #else
        logger.warning("当前构建未启用 SQLITE_HAS_CODEC，数据库将以明文 SQLite 运行")
        #endif
    }
    #endif
}
