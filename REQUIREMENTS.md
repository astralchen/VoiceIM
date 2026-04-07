# IM 语音消息功能需求文档

> 整理自开发会话，持续更新。  
> **2026-04 起**：已接入本地 **GRDB** 持久化、会话列表与多模块目录结构；下文「文件结构」与「数据层」以当前仓库为准。

---

## 一、录制

### 1.1 基本交互

| 操作 | 触发条件 | 行为 |
|------|----------|------|
| 开始录音 | 长按"按住说话"（≥ 0.3s） | 显示录音浮层，计时器从 0 开始计秒 |
| 正常发送 | 松手，录音时长 ≥ 1s | 语音发送，追加到消息列表，恢复"按住说话" |
| 时间过短 | 松手，录音时长 < 1s | 删除录音文件，Toast 提示"说话时间太短"，恢复"按住说话" |
| 预备取消 | 录音中手指上滑 > 80pt | 浮层变为取消样式，按钮显示"松开 取消"，计时继续 |
| 取消发送 | 处于预备取消状态时松手 | 丢弃录音文件，恢复"按住说话" |
| 恢复录音 | 处于预备取消状态时手指下滑回阈值内 | 浮层恢复正常样式，按钮显示"松开 发送" |
| 自动发送 | 录音达到 30s | 自动停止并发送，恢复"按住说话" |

### 1.2 约束

- 同一时刻只允许进行一次录音，不可并发。
- 最长录制时长：**30 秒**。
- 最短有效时长：**1 秒**。

### 1.3 录音浮层状态

| 状态 | 图标 | 背景色 | 提示文字 |
|------|------|--------|----------|
| 正常录音 | 麦克风 | 深色半透明 | 上滑取消 |
| 预备取消 | ✕ 圆圈（红色） | 深红色半透明 | 松手取消 |

---

## 二、消息列表

### 2.1 消息类型

| 类型 | 数据字段 | Cell 类 |
|------|----------|---------|
| 语音消息 | `ChatMessage.Kind.voice(localURL:remoteURL:duration:)` | `VoiceMessageCell` |
| 文本消息 | `ChatMessage.Kind.text(String)` | `TextMessageCell` |
| 图片消息 | `ChatMessage.Kind.image(localURL:remoteURL:)` | `ImageMessageCell` |
| 视频消息 | `ChatMessage.Kind.video(localURL:remoteURL:duration:)` | `VideoMessageCell` |
| 位置消息 | `ChatMessage.Kind.location(latitude:longitude:address:)` | `LocationMessageCell` |
| 撤回消息 | `ChatMessage.Kind.recalled(originalText:)` | `RecalledMessageCell` |

### 2.2 发送者与方向

- 每条消息携带 `sender: Sender`（含 `id`、`displayName`）和 `sentAt: Date`。
- `isOutgoing = sender.id == "me"`，决定气泡靠右（自己）还是靠左（对方）。
- 头像为 36×36 圆形占位：背景色由 `sender.id` UTF-8 字节求和映射到固定调色板，中心显示 `displayName` 首字母。同一发送者颜色跨 session 保持一致。

### 2.3 消息发送状态

每条消息携带 `sendStatus: SendStatus` 字段，仅自己发送的消息（`isOutgoing = true`）显示状态指示器。

| 状态 | 枚举值 | UI 展示 | 说明 |
|------|--------|---------|------|
| 发送中 | `.sending` | 旋转的加载指示器（UIActivityIndicatorView） | 消息正在发送到服务器 |
| 已送达 | `.delivered` | 单勾（暂未实现 UI） | 消息已送达服务器 |
| 已读 | `.read` | 双勾（暂未实现 UI） | 对方已读消息 |
| 发送失败 | `.failed` | 红色感叹号图标（可点击重试） | 消息发送失败，点击重试 |

#### 状态指示器位置
- 位于气泡左侧（发送方消息靠右，状态指示器在气泡与头像之间）
- 垂直居中对齐气泡
- 尺寸：加载指示器 20×20pt，失败图标 24×24pt

