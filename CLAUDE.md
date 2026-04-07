# CLAUDE.md

本文件为 **Claude Code**（claude.ai/code）在本仓库协作时的工程指引。与 **Codex** 对照文档见 **`AGENTS.md`**；功能细则见 **`REQUIREMENTS.md`**，概览见 **`README.md`**。

## 构建与运行

```bash
# 修改 project.yml 后必须重新生成 Xcode 工程
xcodegen generate

# 解析 SPM 依赖（GRDB）
xcodebuild -resolvePackageDependencies -project VoiceIM.xcodeproj -scheme VoiceIM

# 编译（不签名）
xcodebuild -project VoiceIM.xcodeproj \
  -scheme VoiceIM \
  -destination "generic/platform=iOS Simulator" \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build

# 单元测试（scheme 以 `xcodebuild -list` 为准，当前一般为 VoiceIM）
xcodebuild test \
  -project VoiceIM.xcodeproj \
  -scheme VoiceIM \
  -destination "platform=iOS Simulator,name=iPhone 17" \
  CODE_SIGNING_ALLOWED=NO

open VoiceIM.xcodeproj
```

- 仅改 Swift 源文件时**不必**运行 `xcodegen generate`。
- **`project.yml`** 变更后必须 `xcodegen generate` 才会反映到 `.xcodeproj`。

## 技术栈

- **Swift 6.0**，严格并发（`ENABLE_STRICT_OBJC_MSGSEND: YES`）
- **UIKit**，无 SwiftUI
- **iOS 15.0+**
- **Swift Testing**（`VoiceIMTests`）
- **GRDB**（SPM，见 `project.yml`）：本地 SQLite 关系库 + 迁移
- **AVFoundation / AVKit / PhotosUI**：录音、播放、相册与视频
- 列表：**UICollectionViewDiffableDataSource** + **UICollectionViewCompositionalLayout**

## 架构概览（MVVM + Repository + GRDB）

```
VoiceIM/
├── App/                           # 入口、AppCompositionRoot
├── Core/
│   ├── Error/                     # ChatError、ErrorHandler
│   ├── Logging/                   # Logger
│   ├── Storage/
│   │   ├── Database/              # DatabaseManager、Migrations、Records、KeychainHelper
│   │   ├── GRDBStorageCore.swift  # 共享 SQL 与 ChatMessage 映射
│   │   ├── MessageStore.swift、ConversationStore.swift、ReceiptStore.swift
│   │   ├── MessageStorage.swift   # 可选门面（聚合三 Store）
│   │   ├── MessageStorage+Protocols.swift
│   │   └── FileStorageManager.swift
│   ├── Repository/                # MessageRepository
│   ├── ViewModel/                 # ChatViewModel、ConversationListViewModel
│   ├── DependencyInjection/       # AppDependencies
│   └── Media/                     # MediaPlaybackCoordinator 等
├── Models/
├── ViewControllers/               # 聊天、会话列表、通讯录等
├── DataSources/                   # MessageDataSource
├── Coordinators/                # InputCoordinator、MessageActionHandler
├── Services/                    # 录音、播放、缓存、相册、键盘等
├── Views/、Cells/、Protocols/、Utilities/、Transitions/
└── Info.plist

VoiceIMTests/                      # Swift Testing：存储、Repository、QueryPlan 等
```

### 架构原则

1. **依赖注入**：`AppDependencies`（`@MainActor`）构造并持有服务；存储层对外多为 **`any MessageStorageProtocol` / `ConversationStorageProtocol` / `ReceiptStorageProtocol`**，便于测试替换。
2. **协议抽象**：音频等在 **`Protocols/AudioServices.swift`**；存储在 **`Protocols/StorageProtocols.swift`**。
3. **单一数据源（聊天页）**：`ChatViewModel` 用 `@Published` 等管理状态；`VoiceChatViewController` 持有 `ChatViewModel`。
4. **错误与日志**：业务错误归 **`ChatError`**，经 **`ErrorHandler`** 展示；日志用 **`VoiceIM.logger`**（或注入的 `Logger`）。

### 数据流（当前）

```
用户操作
   ↓
ViewController → ChatViewModel（@Published）
                      ↓
                MessageRepository（消息 + 文件 + 缓存）
                      ↓
        ┌─────────────┼─────────────┐
        ↓             ↓             ↓
 any MessageStorageProtocol   any ReceiptStorageProtocol   FileStorageProtocol
   (MessageStore)              (ReceiptStore)         (FileStorageManager)
        ↓             ↓
   DatabaseManager（GRDB DatabaseQueue）
        ↓
   SQLite 文件（Documents/VoiceIM/…）
```

