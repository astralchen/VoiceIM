# IM 语音消息功能需求文档

> 整理自开发会话，持续更新。

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

### 2.3 时间分隔行

- 规则：与上一条消息的 `sentAt` 间隔 **> 5 分钟**时，在该消息上方显示时间分隔行。
- 第一条消息始终显示时间分隔行。
- 时间格式：
  - 今天：`HH:mm`
  - 昨天：`昨天 HH:mm`
  - 更早：`M月d日 HH:mm`
- 不显示时高度折叠为 0，不留白（`isHidden` + `heightConstraint = 0` 双重保证）。

### 2.4 气泡布局

| 方向 | 头像位置 | 气泡位置 | 气泡背景色 |
|------|----------|----------|------------|
| 自己（靠右） | cell 右侧 8pt | 头像左侧 8pt | `systemBlue × 0.15` |
| 对方（靠左） | cell 左侧 8pt | 头像右侧 8pt | `systemGray5` |

- 气泡最大宽度：contentView 宽度的 **65%**（为头像 36pt + 两侧边距共 52pt 留空间）。
- 方向切换通过激活/停用两套预构建约束实现，cell 复用时先停用全部再激活目标套，避免约束冲突。

### 2.5 滚动策略

- 用户**在底部附近**（距底部 < 60pt）时发送消息：自动滚动到最新消息。
- 用户**正在浏览历史消息**时发送消息：不滚动，保持当前位置。
- 判断公式：`contentSize.height - contentOffset.y - bounds.height + adjustedContentInset.bottom < 60`

### 2.6 下拉加载历史记录

- 在列表顶部下拉触发 `UIRefreshControl`，加载更早的历史消息。
- 历史消息插入列表头部，**不打断用户当前阅读位置**（`layoutIfNeeded()` 后补偿 `contentOffset.y`）。
- 防重：加载期间再次下拉立即结束刷新，不重复发起请求（`isLoadingHistory` 标志）。
- 加载完所有页后显示 Toast"没有更多历史消息"，不再触发请求。

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
  - **拍照**：开发中
  - **位置**：开发中
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

## 五、未读提醒

- 每条语音消息默认为**未读状态**，在气泡播放按钮右上角显示红色圆点（直径 10pt）。
- 用户首次点击播放时，红点以 **0.2s 淡出动画**消失，标记为已读。
- 已读状态持久化在 `ChatMessage.isPlayed`，供后续数据层持久化使用。
- cell 复用时根据 `isPlayed` 状态直接显隐红点（不触发动画），仅在状态从未读变已读时才播放淡出动画。

---

## 五、消息删除

- 长按语音消息气泡（≥ 0.5s）弹出操作菜单（`UIAlertController`，`.actionSheet` 样式）。
- 菜单包含两项：**删除**（destructive 样式）和**取消**。
- 确认删除后执行以下步骤：
  1. 若该消息正在播放，先停止播放，避免播放器持有悬空 URL。
  2. 从 `messages` 数组中移除该条消息。
  3. 若存在本地临时录音文件（`localURL`），同步删除磁盘文件。
  4. `snapshot.deleteItems` + `apply(animatingDifferences: true)` 从列表移除 cell。

---

## 六、技术约束

| 项目 | 要求 |
|------|------|
| 语言 | Swift 6.0，启用严格并发检查 |
| UI 框架 | UIKit（无 SwiftUI） |
| 最低系统 | iOS 15.0+ |
| 音频框架 | AVFoundation（`AVAudioRecorder` 录音，`AVAudioPlayer` 播放） |
| 相册选择 | PhotosUI（`PHPickerViewController`，iOS 14+） |
| 视频播放 | AVKit（`AVPlayerViewController`） |
| 列表组件 | `UICollectionView` + `UICollectionViewDiffableDataSource` + `UICollectionViewCompositionalLayout` |
| 并发模型 | `async/await`，UI 操作统一在 `@MainActor`，下载缓存使用 `actor` |

---

## 七、文件结构

```
VoiceIM/
├── App/                           # 应用入口
│   ├── AppDelegate.swift
│   └── SceneDelegate.swift
├── Models/                        # 数据模型
│   ├── ChatMessage.swift          # 通用消息数据模型（voice/text/image/video）
│   └── Sender.swift               # 发送者身份（id、displayName）
├── Views/                         # 视图组件
│   ├── AvatarView.swift           # 圆形头像占位视图
│   ├── ChatInputView.swift        # 输入栏（文字/语音切换 + 扩展按钮）
│   ├── RecordingOverlayView.swift # 录音浮层（正常/预备取消两态）
│   └── ToastView.swift            # 轻量 Toast 提示
├── ViewControllers/               # 视图控制器
│   ├── VoiceChatViewController.swift          # 主页面（UICollectionView + DiffableDataSource）
│   ├── RecordingOverlayViewController.swift   # 录音浮层控制器
│   ├── ImagePreviewViewController.swift       # 图片全屏预览
│   └── VideoPreviewViewController.swift       # 视频全屏播放
├── Managers/                      # 业务逻辑管理器
│   ├── VoiceRecordManager.swift   # 录音管理（@MainActor 单例）
│   ├── VoicePlaybackManager.swift # 播放管理（@MainActor 单例，播放互斥）
│   └── VoiceCacheManager.swift    # 下载缓存（actor，线程安全）
├── Cells/                         # 消息 Cell
│   ├── ChatBubbleCell.swift       # Cell 基类（时间分隔行 + 头像 + 收/发方向约束 + 状态指示器）
│   ├── VoiceMessageCell.swift     # 语音消息 Cell（继承 ChatBubbleCell）
│   ├── TextMessageCell.swift      # 文本消息 Cell（继承 ChatBubbleCell）
│   ├── ImageMessageCell.swift     # 图片消息 Cell（继承 ChatBubbleCell）
│   └── VideoMessageCell.swift     # 视频消息 Cell（继承 ChatBubbleCell）
├── Protocols/                     # 协议定义
│   └── MessageCellConfigurable.swift  # Cell 统一配置协议 + MessageCellDependencies
└── Info.plist                     # 含 NSMicrophoneUsageDescription
```