#### 重试逻辑
- 点击失败图标触发重试
- 删除失败的消息（带删除动画）
- 根据消息类型重新创建并发送：
  - 语音消息：使用原 `localURL` 重新发送（若文件丢失则提示用户）
  - 文本消息：使用原文本内容重新发送
  - 图片消息：使用原 `localURL` 重新发送（若文件丢失则提示用户）
  - 视频消息：使用原 `localURL` 重新发送（若文件丢失则提示用户）
- 新消息追加到列表底部，状态为 `.sending`

#### 模拟发送（开发阶段）
- 延迟 1-2 秒模拟网络请求
- 70% 成功率（`.delivered`），30% 失败率（`.failed`）
- 生产环境替换为真实网络请求

### 2.4 时间分隔行

- 规则：与上一条消息的 `sentAt` 间隔 **> 5 分钟**时，在该消息上方显示时间分隔行。
- 第一条消息始终显示时间分隔行。
- 时间格式：
  - 今天：`HH:mm`
  - 昨天：`昨天 HH:mm`
  - 更早：`M月d日 HH:mm`
- 不显示时高度折叠为 0，不留白（`isHidden` + `heightConstraint = 0` 双重保证）。

### 2.5 气泡布局

| 方向 | 头像位置 | 气泡位置 | 气泡背景色 |
|------|----------|----------|------------|
| 自己（靠右） | cell 右侧 8pt | 头像左侧 8pt | `systemBlue × 0.15` |
| 对方（靠左） | cell 左侧 8pt | 头像右侧 8pt | `systemGray5` |

- 气泡最大宽度：contentView 宽度的 **65%**（为头像 36pt + 两侧边距共 52pt 留空间）。
- 方向切换通过激活/停用两套预构建约束实现，cell 复用时先停用全部再激活目标套，避免约束冲突。

### 2.6 滚动策略

- 用户**在底部附近**（距底部 < 60pt）时发送消息：自动滚动到最新消息。
- 用户**正在浏览历史消息**时发送消息：不滚动，保持当前位置。
- 判断公式：`contentSize.height - contentOffset.y - bounds.height + adjustedContentInset.bottom < 60`

### 2.7 下拉加载历史记录

- 在列表顶部下拉触发 `UIRefreshControl`，加载更早的历史消息。
- 历史消息插入列表头部，**不打断用户当前阅读位置**（`layoutIfNeeded()` 后补偿 `contentOffset.y`）。
- 防重：加载期间再次下拉立即结束刷新，不重复发起请求（`isLoadingHistory` 标志）。
- 加载完所有页后显示 Toast"没有更多历史消息"，不再触发请求。

### 2.8 会话列表与通讯录（2026-04）

**会话列表页**（`ConversationListViewController` + `ConversationListViewModel`）：

- 使用 `UICollectionView` 展示会话；数据来自 **一次聚合查询**（未读、置顶、最后一条预览与时间），避免对每条会话再查库（实现见 `ConversationStore.loadConversationSummaries`）。
- 与本地通讯录占位合并：无会话的联系人仍显示空会话行（按名称排序在列表底部）。
- **侧滑操作**：删除会话（物理删除，外键级联）、标记已读、置顶/取消置顶、不显示该会话。
- **隐藏会话**：`conversation_settings.is_hidden = 1` 时不出现在列表；该会话 **发送或接收任意新消息** 时自动 `is_hidden = 0` 恢复显示（实现见 `MessageStore.append`）。
- **排序规则**：置顶优先 → 最近消息时间（无消息则回退会话创建时间）→ 会话 ID 稳定排序。

**通讯录页**（`ContactsViewController`）：`UICollectionView` 展示联系人，进入聊天沿用单聊会话 ID（当前与 `contact.id` 一致）。

**依赖注入**：`ConversationListViewModel` 依赖 `any MessageStorageProtocol`（DEBUG 种子数据）与 `any ConversationStorageProtocol`（列表与设置）；由 `AppDependencies.makeConversationListViewModel()` 统一注入。

---

## 三、播放

