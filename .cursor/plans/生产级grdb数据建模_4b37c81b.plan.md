---
name: 生产级GRDB数据建模
overview: 基于当前工程代码（2026-04）更新的执行现状：GRDB 关系模型已落地并持续演进，新增会话置顶/隐藏、会话页与通讯录页 CollectionView 化；同时明确仍未完成的生产级项（SQLCipher、群聊语义、性能验证等）。
todos:
  - id: schema-ddl
    content: 定义生产级表结构、外键、唯一约束与审计字段
    status: completed
  - id: migrations
    content: 建立 GRDB 迁移框架并实现首版迁移
    status: completed
  - id: store-split
    content: 拆分 MessageStorage 为消息/会话/回执存储接口与能力边界
    status: completed
  - id: repo-adapt
    content: 改造 MessageRepository 与 ViewModel 对齐新关系模型（含群聊语义）
    status: completed
  - id: security-hardening
    content: 接入高安全策略：加密、密钥管理、日志脱敏
    status: completed
  - id: verification
    content: 完成功能回归、索引命中检查与性能验证
    status: completed
isProject: false
---

# 生产级 GRDB 数据建模计划（按当前代码更新）

## 1) 当前目标与边界（已调整）

- 当前以**单聊优先**为主线，逐步向群聊模型兼容。
- 已不做历史 JSON 迁移；新数据以 GRDB 为唯一来源。
- 删除策略已从“建议软删”调整为**当前业务物理删除**（会话删除依赖 FK CASCADE）。

## 2) 当前实现快照（2026-04）

### 2.1 数据库层（已落地）

- 迁移框架：`VoiceIM/Core/Storage/Database/DatabaseManager.swift` + `Migrations.swift`
- 表结构（7 张核心表）已存在：
  - `users`
  - `conversations`
  - `conversation_members`
  - `messages`
  - `message_receipts`
  - `message_attachments`
  - `conversation_settings`
- 外键约束、唯一约束、核心索引已配置并启用（`PRAGMA foreign_keys = ON`）。

### 2.2 领域模型与 ID（已落地）

- `ChatMessage.id` 已从 UUID 改为 `String`。
- 使用 `MessageIDGenerator` 生成有序字符串 ID。
- `messages.client_msg_id` 已落库并唯一约束。

### 2.3 存储与查询能力（已落地并扩展）

- 存储主入口：`VoiceIM/Core/Storage/MessageStorage.swift`
- 会话维度接口已建立（协议位于 `StorageProtocols.swift`）：
  - 会话列表聚合查询
  - 标记已读
  - 置顶/取消置顶（`is_pinned`）
  - 不显示会话（`is_hidden`）
  - 会话删除（物理）
- 会话列表排序当前规则：
  1. 置顶优先
  2. 最近消息时间优先（无消息回退创建时间）
  3. 稳定兜底按会话 ID

### 2.4 业务与 UI（已落地并演进）

- `ConversationListViewController`、`ContactsViewController` 已切换为 `UICollectionView`。
- 会话列表支持侧滑操作：
  - 删除
  - 标记已读
  - 置顶/取消置顶
  - 不显示该会话
- 隐藏恢复逻辑：
  - 会话被“不显示”后从列表过滤
  - 发送或接收新消息时自动恢复显示

## 3) 与原计划的关键偏差（必须记录）

- 偏差 A：原计划强调软删；当前代码已采用**物理删除**。
- 偏差 B：原文引用了 `ConversationSummaryBuilder.swift`，当前工程已无该文件。
- 偏差 C：原计划“Store 完全拆分为独立类”尚未完成，当前仍以 `MessageStorage` 聚合实现为主。

## 4) 任务状态重评估（按真实代码）

### ✅ 已完成

- 生产级基础 DDL、约束、索引（首版）
- GRDB 迁移体系
- 文本有序 ID + 幂等键落库
- 会话列表能力：未读、置顶、隐藏、删除
- 回执读路径与关键写路径接入（已读/已播的主流程）

### 🟡 部分完成（仍需继续）

- 存储层拆分：接口已拆，类实现仍聚合在 `MessageStorage`
- Repository/ViewModel 与“群聊语义”对齐：当前仍以 `contactID` 单聊语义为主
- 安全加固：日志脱敏已做，SQLCipher/密钥轮换尚未落地
- 验证体系：有编译回归，缺系统化性能与索引命中报告

### ❌ 未完成

- Keychain 密钥轮换闭环
- `message_attachments` 的 `sha256` / `size_bytes` 生产级写入校验
- Delivered 回执体系完整化（`delivered_at_ms` 业务闭环）
- 群聊端到端能力（成员管理、消息路由、UI 展示）

## 5) 下一步建议（按优先级）

- P0：补齐安全闭环（SQLCipher + Keychain 密钥管理）
- P0：补齐“隐藏会话/置顶会话”相关测试（持久化、排序、恢复）
- P1：补齐附件完整性字段写入与校验流程
- P1：输出 `EXPLAIN QUERY PLAN` 与会话列表/分页压测报告
- P2：推进 `MessageStorage` 模块化拆分（`MessageStore`/`ConversationStore`/`ReceiptStore`）
- P2：按群聊语义改造 Repository 与 ViewModel

## 6) 验收口径（更新版）

- 功能：会话列表排序、置顶/隐藏恢复、已读/已播、删除行为一致且可复现
- 数据：外键无违规、幂等键不重复、会话设置状态与 UI 一致
- 性能：会话列表与聊天分页在目标设备达标并有量化结果
- 安全：数据库加密生效、密钥不落盘、日志可审计且脱敏

