# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

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
- **iOS 13.0+**，部分注释中标注了 iOS 15 可升级路径
- **AVFoundation**：`AVAudioRecorder`（录音）、`AVAudioPlayer`（播放）
- 列表：`UICollectionViewDiffableDataSource` + `UICollectionViewCompositionalLayout`（均为 iOS 13 API）

## 架构概览

所有功能集中在 `VoiceIM/` 目录下，无第三方依赖。

### 数据流

```
VoiceRecordManager          VoiceCacheManager（actor）
      │ 录音文件 URL                │ 下载并缓存远程 URL
      ▼                            ▼
VoiceChatViewController ──── VoiceMessage（数据模型）
      │                            │
      │  DiffableDataSource        │ messages: [VoiceMessage]（可变状态）
      │  snapshot（仅存顺序/id）    │ isPlayed 在此更新
      ▼                            ▼
VoiceMessageCell         VoicePlaybackManager
  进度滑块 / 红点               播放互斥 / 进度回调
```

### 并发模型

- `VoiceRecordManager`、`VoicePlaybackManager`、`VoiceChatViewController` 均为 `@MainActor`
- `VoiceCacheManager` 是 `actor`，用 `inFlight: [URL: Task<URL, Error>]` 防止同一 URL 并发下载
- AVFoundation delegate 方法标记 `nonisolated`，内部用 `Task { @MainActor in ... }` 回主线程

### isPlayed 状态更新（关键设计，详见 VoiceMessage.swift 注释）

`Hashable` 仅基于 `id`，`isPlayed` 变化通过以下路径传递：

1. `messages[idx].isPlayed = true`
2. `snapshot.reloadItems([messages[idx]])` → cell provider 重新执行
3. cell provider 从 `messages` 数组查最新状态（snapshot 内 item 不变，仍是旧值）
4. `configure(isUnread: false)` → cell 检测到未读→已读，触发红点淡出动画

升级到 iOS 15 后可改用 `reconfigureItems`，届时 `messages` 数组可移除，具体示例见 `markAsPlayed` 方法注释。

### 录音状态机

`RecordState`: `.idle` → `.recording` → `.cancelReady` → `.idle`

长按手势（`UILongPressGestureRecognizer`，`allowableMovement = 2000`）：
- `.began`：请求麦克风权限，启动 `AVAudioRecorder`，开始 1s 倒计时 Timer
- `.changed`：手指上移 > 80pt 进入 `.cancelReady`，下移回来恢复 `.recording`
- `.ended`：`.recording` → 发送；`.cancelReady` → 丢弃

### 播放互斥与 Seek 防抖

`VoicePlaybackManager.play(id:url:)` 内部先调 `stopCurrent()`，`onStop` 回调通知旧 cell 重置状态。`VoiceMessageCell` 用 `isSeeking: Bool` 标志在拖拽期间屏蔽 50ms 进度 Timer 的推送，防止 `UISlider.value` 被覆盖。

## 需求文档

完整功能需求见 `REQUIREMENTS.md`。