### 3.1 基本交互

- 点击语音消息气泡上的播放按钮开始播放。
- 再次点击同一条正在播放的消息：停止播放。
- 同一时刻只允许播放一条语音，播放新消息时自动停止当前播放。
- **录音期间禁止播放**：处于录音中或预备取消状态时，点击播放按钮无效。
- **开始录音时停止播放**：若当前有语音正在播放，录音启动前自动停止播放。

### 3.2 进度显示

- 播放中显示可拖拽的进度滑块（`UISlider`，`minimumValue = 0`，`maximumValue = 1`）。
- 播放完成或停止后隐藏进度滑块。
- 时长标签在播放中实时显示**剩余时长**，停止后恢复显示**总时长**。
- 计算公式：`remaining = duration × (1 - progress)`

### 3.3 拖拽跳转（Seek）

- 用户拖动进度滑块时，时长标签实时更新剩余时长。
- 手指抬起后跳转到对应播放位置（`AVAudioPlayer.currentTime = progress × duration`）。
- 拖拽期间屏蔽来自播放器的进度推送，避免滑块抖动。

### 3.4 本地与远程语音

| 类型 | 来源 | 处理方式 |
|------|------|----------|
| 本地录制 | `ChatMessage.localURL` | 直接播放 |
| 远程服务器 | `ChatMessage.remoteURL` | 下载后缓存，再播放 |

### 3.5 下载缓存

- 缓存目录：`Library/Caches/IMVoiceCache/`
- 缓存文件命名：`abs(remoteURL.absoluteString.hashValue).<ext>`
- 同一 URL 同时发起多次下载请求时，复用同一个 `Task`，避免重复下载。
- 缓存命中时直接返回本地路径，不发起网络请求。

---

## 四、图片和视频消息

### 4.1 扩展功能按钮

- 输入栏左侧显示扩展功能按钮（蓝色 `plus.circle.fill` 图标，32×32pt）
- 点击弹出功能菜单（`UIAlertController`，`.actionSheet` 样式）
- 菜单选项：
  - **相册**：打开系统相册选择器
  - **拍照**：已接入口（能力随系统权限与实现演进）
  - **位置**：当前为**演示用随机坐标**（`InputCoordinator.sendRandomLocation`）；生产应接 CoreLocation 与用户授权
  - **取消**

### 4.2 相册选择

- 使用 `PHPickerViewController`（iOS 14+）
- 支持选择图片和视频（`.any(of: [.images, .videos])`）
- 单选模式（`selectionLimit = 1`）
- 选择后自动复制到临时目录
- 视频自动提取时长（`AVAsset.duration`）

### 4.3 图片消息

**数据结构**：
- `ChatMessage.Kind.image(localURL:remoteURL:)`
- 工厂方法：`image(localURL:)`, `remoteImage(id:remoteURL:sender:sentAt:)`

**UI 展示**（`ImageMessageCell`）：
- 固定尺寸：200×200pt
- 内容模式：`scaleAspectFill`
- 加载指示器：居中显示
- 点击图片：打开全屏预览

**图片预览**（`ImagePreviewViewController`）：
- 全屏黑色背景
- 支持双指缩放（1.0x - 3.0x）
- 双击缩放功能
- 关闭按钮：右上角，白色 `xmark.circle.fill` 图标

### 4.4 视频消息

**数据结构**：
- `ChatMessage.Kind.video(localURL:remoteURL:duration:)`
- 工厂方法：`video(localURL:duration:)`, `remoteVideo(id:remoteURL:duration:sender:sentAt:)`

**UI 展示**（`VideoMessageCell`）：
- 固定尺寸：200×200pt
- 视频缩略图：第一帧（`AVAssetImageGenerator`）
- 播放按钮：居中，白色半透明背景，50×50pt
- 时长标签：右下角，黑色半透明背景，格式 `M:SS`
- 点击视频：打开全屏播放

