# IM 语音消息功能需求文档

> 整理自开发会话，最终确认版本。

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

### 2.1 展示

- 每次发送成功后，消息追加到列表末尾。
- 列表使用 `UICollectionView`（iOS 13 `UICollectionViewDiffableDataSource` + `UICollectionViewCompositionalLayout`）。
- 消息气泡靠左展示，显示：播放按钮、时长/剩余时长、进度滑块（播放时显示）、未读红点（未播放时显示）。

### 2.2 滚动策略

- 用户**在底部附近**（距底部 < 60pt）时发送语音：自动滚动到最新消息。
- 用户**正在浏览历史消息**时发送语音：不滚动，保持当前位置。
- 判断公式：`contentSize.height - contentOffset.y - bounds.height + adjustedContentInset.bottom < 60`

---

## 三、播放

### 3.1 基本交互

- 点击语音消息气泡上的播放按钮开始播放。
- 再次点击同一条正在播放的消息：停止播放。
- 同一时刻只允许播放一条语音，播放新消息时自动停止当前播放。

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
| 本地录制 | `VoiceMessage.localURL` | 直接播放 |
| 远程服务器 | `VoiceMessage.remoteURL` | 下载后缓存，再播放 |

### 3.5 下载缓存

- 缓存目录：`Library/Caches/IMVoiceCache/`
- 缓存文件命名：`abs(remoteURL.absoluteString.hashValue).<ext>`
- 同一 URL 同时发起多次下载请求时，复用同一个 `Task`，避免重复下载。
- 缓存命中时直接返回本地路径，不发起网络请求。

---

## 四、未读提醒

- 每条语音消息默认为**未读状态**，在气泡播放按钮右上角显示红色圆点（直径 10pt）。
- 用户首次点击播放时，红点以 **0.2s 淡出动画**消失，标记为已读。
- 已读状态持久化在 `VoiceMessage.isPlayed`，供后续数据层持久化使用。
- cell 复用时根据 `isPlayed` 状态直接显隐红点（不触发动画），仅在状态从未读变已读时才播放淡出动画。

---

## 五、技术约束

| 项目 | 要求 |
|------|------|
| 语言 | Swift 6.0，启用严格并发检查 |
| UI 框架 | UIKit（无 SwiftUI） |
| 最低系统 | iOS 13.0+ |
| 音频框架 | AVFoundation（`AVAudioRecorder` 录音，`AVAudioPlayer` 播放） |
| 列表组件 | `UICollectionView` + `UICollectionViewDiffableDataSource` + `UICollectionViewCompositionalLayout` |
| 并发模型 | `async/await`，UI 操作统一在 `@MainActor`，下载缓存使用 `actor` |

---

## 六、文件结构

```
VoiceIM/
├── VoiceMessage.swift              // 数据模型，含 isPlayed 持久化字段
├── VoiceRecordManager.swift        // 录音管理（@MainActor 单例）
├── VoiceCacheManager.swift         // 下载缓存（actor，线程安全）
├── VoicePlaybackManager.swift      // 播放管理（@MainActor 单例，播放互斥）
├── VoiceMessageCell.swift          // 语音消息气泡 Cell（UICollectionViewCell）
├── RecordingOverlayView.swift      // 录音浮层（正常 / 预备取消两态）
├── ToastView.swift                 // 轻量 Toast 提示
├── VoiceChatViewController.swift   // 主页面（UICollectionView + DiffableDataSource）
├── AppDelegate.swift
├── SceneDelegate.swift
└── Info.plist                      // 含 NSMicrophoneUsageDescription
```

---

## 七、关键设计决策

### 7.1 DiffableDataSource 与 isPlayed 更新（详见 VoiceMessage.swift 注释）

**问题**：`isPlayed` 是可变字段，但 DiffableDataSource 要求 item 符合 `Hashable`，状态更新方式影响视觉效果。

| 方案 | Hashable 依据 | 更新机制 | 问题 | 适用版本 |
|------|---------------|----------|------|----------|
| A | id + isPlayed | apply 新 snapshot | delete+insert 闪烁 | — |
| B（当前） | id | reloadItems + messages 数组 | 需维护两份数据 | iOS 13+ |
| C（待升级） | id | reconfigureItems + insert/delete 替换 item | — | iOS 15+ |

### 7.2 消息发送后的滚动策略

新消息追加使用 `UIView.performWithoutAnimation { insertRows }` 或 DiffableDataSource `animatingDifferences: false`，避免系统默认的从顶部滑入动画。滚动与否由 `isNearBottom` 决定。

### 7.3 拖拽 Seek 防抖

拖拽期间设置 `isSeeking = true`，阻断播放器 50ms 定时器的进度更新推送，防止 `UISlider.value` 被外部覆盖导致抖动。手指抬起后执行实际 seek 并重置标志。
