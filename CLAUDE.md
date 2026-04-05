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

# 运行单元测试
xcodebuild test \
  -project VoiceIM.xcodeproj \
  -scheme VoiceIMTests \
  -destination "platform=iOS Simulator,name=iPhone 15"

# 用 Xcode 打开工程
open VoiceIM.xcodeproj
```

每次修改 `project.yml` 后需重新运行 `xcodegen generate` 才能使配置生效；Swift 源文件的改动不需要重新生成。

## 技术栈

- **Swift 6.0**，严格并发检查开启（`ENABLE_STRICT_OBJC_MSGSEND: YES`）
- **UIKit**，无 SwiftUI
- **iOS 15.0+**
- **Swift Testing**：单元测试框架（iOS 15+）
- **AVFoundation**：`AVAudioRecorder`（录音）、`AVAudioPlayer`（播放）、`AVAsset`（视频处理）
- **AVKit**：`AVPlayerViewController`（视频播放）
- **PhotosUI**：`PHPickerViewController`（相册选择，iOS 14+）
- 列表：`UICollectionViewDiffableDataSource` + `UICollectionViewCompositionalLayout`（均为 iOS 13 API）

## 架构概览（2024 重构版）

项目采用 **MVVM + Repository** 架构，代码按层级组织：

```
VoiceIM/
├── Core/                          # 核心层（业务无关）
│   ├── Error/                     # 统一错误处理
│   │   ├── ChatError.swift        # 错误类型定义
│   │   └── ErrorHandler.swift    # 错误展示策略
│   ├── Logging/                   # 日志系统
│   │   └── Logger.swift           # 日志协议和实现
│   ├── Storage/                   # 存储层
│   │   ├── FileStorageManager.swift   # 文件管理
│   │   └── MessageStorage.swift       # 消息持久化
│   ├── Repository/                # 数据仓库层
│   │   └── MessageRepository.swift    # 消息业务逻辑
│   ├── ViewModel/                 # 视图模型层
│   │   └── ChatViewModel.swift        # 聊天状态管理
│   ├── Protocols/                 # 协议抽象
│   │   └── ServiceProtocols.swift     # 服务接口定义
│   └── DependencyInjection/       # 依赖注入
│       └── AppDependencies.swift      # 依赖容器
├── Models/                        # 数据模型
├── Views/                         # 自定义视图
├── ViewControllers/               # 视图控制器
├── Managers/                      # 服务管理器
├── Cells/                         # 列表 Cell
└── Protocols/                     # UI 协议

VoiceIMTests/                      # 单元测试
├── MessageRepositoryTests.swift
├── FileStorageManagerTests.swift
├── ChatErrorTests.swift
└── LoggerTests.swift
```

### 架构原则

1. **依赖注入**：通过 `AppDependencies` 容器管理所有服务实例，替代 `.shared` 单例
2. **协议抽象**：核心服务定义协议接口，便于测试和替换实现
3. **单一数据源**：`ChatViewModel` 使用 `@Published` 管理状态，ViewController 订阅变化
4. **错误统一处理**：所有错误归类到 `ChatError`，通过 `ErrorHandler` 统一展示
5. **日志系统**：使用 `VoiceIM.logger` 全局实例，支持多目标输出

### 数据流（新架构）

```
用户操作
   ↓
ViewController → ChatViewModel (状态管理)
                      ↓
                MessageRepository (业务逻辑)
                      ↓
        ┌─────────────┼─────────────┐
        ↓             ↓             ↓
  MessageStorage  FileStorage  NetworkService
   (持久化)        (文件)        (网络)
        ↓             ↓             ↓
    JSON 文件      本地文件      服务器 API