**视频预览**（`VideoPreviewViewController`）：
- 使用 `AVPlayerViewController` 全屏播放
- 系统原生播放控制器
- 打开后自动播放（`viewDidAppear` 中调用 `player?.play()`）
- 页面消失时自动暂停
- 关闭按钮：右上角，白色 `xmark.circle.fill` 图标

---

## 五、文本消息复制

### 5.1 长按上下文菜单

- 长按文本消息触发 `UIContextMenuInteraction`（iOS 13+）
- 显示上下文菜单，包含：复制、撤回（条件显示）、删除
- 点击"复制"将全部文本复制到剪贴板
- 使用系统原生的上下文菜单交互体验

### 5.2 文本内容检测与高亮

**支持的检测类型**：
- **URL 链接**：自动检测 http/https 链接
- **电话号码**：自动检测电话号码格式
- **银行卡号**：检测 16-19 位银行卡号（支持空格或横线分隔）

**高亮样式**：
- 蓝色文字 + 下划线
- 使用 `NSDataDetector` 检测 URL 和电话号
- 使用正则表达式检测银行卡号

**点击行为**：
- **URL**：在 Safari 中打开
- **电话号**：调起系统拨号界面
- **银行卡号**：弹出 Alert 显示格式化卡号，提供复制功能

**实现细节**：
- 使用 `NSAttributedString` 实现高亮显示
- 通过 `NSLayoutManager` 精确计算点击位置
- 点击事件通过 `MessageCellDependencies.onLinkTapped` 回调传递给外部处理
- 银行卡号使用自定义 `bankcard:` scheme 标识

### 5.3 实现细节

**统一交互模式**：
- 所有消息类型（语音/文本/图片/视频）统一使用 `UIContextMenuInteraction`
- 通过 `contextMenuProvider: ((ChatMessage) -> UIMenu?)` 回调外部控制菜单内容
- `MessageActionHandler.buildContextMenu(for:)` 集中构建菜单逻辑

**菜单项构建**：
- **文本消息**：复制 + 撤回（条件显示）+ 删除
- **其他消息**：撤回（条件显示）+ 删除
- 撤回条件：自己发送 + 已送达 + 3 分钟内

**架构设计**：
- Cell 不决定菜单内容，通过回调将控制权交给外部
- ViewController 设置 `contextMenuProvider`，委托给 `MessageActionHandler`
- 职责分离：Cell 负责显示，Handler 负责业务逻辑

---

## 六、未读提醒

- 每条语音消息默认为**未读状态**，在气泡播放按钮右上角显示红色圆点（直径 10pt）。
- 用户首次点击播放时，红点以 **0.2s 淡出动画**消失；内存模型上更新 `isPlayed` / `isRead`，并由 `MessageRepository` 写回存储。
- **持久化**：对方语音的已播/已读与「进入会话全部已读」写入 **`message_receipts`**（及 `conversation_members.unread_count`）；加载消息时由 `GRDBStorageCore.toChatMessage` 根据当前用户回执行还原 `isPlayed` / `isRead`。
- cell 复用时根据 `isPlayed` 状态直接显隐红点（不触发动画），仅在状态从未读变已读时才播放淡出动画。

---

## 七、消息撤回与删除

### 7.1 消息撤回

**撤回条件**（同时满足）：
- 自己发送的消息（`isOutgoing = true`）
- 发送状态为 `.delivered`（已送达）
- 发送时间在 3 分钟以内

**撤回流程**：
1. 长按消息气泡弹出操作菜单
2. 选择"撤回"选项
3. 原消息替换为 `RecalledMessageCell`
4. 删除原消息的本地文件（语音/图片/视频）

**撤回后展示**：
- **文本消息撤回**：显示"你撤回了一条消息"，点击可重新编辑发送
- **其他类型撤回**：仅显示"你撤回了一条消息"，不可重新编辑
- 保留原消息的时间戳和发送者信息
- 撤回消息不显示时间分隔行

### 7.2 消息删除