---

## 八、关键设计决策

### 8.1 DiffableDataSource 与 isPlayed/sendStatus 更新（详见 ChatMessage.swift 注释）

**问题**：`isPlayed` 和 `sendStatus` 是可变字段，但 DiffableDataSource 要求 item 符合 `Hashable`，状态更新方式影响视觉效果。

| 方案 | Hashable 依据 | 更新机制 | 问题 | 适用版本 |
|------|---------------|----------|------|----------|
| A | id + isPlayed + sendStatus | apply 新 snapshot | delete+insert 闪烁 | — |
| B（当前） | id | reloadItems + messages 数组 | 需维护两份数据 | iOS 13+ |
| C（待升级） | id | reconfigureItems + insert/delete 替换 item | — | iOS 15+ |

### 8.2 消息发送后的滚动策略

新消息追加使用 `animatingDifferences: false`，避免系统默认的从顶部滑入动画；滚动与否由 `isNearBottom` 决定。

### 8.3 拖拽 Seek 防抖

拖拽期间设置 `isSeeking = true`，阻断播放器 50ms 定时器的进度更新推送，防止 `UISlider.value` 被外部覆盖导致抖动。手指抬起后执行实际 seek 并重置标志。

### 8.4 下拉加载历史的滚动位置保持

插入历史消息后内容总高度增加 ΔH，若不处理 `contentOffset` 会导致屏幕内容向下跳动。
解决方案：`dataSource.apply` 后立即调用 `collectionView.layoutIfNeeded()` 强制同步布局，
读取新 `contentSize.height`，将 `contentOffset.y` 加上 ΔH 抵消内容下移。

### 8.5 Cell 类型扩展架构（MessageCellConfigurable）

**问题**：随消息类型增加，cell provider 内的 `switch` 分支持续膨胀，注册代码分散。

**方案**：
- 所有 Cell 实现 `MessageCellConfigurable` 协议，统一 `configure(with:deps:)` 入口。
- `ChatMessage.Kind.reuseID` 集中维护 Kind → reuseID 映射，编译器保证 switch 穷举。
- `MessageCellDependencies` 聚合外部依赖，新增依赖不影响协议签名。
- cell provider 只剩一次 dequeue + 一次协议调用，新增类型只需：① 建 Cell 实现协议 ② `Kind.reuseID` 追加一行 ③ 注册一行。

### 8.6 收/发方向布局切换

采用两套预构建约束数组（`incomingConstraints` / `outgoingConstraints`），`configureCommon` 时先全部停用再激活目标套。
相比 `addConstraint`/`removeConstraint`，此方案在 cell 复用时不产生约束冲突警告。

### 8.7 头像颜色稳定性

不使用 `String.hashValue`（Swift SE-0206 每次进程启动随机化），改用 UTF-8 字节求和映射到固定调色板，确保同一发送者头像颜色跨 session 一致。

### 8.8 图片和视频消息的缩略图加载

- **图片**：后台线程加载 `Data(contentsOf:)` → `UIImage(data:)`，主线程更新 UI
- **视频**：使用 `AVAssetImageGenerator` 提取第一帧作为缩略图
- 生产环境建议使用 SDWebImage 等专业图片加载库

### 8.9 扩展功能按钮设计

- 类似 iMessage 的 `+` 按钮，位于输入栏左侧
- 通过 `UIAlertController` 弹出功能菜单
- 使用 `PHPickerViewController` 选择相册（iOS 14+）
- 预留拍照、位置等功能接口

### 8.10 代码文件结构组织

按功能模块分类到 7 个文件夹：
- **App**: 应用入口（AppDelegate、SceneDelegate）
- **Models**: 数据模型（ChatMessage、Sender）
- **Views**: 视图组件（AvatarView、ChatInputView、RecordingOverlayView、ToastView）
- **ViewControllers**: 视图控制器（主页面、录音浮层、图片/视频预览）
- **Managers**: 业务逻辑管理器（录音、播放、缓存）
- **Cells**: 消息 Cell（基类 + 4 种消息类型）
- **Protocols**: 协议定义（MessageCellConfigurable）
