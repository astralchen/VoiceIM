# AGENTS.md

本文件为 Codex（Codex.ai/code）等智能体在本仓库内协作时的工程指引。更完整的架构与交互说明见 **`CLAUDE.md`**、**`README.md`**、**`REQUIREMENTS.md`**。

## 构建与运行

```bash
# 修改 project.yml 后必须重新生成 Xcode 工程
xcodegen generate

# 拉取 SPM 依赖（GRDB 等；亦可在 Xcode 中 File → Packages → Resolve）
xcodebuild -resolvePackageDependencies -project VoiceIM.xcodeproj -scheme VoiceIM

# 编译检查（不签名）
xcodebuild -project VoiceIM.xcodeproj \
  -scheme VoiceIM \
  -destination "generic/platform=iOS Simulator" \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build

# 单元测试（scheme 以 xcodebuild -list 为准，当前一般为 VoiceIM）
xcodebuild test \
  -project VoiceIM.xcodeproj \
  -scheme VoiceIM \
  -destination "platform=iOS Simulator,name=iPhone 17" \
  CODE_SIGNING_ALLOWED=NO

open VoiceIM.xcodeproj
```

- 仅改 Swift 源码时**不需要** `xcodegen generate`；改 **`project.yml`** 后必须生成。
- **GRDB** 通过 `project.yml` 的 `packages` 引入（远程 SPM）；若解析失败，检查网络与 Xcode Package 缓存。

## 技术栈

- **Swift 6.0**，严格并发（`ENABLE_STRICT_OBJC_MSGSEND: YES`）
- **UIKit**，无 SwiftUI
- **部署版本 iOS 15.0+**（与 `project.yml` 一致）
- **GRDB**（SQLite）：本地关系库 + 迁移；可选 SQLCipher 需自行定义 `SQLITE_HAS_CODEC` 并接对应变体
- **Swift Testing**：`VoiceIMTests` 中的 `@Suite` / `@Test`
- **AVFoundation / AVKit / PhotosUI**：录音、播放、相册与视频
- 列表：**UICollectionViewDiffableDataSource** + **UICollectionViewCompositionalLayout**（聊天、会话列表、通讯录等）

## 架构概览

业务代码在 **`VoiceIM/`** 下；**非「零依赖」**：通过 SPM 使用 **GRDB**。

### 数据流（持久化与聊天）

```
AppDependencies（@MainActor）
  ├─ any MessageStorageProtocol      → MessageStore（actor）
  ├─ any ConversationStorageProtocol → ConversationStore（actor）
  └─ any ReceiptStorageProtocol    → ReceiptStore（actor）
        ↓ 共用同一 DatabaseManager（GRDB DatabaseQueue）
MessageRepository / ConversationListViewModel
        ↓
VoiceChatViewController 等 ← ChatViewModel（MessageRepository）
        ↓
MessageDataSource（DiffableDataSource）+ ChatMessage
```

- 共享 SQL 与域映射集中在 **`GRDBStorageCore`**；各 Store 在单次 `read`/`write` 闭包内调用，保证事务边界。
- **`MessageStorage`** 为可选门面（聚合三 Store），测试或单入口转发时使用；生产路径多由 `AppDependencies` 直接注入协议。
- **`MessageRepository`**：消息 CRUD 走 `messageStorage`，`markConversationAsRead()` 走 **`receiptStorage`**，与会话列表侧协议解耦。

### 目录习惯（相对旧版「Managers」）

- **`Core/`**：`Storage/`（含 `Database/` 迁移与 Record）、`Repository/`、`ViewModel/`、`DependencyInjection/`、`Error/`、`Logging/`、`Media/`
- **`Services/`**：录音、播放、缓存、相册等
- **`Coordinators/`**：`InputCoordinator`、`MessageActionHandler`
- **`DataSources/`**：`MessageDataSource`
- **`ViewControllers/`、`Views/`、`Cells/`、`Models/`、`Protocols/`** 等

### 并发模型

- `VoiceRecordManager`、`VoicePlaybackManager`、主要 `UIViewController` / `ViewModel`：**`@MainActor`**
- **`VoiceCacheManager`**：`actor`，同 URL 合并下载任务
- **`MessageStore` / `ConversationStore` / `ReceiptStore`**：`actor`；与 `DatabaseManager` 搭配时由 **DatabaseQueue 串行化** SQL
- AVFoundation 回调多为 **`nonisolated`**，回 UI 用 `Task { @MainActor in ... }`

### ChatMessage 与列表刷新（替代旧 VoiceMessage 描述）

- **`ChatMessage`**：`Hashable` **仅基于 `id`**；`isPlayed`、`sendStatus` 等为可变状态。
- 更新路径：改 `messages` 数组中的项 → **`snapshot.reloadItems`** → cell provider 从数组取最新值 → `configure` 更新 UI（如语音红点淡出）。
- 已读/已播持久化：对方消息依赖 **`message_receipts`**（及成员未读字段）；加载时由存储层还原到 `ChatMessage`（详见 `GRDBStorageCore.toChatMessage`）。

### 录音状态机

`RecordState`：`.idle` → `.recording` → `.cancelReady` → `.idle`

- 长按 `UILongPressGestureRecognizer`（`allowableMovement = 2000`）
- `.began`：权限 + `AVAudioRecorder` + 约 1s 计时门槛
- `.changed`：上移 > 80pt → `.cancelReady`，下移恢复 `.recording`
- `.ended`：`.recording` 发送；`.cancelReady` 丢弃

### 播放互斥与 Seek 防抖

- `VoicePlaybackManager.play` 前先 `stopCurrent()`，通过 `onStop` 让旧 cell 复位。
- `VoiceMessageCell` 用 **`isSeeking`** 在拖拽期间屏蔽定时进度回调，避免 `UISlider` 与播放器互相抢 `value`。

## 需求与计划

- 功能级需求：**`REQUIREMENTS.md`**
- 数据建模与迭代记录：**`.cursor/plans/生产级grdb数据建模_4b37c81b.plan.md`**
