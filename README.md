# VoiceIM

iOS 即时通讯示例应用：语音、文字、图片、视频、位置消息；录制、发送、播放、进度与未读；消息状态与撤回。**消息与会话数据持久化在本地 GRDB（SQLite）**，支持会话列表、置顶/隐藏、标记已读等。

## 功能特性

### 语音消息
- 长按「按住说话」录音，实时显示秒数
- 上滑取消、松手发送（不足 1 秒提示过短）；最长 30s，到上限自动发送
- 点击播放/停止，同时只播放一条；进度条拖拽与剩余时长
- 本地与远程语音（缓存下载，相同 URL 不重复拉取）
- 未读语音红点，首次播放后淡出

### 文字消息
- 多行输入、高度自适应（最多约 5 行）；回车发送
- 文字/语音模式切换

### 图片与视频
- 「+」打开系统相册；固定尺寸图片气泡、视频缩略图与时长
- 图片全屏预览（双指缩放）、视频全屏播放

### 消息状态与撤回
- 发送中 / 已送达 / 已读 / 失败（失败可重试）
- 撤回：己方、已送达、3 分钟内；文本可点撤回提示重新编辑

### 消息列表与会话
- 聊天页：`UICollectionView` + DiffableDataSource，时间分隔、下拉历史
- **会话列表**与**通讯录**：`UICollectionView`；侧滑删除、标记已读、置顶、不显示会话
- 隐藏会话在**有新消息**时自动恢复列表展示

### 数据与存储（GRDB）
- 本地关系库：`users`、`conversations`、`conversation_members`、`messages`、`message_receipts`、`message_attachments`、`conversation_settings`
- 外键与迁移：`DatabaseManager` + `Migrations.swift`；DEBUG 下可按 schema 变更擦除重建（勿用于生产数据）
- 存储分层：`MessageStore` / `ConversationStore` / `ReceiptStore` + 共享逻辑 `GRDBStorageCore`；可选门面 `MessageStorage`（测试或单入口转发）
- `AppDependencies` 注入 `any MessageStorageProtocol` 等；`MessageRepository`、`ConversationListViewModel` 依赖协议，便于替换与单测
- 附件写入 `sha256` / `size_bytes`，读路径校验失败时回收损坏本地文件

## 环境要求

- **Xcode 16+**（与 `project.yml` 中 `xcodeVersion` 一致为佳）
- **iOS 15.0+**
- **Swift 6.0**
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)**：修改 `project.yml` 后用于重新生成 `.xcodeproj`

## 依赖（Swift Package Manager）

- **GRDB**：在 `project.yml` 中配置为远程包 `https://github.com/groue/GRDB.swift`（版本见 `from` 字段）。
- 首次打开或拉代码后，在 Xcode 中执行 **File → Packages → Resolve Package Versions**。
- **数据库加密**：若需 SQLCipher，需按 GRDB 官方文档接入带 `SQLITE_HAS_CODEC` 的构建，并在 `project.yml` 的 `SWIFT_ACTIVE_COMPILATION_CONDITIONS` 中定义该宏；默认 SPM 多为系统 SQLite（明文库文件）。

## 运行

```bash
# 安装 XcodeGen（仅首次）
brew install xcodegen

# 根据 project.yml 生成 Xcode 工程（改 yml 后必须执行）
xcodegen generate

# 打开工程
open VoiceIM.xcodeproj
```

在 Xcode 中选择 **Scheme：`VoiceIM`**，模拟器或真机 Run。真机在 **Signing & Capabilities** 中配置 Team。

### 命令行编译（不签名）

```bash
xcodebuild -project VoiceIM.xcodeproj \
  -scheme VoiceIM \
  -destination "generic/platform=iOS Simulator" \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

### 运行单元测试

```bash
xcodebuild test \
  -project VoiceIM.xcodeproj \
  -scheme VoiceIM \
  -destination "platform=iOS Simulator,name=iPhone 15" \
  CODE_SIGNING_ALLOWED=NO
```

（模拟器名称请按本机 `xcrun simctl list` 调整。）

## 技术栈

| 项目 | 说明 |
|------|------|
| Swift 6.0 | 严格并发；存储层使用 `actor` |
| UIKit | 无 SwiftUI；Launch Screen 除外 |
| GRDB | SQLite 访问、迁移、类型安全查询 |
| AVFoundation / AVKit / PhotosUI | 录音、播放、相册 |
| UICollectionViewDiffableDataSource + CompositionalLayout | 消息列表、会话列表等 |
| MVVM + Repository | `ChatViewModel`、`ConversationListViewModel`、`MessageRepository` |
| 依赖注入 | `AppDependencies` 统一装配 |

## 项目结构（摘要）

```
VoiceIM/
├── project.yml                 # XcodeGen：目标、SPM、编译参数、Scheme
├── VoiceIM.xcodeproj           # 由 xcodegen 生成，勿手改结构
├── README.md / REQUIREMENTS.md / CLAUDE.md / AGENTS.md
└── VoiceIM/
    ├── App/                    # 入口、Composition Root
    ├── Models/                 # ChatMessage、Contact、ConversationSummary …
    ├── Core/
    │   ├── Storage/            # MessageStore、ConversationStore、ReceiptStore、
    │   │                       # GRDBStorageCore、MessageStorage、FileStorageManager
    │   │   └── Database/       # DatabaseManager、Migrations、Records、KeychainHelper
    │   ├── Repository/         # MessageRepository
    │   ├── ViewModel/          # ChatViewModel、ConversationListViewModel
    │   ├── DependencyInjection/# AppDependencies
    │   ├── Error / Logging / Media
    ├── ViewControllers/        # 会话列表、通讯录、聊天页等
    ├── DataSources/            # MessageDataSource
    ├── Coordinators/           # InputCoordinator、MessageActionHandler
    ├── Services/               # 录音、播放、缓存、相册、键盘等
    ├── Cells / Views / Protocols / Utilities / Transitions
    └── Info.plist
└── VoiceIMTests/               # Swift Testing：存储、QueryPlan、Repository 等
```

## 关键设计

- **聊天页瘦身**：`VoiceChatViewController` 协调 `MessageDataSource`、`MessageActionHandler`、`InputCoordinator`、`KeyboardManager` 等。
- **可变消息状态**：`ChatMessage` 的 `Hashable` 仅基于 `id`；`isPlayed`、`sendStatus` 等通过数据源 `reloadItems` 驱动 Cell 刷新。
- **播放互斥**：`VoicePlaybackManager` 播放新消息前停止当前播放。
- **语音缓存**：`VoiceCacheManager`（`actor`）合并同 URL 下载任务。
- **存储事务**：各 Store 在单次 `DatabaseManager.read/write` 内调用 `GRDBStorageCore`，保证多表更新原子性。

## 开发说明

- 修改 **`project.yml`** 后务必执行 **`xcodegen generate`**。
- 详细需求见 **`REQUIREMENTS.md`**；AI/工具辅助开发见 **`CLAUDE.md`**、**`AGENTS.md`**。
- 数据建模与迭代计划见 **`.cursor/plans/生产级grdb数据建模_4b37c81b.plan.md`**（路径以仓库为准）。
