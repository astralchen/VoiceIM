import Foundation
import GRDB

/// 数据库版本化迁移
///
/// # 迁移规则
/// 1. 所有迁移按版本号顺序注册，GRDB 自动跳过已执行的迁移
/// 2. **禁止修改已上线迁移**——只能在末尾追加新迁移
/// 3. 新版本发布前，在 `registerAll` 末尾追加新的 `registerMigration` 调用
///
/// # 表关系概览
/// ```
/// users ──1:N──▶ conversation_members ◀──N:1── conversations
///                                               │
/// conversations ──1:N──▶ messages ──1:N──▶ message_receipts
///                           │
///                           └──1:N──▶ message_attachments
///
/// conversations ──1:N──▶ conversation_settings
/// ```
///
/// # 外键删除策略
/// - `conversations → users`：`ON DELETE SET NULL`（群主被删不影响群）
/// - `messages → conversations`：`ON DELETE CASCADE`（会话物理删除时级联清消息）
/// - `messages → users`：`ON DELETE SET NULL`（用户注销不丢消息）
/// - `conversation_members → conversations/users`：`ON DELETE CASCADE`
/// - `message_receipts → messages/users`：`ON DELETE CASCADE`
/// - `message_attachments → messages`：`ON DELETE CASCADE`
/// - `conversation_settings → conversations/users`：`ON DELETE CASCADE`
///
/// # 删除策略
/// 业务层使用物理删除。删除会话时依赖外键 CASCADE 自动清理 messages / members / settings 等关联数据。
enum DatabaseMigrations {

    static func registerAll(in migrator: inout DatabaseMigrator) {
        // v1：初始表结构（7 张核心表）
        migrator.registerMigration("v1_create_tables") { db in
            try createUsersTable(db)
            try createConversationsTable(db)
            try createConversationMembersTable(db)
            try createMessagesTable(db)
            try createMessageReceiptsTable(db)
            try createMessageAttachmentsTable(db)
            try createConversationSettingsTable(db)
        }

        // v1：索引（与表创建分开注册，便于后续单独追加索引迁移）
        migrator.registerMigration("v1_create_indexes") { db in
            try createIndexes(db)
        }
    }

    // MARK: - 表结构

    /// 用户表：存储所有出现过的用户信息
    ///
    /// - 主键：服务端用户 ID（文本），支持多端同步
    /// - status：0=正常, 1=已注销
    private static func createUsersTable(_ db: Database) throws {
        try db.create(table: "users") { t in
            t.column("id", .text).notNull().primaryKey()
            t.column("display_name", .text).notNull()
            t.column("avatar_url", .text)
            t.column("status", .integer).notNull().defaults(to: 0)
            t.column("created_at_ms", .integer).notNull()
            t.column("updated_at_ms", .integer).notNull()
        }
    }

    /// 会话表：每个单聊/群聊一条记录
    ///
    /// - type：0=单聊, 1=群聊
    /// - last_message_id / last_message_at_ms：冗余字段，
    ///   每次消息写入时事务内同步更新，避免会话列表查询 JOIN messages
    /// - version：乐观锁版本号，用于多端并发写入冲突检测
    /// - deleted_at_ms：预留审计字段（当前业务采用物理删除）
    private static func createConversationsTable(_ db: Database) throws {
        try db.create(table: "conversations") { t in
            t.column("id", .text).notNull().primaryKey()
            t.column("type", .integer).notNull().defaults(to: 0)
            t.column("title", .text)
            t.column("owner_user_id", .text)
                .references("users", onDelete: .setNull)
            t.column("last_message_id", .text)
            t.column("last_message_at_ms", .integer)
            t.column("version", .integer).notNull().defaults(to: 1)
            t.column("is_muted_default", .boolean).notNull().defaults(to: false)
            t.column("created_at_ms", .integer).notNull()
            t.column("updated_at_ms", .integer).notNull()
            t.column("deleted_at_ms", .integer)
        }
    }

    /// 会话成员表：记录每个用户在每个会话中的身份与状态
    ///
    /// - 联合主键：(conversation_id, user_id)
    /// - role：0=普通成员, 1=管理员, 2=群主
    /// - unread_count：该成员在此会话的未读消息数，
    ///   收到对方消息时 +1，进入会话已读时归零（事务内更新）
    /// - last_read_message_seq：该成员最后已读的消息序号，
    ///   用于断线重连后精确补齐未读回执
    private static func createConversationMembersTable(_ db: Database) throws {
        try db.create(table: "conversation_members") { t in
            t.column("conversation_id", .text).notNull()
                .references("conversations", onDelete: .cascade)
            t.column("user_id", .text).notNull()
                .references("users", onDelete: .cascade)
            t.column("role", .integer).notNull().defaults(to: 0)
            t.column("joined_at_ms", .integer).notNull()
            t.column("left_at_ms", .integer)
            t.column("is_muted", .boolean).notNull().defaults(to: false)
            t.column("unread_count", .integer).notNull().defaults(to: 0)
            t.column("last_read_message_seq", .integer).notNull().defaults(to: 0)
            t.column("updated_at_ms", .integer).notNull()
            t.primaryKey(["conversation_id", "user_id"])
        }
    }

