# MVVM 架构重构指南

## 概述

本文档说明如何将 VoiceChatViewController 从旧架构迁移到 MVVM 架构。

---

## 文件对比

### 新文件（MVVM 版本）
- `VoiceChatViewController_MVVM.swift` - 使用 ChatViewModel 的新版本
- `SceneDelegate_MVVM.swift` - 使用 AppDependencies 的新版本

### 旧文件（保留）
- `VoiceChatViewController.swift` - 原版本（作为参考）
- `SceneDelegate.swift` - 原版本

---

## 主要变化

### 1. 依赖注入

**旧代码**：
```swift
init(player: AudioPlaybackService = VoicePlaybackManager.shared) {
    self.player = player
    super.init(nibName: nil, bundle: nil)
}
```

**新代码**：
```swift
private let viewModel: ChatViewModel

init(viewModel: ChatViewModel) {
    self.viewModel = viewModel
    super.init(nibName: nil, bundle: nil)
}
```

### 2. 状态订阅

**新增**：
```swift
private var cancellables = Set<AnyCancellable>()

private func bindViewModel() {
    // 订阅消息列表变化
    viewModel.$messages
        .receive(on: DispatchQueue.main)
        .sink { [weak self] messages in
            self?.updateMessages(messages)
        }
        .store(in: &cancellables)

    // 订阅错误
    viewModel.$error
        .compactMap { $0 }
        .receive(on: DispatchQueue.main)
        .sink { [weak self] error in
            self?.handleError(error)
        }
        .store(in: &cancellables)
}
```

### 3. 业务逻辑调用

**旧代码**：
```swift
inputCoordinator.onSendText = { [weak self] text in
    self?.appendMessage(.text(text))
}
```

**新代码**：
```swift
inputCoordinator.onSendText = { [weak self] text in
    self?.viewModel.sendTextMessage(text)
}
```

### 4. SceneDelegate 初始化

**旧代码**：
```swift
let chatViewController = VoiceChatViewController()
```

**新代码**：
```swift
let dependencies = AppDependencies.shared
let viewModel = dependencies.makeChatViewModel()
let chatViewController = VoiceChatViewController(viewModel: viewModel)
```

---

## 迁移步骤

### 步骤 1：备份旧文件
```bash
# 旧文件已保留，无需额外操作
```

### 步骤 2：替换文件

```bash
# 替换 VoiceChatViewController
mv VoiceIM/ViewControllers/VoiceChatViewController.swift VoiceIM/ViewControllers/VoiceChatViewController_OLD.swift
mv VoiceIM/ViewControllers/VoiceChatViewController_MVVM.swift VoiceIM/ViewControllers/VoiceChatViewController.swift

# 替换 SceneDelegate
mv VoiceIM/App/SceneDelegate.swift VoiceIM/App/SceneDelegate_OLD.swift
mv VoiceIM/App/SceneDelegate_MVVM.swift VoiceIM/App/SceneDelegate.swift
```

### 步骤 3：重新生成 Xcode 工程

```bash
xcodegen generate
```

### 步骤 4：编译验证

```bash
xcodebuild -project VoiceIM.xcodeproj \
  -scheme VoiceIM \
  -destination "generic/platform=iOS Simulator" \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

### 步骤 5：运行测试

```bash
# 在 Xcode 中运行应用
open VoiceIM.xcodeproj

# 或使用命令行
xcodebuild test \
  -project VoiceIM.xcodeproj \
  -scheme VoiceIMTests \
  -destination "platform=iOS Simulator,name=iPhone 15"
```

---

## 功能验证清单

迁移后需要验证以下功能：

- [ ] 发送文本消息
- [ ] 发送语音消息
- [ ] 发送图片消息
- [ ] 发送视频消息
- [ ] 发送位置消息
- [ ] 播放语音消息
- [ ] 删除消息
- [ ] 撤回消息
- [ ] 重试失败消息
- [ ] 消息持久化（重启应用后消息仍在）
- [ ] 错误处理（显示 Toast/Alert）
- [ ] 日志记录

---

## 已知问题

### 1. 播放进度回调未实现

**问题**：AudioPlaybackService 不支持 Combine，无法订阅播放进度。

**临时方案**：使用旧的回调方式。

**长期方案**：重构 VoicePlaybackManager 支持 Combine。

### 2. 历史消息加载未实现

**问题**：下拉刷新功能未连接到 ViewModel。

**临时方案**：保留旧的模拟逻辑。

**长期方案**：在 ChatViewModel 中实现 `loadHistoryMessages()` 方法。

### 3. 消息列表更新策略

**问题**：当前使用简单的"清空后重新添加"策略，性能不佳。

**临时方案**：可接受，消息数量不多时影响不大。

**长期方案**：实现增量更新（diff 算法）。

---

## 回滚方案

如果迁移后出现问题，可以快速回滚：

```bash
# 恢复旧文件
mv VoiceIM/ViewControllers/VoiceChatViewController_OLD.swift VoiceIM/ViewControllers/VoiceChatViewController.swift
mv VoiceIM/App/SceneDelegate_OLD.swift VoiceIM/App/SceneDelegate.swift

# 重新生成工程
xcodegen generate

# 重新编译
xcodebuild -project VoiceIM.xcodeproj -scheme VoiceIM build
```

---

## 性能对比

### 旧架构
- ViewController 行数：628 行
- 业务逻辑：在 ViewController 中
- 状态管理：分散在多个 Manager

### 新架构
- ViewController 行数：约 450 行（减少 28%）
- 业务逻辑：在 ChatViewModel 和 MessageRepository
- 状态管理：集中在 ChatViewModel

---

## 后续优化

1. **实现播放进度订阅**
   - 重构 VoicePlaybackManager 支持 Combine
   - 在 ChatViewModel 中订阅播放进度

2. **实现历史消息加载**
   - 在 MessageRepository 中实现分页加载
   - 在 ChatViewModel 中暴露 `loadHistoryMessages()` 方法

3. **优化消息列表更新**
   - 实现增量更新算法
   - 使用 DiffableDataSource 的 diff 功能

4. **添加单元测试**
   - ChatViewModel 测试
   - MessageRepository 测试
   - 集成测试

---

## 总结

MVVM 架构迁移已完成，新版本代码更清晰、更易维护、更易测试。

**下一步**：执行迁移步骤，验证功能，修复已知问题。