- 长按消息气泡（≥ 0.5s）弹出操作菜单（`UIAlertController`，`.actionSheet` 样式）
- 菜单包含：**撤回**（符合条件时显示）、**删除**（destructive 样式）、**取消**
- 确认删除后执行以下步骤：
  1. 若该消息正在播放，先停止播放，避免播放器持有悬空 URL
  2. 从 `messages` 数组中移除该条消息
  3. 若存在本地临时文件（`localURL`），同步删除磁盘文件
  4. `snapshot.deleteItems` + `apply(animatingDifferences: true)` 从列表移除 cell

---

## 八、技术约束

| 项目 | 要求 |
|------|------|
| 语言 | Swift 6.0，启用严格并发检查 |
| UI 框架 | UIKit（无 SwiftUI） |
| 最低系统 | iOS 15.0+ |
| 音频框架 | AVFoundation（`AVAudioRecorder` 录音，`AVAudioPlayer` 播放） |
| 相册选择 | PhotosUI（`PHPickerViewController`，iOS 14+） |
| 视频播放 | AVKit（`AVPlayerViewController`） |
| 列表组件 | `UICollectionView` + `UICollectionViewDiffableDataSource` + `UICollectionViewCompositionalLayout` |
| 并发模型 | `async/await`，UI 操作统一在 `@MainActor`，下载缓存与 GRDB 存储使用 `actor` |
| 本地数据库 | **GRDB**（SQLite），迁移见 `Migrations.swift`；依赖由 **Swift Package Manager** 引入（`project.yml`） |

---

## 九、本地数据持久化（GRDB）

### 9.1 目标与范围

- 聊天消息、会话、成员、回执、附件元数据、每用户会话设置等均落库；**不做**历史 JSON 文件迁移，以 GRDB 为唯一本地来源。
- 删除策略为**物理删除**（含会话删除时的外键级联，见迁移 DDL）。

### 9.2 核心表（摘要）

| 表 | 用途 |
|----|------|
| `users` | 用户展示名等 |
| `conversations` | 会话主表 + `last_message_*` 冗余字段供列表排序 |
| `conversation_members` | 成员、**未读数**、已读水位 `last_read_message_seq` |
| `messages` | 消息主行（含 `client_msg_id` 幂等） |
| `message_receipts` | 每用户对消息的已读/已播时间 |
| `message_attachments` | 媒体路径、远程 URL、**sha256**、**size_bytes** 等 |
| `conversation_settings` | 置顶、隐藏等 **每用户每会话** 设置 |

### 9.3 存储分层与协议

- **`GRDBStorageCore`**：共享 SQL 与 `ChatMessage` ↔ 表映射；由各 Store 在**单次** `DatabaseManager.read/write` 事务内调用，避免重复实现。
- **`MessageStore`**（`MessageStorageProtocol`）：会话内消息增删改查、懒建会话、刷新 `last_message_*`、新消息恢复隐藏会话、对方消息未读 +1。
- **`ConversationStore`**（`ConversationStorageProtocol`）：会话列表聚合、置顶/隐藏、物理删会话等。
- **`ReceiptStore`**（`ReceiptStorageProtocol`）：与聊天页「整会话已读」对齐；与 `ConversationStore` 中同名能力 **共用** `GRDBStorageCore` SQL。
- **`MessageStorage`**：可选**门面**，聚合上述三个 actor，共享同一 `DatabaseManager`；测试或单入口转发时使用。
- **`MessageRepository`**：业务层；消息走 `messageStorage`，`markConversationAsRead()` 走 **`receiptStorage`**，便于与会话列表依赖解耦。
- **`AppDependencies`**：构造三个 Store 实例（同一 DB），对外暴露 `any *Protocol` 供 ViewModel / 测试替换。

### 9.4 附件完整性

- 写入媒体附件时，若本地文件可读，计算 **SHA256** 与 **size** 写入 `message_attachments`。
- 读取时校验；**不匹配则删除本地坏文件**并降级为仅远程 URL（见 `GRDBStorageCore.validatedLocalURL`）。

### 9.5 加密（SQLCipher）说明

