# GRDB 表关系图（ER）

本文档基于当前 `Migrations.swift` 的真实结构整理，用于快速查看表之间的主外键关系与级联策略。

## 1. Mermaid ER 图

```mermaid
erDiagram
    USERS {
        TEXT id PK
        TEXT display_name
        TEXT avatar_url
        INT status
        INT created_at_ms
        INT updated_at_ms
    }

    CONVERSATIONS {
        TEXT id PK
        INT type
        TEXT title
        TEXT owner_user_id FK
        TEXT last_message_id
        INT last_message_at_ms
        INT version
        BOOL is_muted_default
        INT created_at_ms
        INT updated_at_ms
        INT deleted_at_ms
    }

    CONVERSATION_MEMBERS {
        TEXT conversation_id PK,FK
        TEXT user_id PK,FK
        INT role
        INT joined_at_ms
        INT left_at_ms
        BOOL is_muted
        INT unread_count
        INT last_read_message_seq
        INT updated_at_ms
    }

    MESSAGES {
        TEXT id PK
        TEXT conversation_id FK
        INT seq
        TEXT client_msg_id UK
        TEXT sender_user_id FK
        INT kind
        TEXT body_text
        TEXT ext_json
        INT send_status
        INT created_at_ms
        INT server_at_ms
        INT edited_at_ms
        INT recalled_at_ms
        INT deleted_at_ms
    }

    MESSAGE_RECEIPTS {
        TEXT message_id PK,FK
        TEXT user_id PK,FK
        INT delivered_at_ms
        INT read_at_ms
        INT played_at_ms
        INT updated_at_ms
    }

    MESSAGE_ATTACHMENTS {
        TEXT id PK
        TEXT message_id FK
        INT media_type
        TEXT local_path
        TEXT remote_url
        TEXT sha256
        INT size_bytes
        INT duration_ms
        INT width
        INT height
        INT created_at_ms
    }

    CONVERSATION_SETTINGS {
        TEXT conversation_id PK,FK
        TEXT user_id PK,FK
        BOOL is_pinned
        BOOL is_hidden
        INT mute_until_ms
        INT updated_at_ms
    }

    USERS ||--o{ CONVERSATION_MEMBERS : "membership"
    CONVERSATIONS ||--o{ CONVERSATION_MEMBERS : "members"

    CONVERSATIONS ||--o{ MESSAGES : "contains"
    USERS ||--o{ MESSAGES : "sender_user_id"

    MESSAGES ||--o{ MESSAGE_RECEIPTS : "receipts"
    USERS ||--o{ MESSAGE_RECEIPTS : "receiver_user_id"

    MESSAGES ||--o{ MESSAGE_ATTACHMENTS : "attachments"

    CONVERSATIONS ||--o{ CONVERSATION_SETTINGS : "per-user settings"
    USERS ||--o{ CONVERSATION_SETTINGS : "owner user"

    USERS o|--o{ CONVERSATIONS : "owner_user_id (nullable)"
```

## 2. 关键外键删除策略

- `conversations.owner_user_id -> users.id`: `ON DELETE SET NULL`
- `conversation_members.conversation_id -> conversations.id`: `ON DELETE CASCADE`
- `conversation_members.user_id -> users.id`: `ON DELETE CASCADE`
- `messages.conversation_id -> conversations.id`: `ON DELETE CASCADE`
- `messages.sender_user_id -> users.id`: `ON DELETE RESTRICT`
- `message_receipts.message_id -> messages.id`: `ON DELETE CASCADE`
- `message_receipts.user_id -> users.id`: `ON DELETE CASCADE`
- `message_attachments.message_id -> messages.id`: `ON DELETE CASCADE`
- `conversation_settings.conversation_id -> conversations.id`: `ON DELETE CASCADE`
- `conversation_settings.user_id -> users.id`: `ON DELETE CASCADE`

## 3. 表格版关系总览

| 子表 | 子表字段 | 父表 | 父表字段 | 基数 | ON DELETE | 说明 |
|---|---|---|---|---|---|---|
| `conversations` | `owner_user_id` | `users` | `id` | N:1 | `SET NULL` | 群主/会话所有者可为空 |
| `conversation_members` | `conversation_id` | `conversations` | `id` | N:1 | `CASCADE` | 会话删除后成员关系自动清理 |
| `conversation_members` | `user_id` | `users` | `id` | N:1 | `CASCADE` | 用户删除后成员关系自动清理 |
| `messages` | `conversation_id` | `conversations` | `id` | N:1 | `CASCADE` | 会话删除后消息自动清理 |
| `messages` | `sender_user_id` | `users` | `id` | N:1 | `RESTRICT` | 防止误删发送者导致消息孤儿 |
| `message_receipts` | `message_id` | `messages` | `id` | N:1 | `CASCADE` | 消息删除后回执自动清理 |
| `message_receipts` | `user_id` | `users` | `id` | N:1 | `CASCADE` | 用户删除后回执自动清理 |
| `message_attachments` | `message_id` | `messages` | `id` | N:1 | `CASCADE` | 消息删除后附件元数据自动清理 |
| `conversation_settings` | `conversation_id` | `conversations` | `id` | N:1 | `CASCADE` | 会话删除后置顶/隐藏配置清理 |
| `conversation_settings` | `user_id` | `users` | `id` | N:1 | `CASCADE` | 用户删除后个性化配置清理 |

## 4. 主键与唯一约束（摘要）

| 表 | 主键 | 关键唯一约束 |
|---|---|---|
| `users` | `id` | - |
| `conversations` | `id` | - |
| `conversation_members` | `(conversation_id, user_id)` | - |
| `messages` | `id` | `client_msg_id`、`(conversation_id, seq)` |
| `message_receipts` | `(message_id, user_id)` | - |
| `message_attachments` | `id` | - |
| `conversation_settings` | `(conversation_id, user_id)` | - |

