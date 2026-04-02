# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 构建与运行

```bash
# 重新生成 Xcode 工程（修改 project.yml 后执行）
xcodegen generate

# 编译检查（不签名，仅验证代码）
xcodebuild -project VoiceIM.xcodeproj \
  -scheme VoiceIM \
  -destination "generic/platform=iOS Simulator" \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build

# 用 Xcode 打开工程
open VoiceIM.xcodeproj
```

每次修改 `project.yml` 后需重新运行 `xcodegen generate` 才能使配置生效；Swift 源文件的改动不需要重新生成。

## 技术栈

- **Swift 6.0**，严格并发检查开启（`ENABLE_STRICT_OBJC_MSGSEND: YES`）
- **UIKit**，无 SwiftUI
- **iOS 15.0+**
- **AVFoundation**：`AVAudioRecorder`（录音）、`AVAudioPlayer`（播放）、`AVAsset`（视频处理）
- **AVKit**：`AVPlayerViewController`（视频播放）
- **PhotosUI**：`PHPickerViewController`（相册选择，iOS 14+）
- 列表：`UICollectionViewDiffableDataSource` + `UICollectionViewCompositionalLayout`（均为 iOS 13 API）

## 架构概览

代码按功能分为 7 个文件夹：`App`、`Models`、`Views`、`ViewControllers`、`Managers`、`Cells`、`Protocols`。无第三方依赖。

### 数据流

```
VoiceRecordManager          VoiceCacheManager（actor）
      │ 录音文件 URL                │ 下载并缓存远程 URL
      ▼                            ▼
VoiceChatViewController ──── ChatMessage（数据模型）
      │                            │
      │  DiffableDataSource        │ messages: [ChatMessage]（可变状态）
      │  snapshot（仅存顺序/id）    │ isPlayed/sendStatus 在此更新
      ▼                            ▼
MessageCell (4种)         VoicePlaybackManager
  进度滑块 / 红点 / 状态指示器    播放互斥 / 进度回调
```

### 并发模型

- `VoiceRecordManager`、`VoicePlaybackManager`、`VoiceChatViewController` 均为 `@MainActor`
- `VoiceCacheManager` 是 `actor`，用 `inFlight: [URL: Task<URL, Error>]` 防止同一 URL 并发下载
- AVFoundation delegate 方法标记 `nonisolated`，内部用 `Task { @MainActor in ... }` 回主线程

### 可变状态更新（关键设计）

`ChatMessage.Hashable` 仅基于 `id`，`isPlayed` 和 `sendStatus` 变化通过以下路径传递：

1. `messages[idx].isPlayed = true` 或 `messages[idx].sendStatus = .failed`
2. `snapshot.reloadItems([messages[idx]])` → cell provider 重新执行
3. cell provider 从 `messages` 数组查最新状态（snapshot 内 item 不变，仍是旧值）
4. `configure(...)` → cell 根据新状态更新 UI（红点淡出动画、状态指示器切换）

**重要**：必须维护独立的 `messages` 数组作为可变状态的真实来源。升级到 iOS 15 后可改用 `reconfigureItems`，届时 `messages` 数组可移除，具体示例见 `ChatMessage.swift` 注释。

### 消息类型扩展

通过 `MessageCellConfigurable` 协议统一 Cell 配置接口。新增消息类型步骤：

1. 在 `ChatMessage.Kind` 追加 case（如 `.file(URL, name: String)`）
2. 在 `Kind.reuseID` 追加映射（编译器保证 switch 穷举）
3. 创建 Cell 实现 `MessageCellConfigurable` 协议
4. 在 `VoiceChatViewController.setupCollectionView()` 注册 Cell
5. cell provider 自动通过协议调用 `configure(with:deps:)`

### 录音状态机

`RecordState`: `.idle` → `.recording` → `.cancelReady` → `.idle`

长按手势（`UILongPressGestureRecognizer`，`allowableMovement = 2000`）：
- `.began`：请求麦克风权限，启动 `AVAudioRecorder`，开始 1s 倒计时 Timer
- `.changed`：手指上移 > 80pt 进入 `.cancelReady`，下移回来恢复 `.recording`
- `.ended`：`.recording` → 发送；`.cancelReady` → 丢弃

### 播放互斥与 Seek 防抖

`VoicePlaybackManager.play(id:url:)` 内部先调 `stopCurrent()`，`onStop` 回调通知旧 cell 重置状态。`VoiceMessageCell` 用 `isSeeking: Bool` 标志在拖拽期间屏蔽 50ms 进度 Timer 的推送，防止 `UISlider.value` 被覆盖。

### 输入栏模式切换

`ChatInputView` 支持文字/语音模式切换，通过两套约束实现：

- **文字模式**：`textView` + `sendButton` 可见，`voiceInputButton` 隐藏；`toggleButton` 约束到 `sendButton`
- **语音模式**：`voiceInputButton` 可见，`textView` + `sendButton` 隐藏；`toggleButton` 约束到父视图右边

切换时停用旧约束、激活新约束，避免约束冲突。

### 消息发送状态

`ChatMessage.SendStatus` 流转：`.sending` → `.delivered` → `.read`（或 `.sending` → `.failed`）

- 仅自己发送的消息（`isOutgoing = true`）显示状态指示器
- `.sending`：旋转加载指示器（`UIActivityIndicatorView`）
- `.failed`：红色感叹号，点击触发 `retryMessage`（删除失败消息，根据类型重新发送）
- `.delivered` / `.read`：UI 暂未实现

开发阶段使用 `simulateSendMessage` 模拟网络请求（70% 成功率），生产环境替换为真实 API。

## 需求文档

完整功能需求见 `REQUIREMENTS.md`。