```

**关键组件**：

- **ChatViewModel**：管理消息列表、播放状态、录音状态，提供单一数据源
- **MessageRepository**：封装消息发送、删除、撤回等业务逻辑
- **MessageStorage**：消息持久化到本地 JSON 文件
- **FileStorageManager**：统一管理录音/图片/视频文件的存储和清理
- **ErrorHandler**：根据错误类型选择展示方式（Toast/Alert/Banner）
- **Logger**：支持控制台和文件日志，可组合多个输出目标

### 旧架构兼容性

当前 ViewController 仍使用旧架构（直接操作 MessageDataSource），新架构组件已就绪但尚未集成。迁移步骤：

1. 在 `SceneDelegate` 中初始化 `AppDependencies`
2. 创建 `ChatViewModel` 实例并注入依赖
3. 修改 `VoiceChatViewController` 订阅 ViewModel 的 `@Published` 属性
4. 移除 `simulateSendMessage` 等业务逻辑，改为调用 ViewModel 方法

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

### 上下文菜单（UIContextMenuInteraction）

所有消息类型统一使用 `UIContextMenuInteraction`（iOS 13+）实现长按菜单：

- **ChatBubbleCell（基类）**：
  - 添加 `UIContextMenuInteraction` 到 `bubble` 视图
  - 通过 `contextMenuProvider: ((ChatMessage) -> UIMenu?)` 回调获取菜单
  - 在 `configureCommon` 中保存 `currentMessage` 供菜单使用

- **外部控制菜单内容**：
  - ViewController 在 cell provider 中设置 `contextMenuProvider`
  - 委托给 `MessageActionHandler.buildContextMenu(for:)` 构建菜单
  - 根据消息类型和状态动态显示菜单项（复制/撤回/删除）

- **文本消息特殊处理**：
  - 菜单包含"复制"选项（复制全部文本到剪贴板）
  - 支持自动检测并高亮 URL、电话号、银行卡号（16-19位）
  - 点击高亮内容：URL 在 Safari 打开，电话号调起拨号，银行卡号弹出复制对话框
  - 使用 `NSDataDetector` 检测 URL/电话，正则表达式检测银行卡号
  - 点击事件通过 `MessageCellDependencies.onLinkTapped` 回调传递
  - 其他消息类型仅显示撤回/删除

### 录音状态机

`RecordState`: `.idle` → `.recording` → `.cancelReady` → `.idle`

长按手势（`UILongPressGestureRecognizer`，`allowableMovement = 2000`）：
- `.began`：请求麦克风权限，启动 `AVAudioRecorder`，开始 1s 倒计时 Timer
- `.changed`：手指上移 > 80pt 进入 `.cancelReady`，下移回来恢复 `.recording`
- `.ended`：`.recording` → 发送；`.cancelReady` → 丢弃

### 播放互斥与 Seek 防抖

`VoicePlaybackManager.play(id:url:)` 内部先调 `stopCurrent()`，`onStop` 回调通知旧 cell 重置状态。`VoiceMessageCell` 用 `isSeeking: Bool` 标志在拖拽期间屏蔽 50ms 进度 Timer 的推送，防止 `UISlider.value` 被覆盖。

### 波形视图宽度策略（WaveformProgressView）

语音消息气泡采用**分段增长策略**，模仿微信/Telegram 设计：

- **阶段1（≤10秒）**：线性增长 `width = minimumWidth + linearGrowthRate × duration`
- **阶段2（>10秒）**：对数增长 `width = widthAtThreshold + 30 × log₂(duration / linearThreshold)`

**关键实现细节**：

1. **布局优先级**：
   - `waveformView` 设置 `.required` 优先级，严格按 `intrinsicContentSize` 显示
   - `durationLabel` 设置 `.defaultLow` hugging 优先级，优先吸收额外空间
   - 防止 waveformView 被 Auto Layout 意外拉伸

2. **波形条数计算**：
   - `barCount` 基于实际渲染宽度（`bounds.width`）动态计算
   - 公式：`(bounds.width + barSpacing) / (barWidth + barSpacing)`
   - 确保波形条填满整个视图

3. **波形数据加载**：
   - `loadWaveform(from:)` 延迟到布局完成后执行（`DispatchQueue.main.async`）
   - 提取的采样点数量匹配当前 `barCount`，避免重复采样或跳过数据
   - 布局变化时自动重新生成波形数据（阈值 5pt）

详细参数说明见 `WaveformProgressView-API.md`。

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

### 消息撤回

支持撤回自己发送的消息，撤回后显示提示文本：

- **撤回条件**（同时满足）：
  - 自己发送的消息（`isOutgoing = true`）
  - 发送状态为 `.delivered`（已送达）
  - 发送时间在 3 分钟以内
- **撤回逻辑**：长按消息 → 选择"撤回" → 原消息替换为 `RecalledMessageCell`
- **文本消息撤回**：保留原文本内容，点击撤回提示可重新编辑发送
- **其他类型撤回**：仅显示"你撤回了一条消息"，不可重新编辑
- **实现细节**：
  - `ChatMessage.Kind.recalled(originalText: String?)` 存储撤回状态
  - 撤回时删除原消息的本地文件（语音/图片/视频）
  - 保留原消息的时间戳和发送者信息
  - 通过 `snapshot.insertItems + deleteItems` 替换消息
  - 撤回消息不显示时间分隔行

### 音频播放停止场景

以下事件会自动停止音频播放：

1. **开始录音前**：避免录音与播放冲突
2. **删除正在播放的消息**：避免播放器持有悬空 URL
3. **播放互斥切换**：点击正在播放的消息停止
4. **页面消失时**（`viewWillDisappear`）：避免后台播放
5. **应用进入后台时**（`didEnterBackgroundNotification`）：避免后台音频播放
6. **音频会话被打断时**（`AVAudioSession.interruptionNotification`）：来电、闹钟等系统事件

### 架构重构（VoiceChatViewController）

主控制器从 1052 行精简到 519 行，职责分离为 4 个管理器：

- **MessageDataSource**：封装 `UICollectionViewDiffableDataSource` 和 snapshot 更新逻辑
- **MessageActionHandler**：统一处理消息交互（删除/撤回/重试/上下文菜单构建）
- **InputCoordinator**：管理录音状态机、扩展功能菜单、文字/语音/图片/视频发送
- **KeyboardManager**：处理键盘显示/隐藏时的布局调整和滚动策略

## 需求文档

完整功能需求见 `REQUIREMENTS.md`。