- 代码中预留 `SQLITE_HAS_CODEC` 分支（Keychain 口令、`usePassphrase` 等）。**默认 SPM 官方 GRDB 多为系统 SQLite**，是否加密取决于工程是否定义该宏并链接 SQLCipher 变体；以 `README.md` 与 `DatabaseManager` 注释为准。

---

## 十、文件与模块结构

```
VoiceIM/
├── App/
│   ├── AppDelegate.swift
│   ├── SceneDelegate.swift
│   └── AppCompositionRoot.swift
├── Models/
│   ├── ChatMessage.swift
│   ├── Sender.swift
│   ├── Contact.swift
│   ├── ConversationSummary.swift
│   └── MessageIDGenerator.swift
├── Core/
│   ├── Storage/
│   │   ├── Database/              # DatabaseManager、Migrations、Records、KeychainHelper
│   │   ├── GRDBStorageCore.swift
│   │   ├── MessageStore.swift、ConversationStore.swift、ReceiptStore.swift
│   │   ├── MessageStorage.swift、MessageStorage+Protocols.swift
│   │   └── FileStorageManager.swift
│   ├── Repository/MessageRepository.swift
│   ├── ViewModel/                 # ChatViewModel、ConversationListViewModel
│   ├── DependencyInjection/AppDependencies.swift
│   ├── Error、Logging、Media
├── ViewControllers/                 # 会话列表、通讯录、聊天、预览等
├── DataSources/MessageDataSource.swift
├── Coordinators/                    # InputCoordinator、MessageActionHandler
├── Services/                        # 录音、播放、缓存、相册、键盘等
├── Views/、Cells/、Protocols/、Utilities/、Transitions/
└── Info.plist
```

说明：原「Managers」目录已按职责拆到 `Services/`、`Coordinators/`、`DataSources/` 等，以仓库实际路径为准。

---

## 十一、关键设计决策

### 11.1 DiffableDataSource 与 isPlayed/sendStatus 更新（详见 ChatMessage.swift 注释）

**问题**：`isPlayed` 和 `sendStatus` 是可变字段，但 DiffableDataSource 要求 item 符合 `Hashable`，状态更新方式影响视觉效果。

| 方案 | Hashable 依据 | 更新机制 | 问题 | 适用版本 |
|------|---------------|----------|------|----------|
| A | id + isPlayed + sendStatus | apply 新 snapshot | delete+insert 闪烁 | — |
| B（当前） | id | reloadItems + messages 数组 | 需维护两份数据 | iOS 13+ |
| C（待升级） | id | reconfigureItems + insert/delete 替换 item | — | iOS 15+ |

### 11.2 消息发送后的滚动策略

新消息追加使用 `animatingDifferences: false`，避免系统默认的从顶部滑入动画；滚动与否由 `isNearBottom` 决定。

### 11.3 拖拽 Seek 防抖

拖拽期间设置 `isSeeking = true`，阻断播放器 50ms 定时器的进度更新推送，防止 `UISlider.value` 被外部覆盖导致抖动。手指抬起后执行实际 seek 并重置标志。

### 11.4 下拉加载历史的滚动位置保持

插入历史消息后内容总高度增加 ΔH，若不处理 `contentOffset` 会导致屏幕内容向下跳动。
解决方案：`dataSource.apply` 后立即调用 `collectionView.layoutIfNeeded()` 强制同步布局，
读取新 `contentSize.height`，将 `contentOffset.y` 加上 ΔH 抵消内容下移。

### 11.5 Cell 类型扩展架构（MessageCellConfigurable）

**问题**：随消息类型增加，cell provider 内的 `switch` 分支持续膨胀，注册代码分散。

**方案**：
- 所有 Cell 实现 `MessageCellConfigurable` 协议，统一 `configure(with:deps:)` 入口。
- `ChatMessage.Kind.reuseID` 集中维护 Kind → reuseID 映射，编译器保证 switch 穷举。
- `MessageCellDependencies` 聚合外部依赖，新增依赖不影响协议签名。
- cell provider 只剩一次 dequeue + 一次协议调用，新增类型只需：① 建 Cell 实现协议 ② `Kind.reuseID` 追加一行 ③ 注册一行。