    /// 消息表：核心数据表
    ///
    /// - seq：会话内严格递增序号，配合 (conversation_id, seq) 唯一索引保证时序
    /// - client_msg_id：客户端生成的幂等键（唯一字符串），防止网络重发产生重复消息
    /// - kind：消息类型枚举（0=text, 1=voice, 2=image, 3=video, 4=recalled, 5=location）
    /// - body_text：文本消息正文 / 撤回消息原文（用于"重新编辑"功能）
    /// - ext_json：扩展字段，存储消息类型特有数据（如位置消息的经纬度）
    /// - recalled_at_ms / edited_at_ms / deleted_at_ms：
    ///   独立时间字段，不覆盖原始数据，保证撤回/编辑/删除的审计可追溯（deleted_at_ms 当前预留）
    private static func createMessagesTable(_ db: Database) throws {
        try db.create(table: "messages") { t in
            t.column("id", .text).notNull().primaryKey()
            t.column("conversation_id", .text).notNull()
                .references("conversations", onDelete: .cascade)
            t.column("seq", .integer).notNull()
            t.column("client_msg_id", .text).notNull().unique()
            t.column("sender_user_id", .text).notNull()
                .references("users", onDelete: .restrict)
            t.column("kind", .integer).notNull()
            t.column("body_text", .text)
            t.column("ext_json", .text)
            t.column("send_status", .integer).notNull().defaults(to: 0)
            t.column("created_at_ms", .integer).notNull()
            t.column("server_at_ms", .integer)
            t.column("edited_at_ms", .integer)
            t.column("recalled_at_ms", .integer)
            t.column("deleted_at_ms", .integer)
            t.uniqueKey(["conversation_id", "seq"])
        }
    }

    /// 消息回执表：追踪每条消息在每个用户维度的送达/已读/已播放状态
    ///
    /// - 联合主键：(message_id, user_id)
    /// - 群聊场景下同一条消息会有多条回执（每个群成员一条）
    /// - played_at_ms：专为语音消息设计，非语音消息此字段为 NULL
    private static func createMessageReceiptsTable(_ db: Database) throws {
        try db.create(table: "message_receipts") { t in
            t.column("message_id", .text).notNull()
                .references("messages", onDelete: .cascade)
            t.column("user_id", .text).notNull()
                .references("users", onDelete: .cascade)
            t.column("delivered_at_ms", .integer)
            t.column("read_at_ms", .integer)
            t.column("played_at_ms", .integer)
            t.column("updated_at_ms", .integer).notNull()
            t.primaryKey(["message_id", "user_id"])
        }
    }

    /// 消息附件表：存储语音/图片/视频等媒体文件的元信息
    ///
    /// - media_type：0=voice, 1=image, 2=video
    /// - local_path：仅保存文件名（不含目录），读取时拼接对应缓存目录
    /// - sha256 / size_bytes：完整性校验字段，用于下载后验证文件是否损坏
    /// - duration_ms：语音/视频时长（毫秒精度）
    private static func createMessageAttachmentsTable(_ db: Database) throws {
        try db.create(table: "message_attachments") { t in
            t.column("id", .text).notNull().primaryKey()
            t.column("message_id", .text).notNull()
                .references("messages", onDelete: .cascade)
            t.column("media_type", .integer).notNull()
            t.column("local_path", .text)
            t.column("remote_url", .text)
            t.column("sha256", .text)
            t.column("size_bytes", .integer)
            t.column("duration_ms", .integer)
            t.column("width", .integer)
            t.column("height", .integer)
            t.column("created_at_ms", .integer).notNull()
        }
    }

    /// 会话设置表：每个用户对每个会话的个性化配置
    ///
    /// - 联合主键：(conversation_id, user_id)
    /// - is_pinned：置顶会话
    /// - is_hidden：隐藏会话（不删除数据，仅从列表移除）
    /// - mute_until_ms：免打扰截止时间（NULL=不免打扰，0=永久免打扰）
    private static func createConversationSettingsTable(_ db: Database) throws {
        try db.create(table: "conversation_settings") { t in
            t.column("conversation_id", .text).notNull()
                .references("conversations", onDelete: .cascade)
            t.column("user_id", .text).notNull()
                .references("users", onDelete: .cascade)
            t.column("is_pinned", .boolean).notNull().defaults(to: false)
            t.column("is_hidden", .boolean).notNull().defaults(to: false)
            t.column("mute_until_ms", .integer)
            t.column("updated_at_ms", .integer).notNull()
            t.primaryKey(["conversation_id", "user_id"])
        }
    }

    // MARK: - 索引

    /// 生产级索引策略
    ///
    /// 设计原则：覆盖高频查询路径，避免全表扫描
    /// 可通过 `EXPLAIN QUERY PLAN` 验证索引命中情况
    private static func createIndexes(_ db: Database) throws {
        // 聊天页分页加载：WHERE conversation_id = ? ORDER BY seq DESC LIMIT 20
        try db.create(
            index: "idx_messages_conv_seq",
            on: "messages",
            columns: ["conversation_id", "seq"],
            unique: false
        )

        // 最近消息拉取：WHERE conversation_id = ? ORDER BY created_at_ms DESC
        try db.create(
            index: "idx_messages_conv_created",
            on: "messages",
            columns: ["conversation_id", "created_at_ms"]
        )

        // 会话列表排序：ORDER BY last_message_at_ms DESC
        try db.create(
            index: "idx_conversations_last_msg",
            on: "conversations",
            columns: ["last_message_at_ms"]
        )

        // 当前用户的会话未读聚合：WHERE user_id = ? ORDER BY unread_count DESC
        try db.create(
            index: "idx_members_user_unread",
            on: "conversation_members",
            columns: ["user_id", "unread_count"]
        )

        // 已读同步/补偿扫描：WHERE user_id = ? AND read_at_ms IS NULL
        try db.create(
            index: "idx_receipts_user_read",
            on: "message_receipts",
            columns: ["user_id", "read_at_ms"]
        )

        // 媒体文件回收与预加载：WHERE message_id = ?
        try db.create(
            index: "idx_attachments_message",
            on: "message_attachments",
            columns: ["message_id"]
        )
    }
}