- **`MessageRepository`**：`load/append/update/delete` 等走 **`messageStorage`**；**`markConversationAsRead()`** 走 **`receiptStorage`**，与会话列表使用的 **`conversationStorage`** 解耦（SQL 仍由 **`GRDBStorageCore`** 统一）。
- **`GRDBStorageCore`**：禁止在多个 Store 里复制大段 SQL；每个 Store 方法内通常 **一次** `read`/`write`，闭包内多步语句同一事务。
- **`MessageStorage`**：可选门面，测试或单入口转发时用；生产路径多为 `AppDependencies` 直接注入三个协议。
- **加密**：`SQLITE_HAS_CODEC` 分支与 Keychain 口令已预留；**默认 SPM GRDB 多为明文 SQLite**，是否加密取决于工程宏与链接的 GRDB 变体（见 `DatabaseManager` 注释）。

### 聊天页职责拆分（VoiceChatViewController）

主控制器协调：

- **MessageDataSource**：DiffableDataSource 与 snapshot
- **MessageActionHandler**：删除、撤回、重试、上下文菜单
- **InputCoordinator**：录音状态机、扩展菜单、文字/语音/图片/视频/位置等发送入口
- **KeyboardManager**：键盘与滚动

## 并发模型

- `VoiceRecordManager`、`VoicePlaybackManager`、主要 VC / ViewModel：**`@MainActor`**
- **`VoiceCacheManager`**：`actor`，同 URL 合并下载
- **`MessageStore` / `ConversationStore` / `ReceiptStore`**：`actor`；与共享 **`DatabaseManager`** 配合时，由 **GRDB DatabaseQueue** 串行化访问
- AVFoundation 委托方法常标 **`nonisolated`**，回主线程用 **`Task { @MainActor in … }`**

## 可变状态更新（Diffable 与 ChatMessage）

`ChatMessage.Hashable` **仅基于 `id`**。`isPlayed`、`sendStatus` 等变化路径：

1. 更新内存中 **`messages`** 数组对应项  
2. **`snapshot.reloadItems([…])`** → cell provider 再次执行  
3. provider 从 **`messages`** 取**最新**状态（snapshot 项 identity 不变）  
4. **`configure(…)`** 更新 UI（如语音红点淡出、发送状态图标）

**须维护独立 `messages` 数组作为可变状态源。** iOS 15+ 可考虑 `reconfigureItems`（见 `ChatMessage.swift` 注释）。

**持久化**：对方消息已读/已播与「进会话全部已读」写入 **`message_receipts`** 等表；加载时由 **`GRDBStorageCore.toChatMessage`** 还原到 `isRead` / `isPlayed`。

## 消息类型扩展

通过 **`MessageCellConfigurable`** 扩展新类型：

1. `ChatMessage.Kind` 增加 case  
2. `Kind.reuseID` 增加映射  
3. 新建 Cell 实现协议  
4. `VoiceChatViewController.setupCollectionView()` 注册  
5. cell provider 内 `configure(with:deps:)`

## 上下文菜单（UIContextMenuInteraction）

- **ChatBubbleCell**：`UIContextMenuInteraction` 挂在 `bubble`；`contextMenuProvider: ((ChatMessage) -> UIMenu?)`  
- **VoiceChatViewController**：设置 provider，委托 **`MessageActionHandler.buildContextMenu(for:)`**  
- **文本**：复制、撤回（条件）、删除；**链接/电话/银行卡** 高亮与点击见 `TextMessageCell` / `MessageCellDependencies.onLinkTapped`

## 录音状态机

`RecordState`：`.idle` → `.recording` → `.cancelReady` → `.idle`

- `UILongPressGestureRecognizer`，`allowableMovement = 2000`  
- `.began`：权限 + `AVAudioRecorder` + ~1s 门槛  
- `.changed`：上移 > 80pt → `.cancelReady`  
- `.ended`：发送或丢弃

## 播放互斥与 Seek 防抖

- `VoicePlaybackManager.play` 前 **`stopCurrent()`**，`onStop` 复位旧 cell  
- **`VoiceMessageCell.isSeeking`**：拖拽时屏蔽定时进度，避免 `UISlider` 抖动

## 波形视图（WaveformProgressView）

分段宽度：短时长线性增长，长时长对数增长；`waveformView` **布局优先级 .required**，`barCount` 随宽度重算；细节见 **`WaveformProgressView-API.md`**。

## 输入栏模式切换（ChatInputView）

文字模式与语音模式两套约束切换；切换时先停用再激活，避免冲突。

## 消息发送状态

`SendStatus`：`.sending` → `.delivered` / `.failed` → …；仅 **`isOutgoing`** 显示指示器。开发中可用模拟成功率逻辑（以 **`ChatViewModel`** 实际实现为准），生产接真实网络。

## 消息撤回

条件：己方、`.delivered`、3 分钟内。撤回后 **`Kind.recalled`**，删本地媒体文件，列表用 snapshot 替换 cell；文本可点提示重新编辑。

## 音频自动停止场景

录音开始、删正在播的消息、互斥切换、页面消失、进后台、`AVAudioSession` 打断等须停止播放（见 `VoiceChatViewController` 与播放管理器）。

## 需求与计划

- **`REQUIREMENTS.md`**：功能与数据需求全文  
- **`.cursor/plans/生产级grdb数据建模_4b37c81b.plan.md`**：GRDB 与迭代进度  