### 11.6 收/发方向布局切换

采用两套预构建约束数组（`incomingConstraints` / `outgoingConstraints`），`configureCommon` 时先全部停用再激活目标套。
相比 `addConstraint`/`removeConstraint`，此方案在 cell 复用时不产生约束冲突警告。

### 11.7 头像颜色稳定性

不使用 `String.hashValue`（Swift SE-0206 每次进程启动随机化），改用 UTF-8 字节求和映射到固定调色板，确保同一发送者头像颜色跨 session 一致。

### 11.8 图片和视频消息的缩略图加载

- **图片**：后台线程加载 `Data(contentsOf:)` → `UIImage(data:)`，主线程更新 UI
- **视频**：使用 `AVAssetImageGenerator` 提取第一帧作为缩略图
- 生产环境建议使用 SDWebImage 等专业图片加载库

### 11.9 扩展功能按钮设计

- 类似 iMessage 的 `+` 按钮，位于输入栏左侧
- 通过 `UIAlertController` 弹出功能菜单
- 使用 `PHPickerViewController` 选择相册（iOS 14+）
- 预留拍照、位置等功能接口

### 11.10 代码文件结构组织

按功能模块分类（与 **第十章** 目录树一致，此处为逻辑分组）：
- **App**：入口与 Composition Root  
- **Models**：消息、联系人、会话摘要等  
- **Core**：存储（GRDB）、Repository、ViewModel、依赖注入、错误与日志  
- **ViewControllers / Views / Cells / Protocols**  
- **Coordinators / Services / DataSources**：原分散在「Managers」的职责现归此类  

### 11.11 文本消息复制与上下文菜单设计

**统一交互模式（UIContextMenuInteraction）**：
- 所有消息类型统一使用 `UIContextMenuInteraction`（iOS 13+）
- 替代原有的 `UILongPressGestureRecognizer` + `UIAlertController` 方案
- 提供原生 iOS 体验：模糊背景、流畅动画、SF Symbol 图标

**外部控制菜单内容（IoC 模式）**：
- Cell 通过 `contextMenuProvider: ((ChatMessage) -> UIMenu?)` 回调获取菜单
- ViewController 设置回调，委托给 `MessageActionHandler.buildContextMenu(for:)`
- 职责分离：Cell 负责显示，Handler 负责业务逻辑和菜单构建

**菜单项动态构建**：
- 文本消息：复制（复制全部文本）+ 撤回（条件显示）+ 删除
- 其他消息：撤回（条件显示）+ 删除
- 撤回条件：自己发送 + 已送达 + 3 分钟内

**实现细节**：
- `ChatBubbleCell` 基类添加 `UIContextMenuInteraction` 到 `bubble` 视图
- 在 `configureCommon` 中保存 `currentMessage` 供菜单使用
- `MessageActionHandler.buildContextMenu` 根据消息类型和状态构建 `UIMenu`
- 文本消息使用 `UILabel` 显示（简洁），复制功能在菜单中实现
- 文本内容检测使用 `NSDataDetector` + 正则表达式，点击通过 `UITapGestureRecognizer` 处理

**优点**：
- 统一的交互体验，所有消息类型使用相同的长按交互
- 高度灵活，外部可以完全控制菜单内容和行为
- 易于扩展，新增菜单项只需修改 `buildContextMenu` 方法
- Cell 可复用性强，可以在不同场景下使用不同的菜单
- 智能识别文本中的特殊内容（URL、电话、银行卡号），提供便捷操作

### 11.12 本地存储事务边界

- 每个对外存储方法（`MessageStore` / `ConversationStore` / `ReceiptStore`）内部通常对应 **一次** `DatabaseManager.write` 或 `read`，闭包内多步 SQL 属于同一 SQLite 事务，保证消息行、附件、会话冗余字段、未读计数等一致更新。
- 多个 `actor` 共享同一 `DatabaseManager` 时，由 GRDB 的 `DatabaseQueue` **串行化**所有访问，避免并发写竞态。