## 7) 可执行迭代清单（按工程落地）

### 迭代 A（P0）：安全闭环（SQLCipher + Keychain）

- **目标文件**
  - `VoiceIM/Core/Storage/Database/DatabaseManager.swift`
  - `VoiceIM/Core/Storage/Database/KeychainHelper.swift`
  - `project.yml`（如需切换 GRDB 变体）
- **实施动作**
  - 接入数据库 passphrase（启动时从 Keychain 读取）
  - 增加首次密钥生成、后续读取、异常回退策略
  - 切换到 SQLCipher 构建（本地 vendor：`Vendor/GRDB.swift`）
  - 增加 DEBUG 运行态自检（`PRAGMA cipher_version`）
  - 明确 DEBUG/RELEASE 的加密行为差异（Release 编译期强制 `SQLITE_HAS_CODEC`）
- **完成标准**
  - 数据库文件离线不可明文读取（SQLCipher 链路已接入）
  - 重启后可正常解锁和访问
- **验收命令**
  - `xcodebuild -project VoiceIM.xcodeproj -scheme VoiceIM -destination "generic/platform=iOS" -configuration Debug CODE_SIGNING_ALLOWED=NO build`

### 迭代 B（P0）：会话隐藏/置顶回归测试

- **目标文件**
  - `VoiceIM/Core/Storage/MessageStorage.swift`
  - `VoiceIM/Core/ViewModel/ConversationListViewModel.swift`
  - `VoiceIMTests/`（新增或补全相关测试）
- **实施动作**
  - [x] 补齐置顶/取消置顶排序断言
  - [x] 补齐隐藏后列表过滤 + 发送/接收新消息自动恢复断言
  - [x] 补齐“取消置顶回原位（除非新消息）”断言
- **完成标准**
  - [x] 上述 3 组用例可稳定通过
- **验收命令**
  - `xcodebuild test -project VoiceIM.xcodeproj -scheme VoiceIMTests -destination "platform=iOS Simulator,name=iPhone 17"`
  - 结果：`TEST SUCCEEDED`（56 tests / 7 suites）

### 迭代 C（P1）：附件完整性字段落地

- **目标文件**
  - `VoiceIM/Core/Storage/MessageStorage.swift`
  - `VoiceIM/Core/Storage/Database/Records/MessageAttachmentRecord.swift`
  - `VoiceIM/Utilities/CacheUtilities.swift`（必要时）
- **实施动作**
  - 写入 `sha256`、`size_bytes`
  - 下载/读取时做完整性校验
  - 校验失败时给出统一错误与回收策略
- **完成标准**
  - 新写入附件记录具备完整性字段
  - 篡改文件可被检测并触发回收
- **验收命令**
  - `xcodebuild -project VoiceIM.xcodeproj -scheme VoiceIM -destination "generic/platform=iOS" -configuration Debug CODE_SIGNING_ALLOWED=NO build`

### 迭代 D（P1）：查询性能与索引命中报告

- **目标文件**
  - `VoiceIM/Core/Storage/MessageStorage.swift`
  - `VoiceIM/Core/Storage/Database/Migrations.swift`
  - `README.md` 或计划文档附录（记录结果）
- **实施动作**
  - 对会话列表、聊天分页、未读查询执行 `EXPLAIN QUERY PLAN`
  - 校验是否命中预期索引
  - 必要时追加迁移索引
- **完成标准**
  - 核心查询无全表扫描
  - 输出可复现的性能记录
- **验收命令**
  - `xcodebuild -project VoiceIM.xcodeproj -scheme VoiceIM -destination "generic/platform=iOS" -configuration Debug CODE_SIGNING_ALLOWED=NO build`

### 迭代 E（P2）：存储层模块化拆分

- **目标文件**
  - `VoiceIM/Core/Storage/MessageStorage.swift`
  - `VoiceIM/Protocols/StorageProtocols.swift`
  - `VoiceIM/Core/DependencyInjection/AppDependencies.swift`
- **实施动作**
  - 将聚合实现拆分为 `MessageStore` / `ConversationStore` / `ReceiptStore`
  - 保持对 Repository 层接口兼容
- **完成标准**
  - 存储类职责清晰、可单测隔离
- **验收命令**
  - `xcodebuild -project VoiceIM.xcodeproj -scheme VoiceIM -destination "generic/platform=iOS" -configuration Debug CODE_SIGNING_ALLOWED=NO build`

### 迭代 F（P2）：群聊语义改造

- **目标文件**
  - `VoiceIM/Core/Repository/MessageRepository.swift`
  - `VoiceIM/Core/ViewModel/ChatViewModel.swift`
  - `VoiceIM/Models/`（必要时新增会话参与者模型）
- **实施动作**
  - 弱化 `contactID` 单聊假设，改为 `conversationID` 语义
  - 补齐群聊成员、回执、路由规则
- **完成标准**
  - 单聊与群聊在同一数据模型下可共存
- **验收命令**
  - `xcodebuild test -project VoiceIM.xcodeproj -scheme VoiceIMTests -destination "platform=iOS Simulator,name=iPhone 17"`

## 8) 执行节奏建议

- 每次只推进一个迭代，避免多主题混改。
- 每次迭代结束必须附：
  - 变更文件清单
  - 编译/测试结果
  - 风险与回滚点

