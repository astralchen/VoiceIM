# 已应用的修复

生成时间：2026-04-06
最后更新：2026-04-06

## 修复的编译错误

### 1. VideoCacheManager.swift - Actor 隔离问题

**问题**：在 `Task { @MainActor }` 中尝试修改 actor 隔离的属性 `memoryWarningObserver`

**修复**：
- 移除 `Task { @MainActor }` 包装
- 直接在 actor 的 init 中注册 NotificationCenter 观察者
- 使用 `queue: nil` 让通知在发送线程执行

```swift
// 修复前
Task { @MainActor in
    memoryWarningObserver = NotificationCenter.default.addObserver(...)
}

// 修复后
memoryWarningObserver = NotificationCenter.default.addObserver(
    forName: UIApplication.didReceiveMemoryWarningNotification,
    object: nil,
    queue: nil
) { [weak self] _ in
    Task {
        await self?.clearMemoryCache()
    }
}
```

---

### 2. MessageRepository.swift - Actor 隔离调用

**问题**：在非 async 上下文中调用 actor 隔离的方法

**修复**：为以下方法添加 `await` 调用
- `fileStorage.deleteFile(at:)` → `await fileStorage.deleteFile(at:)`
- `storage.append(_:)` → `await storage.append(_:)`

**影响的方法**：
- `sendImageMessage(tempURL:sender:)`
- `sendVideoMessage(tempURL:duration:sender:)`

---

### 3. ChatMessage.swift - Codable 中访问 Actor 属性

**问题**：在 nonisolated 的 Codable 初始化器中无法访问 actor 隔离的目录属性

**修复**：在 `FileStorageManager` 中添加 nonisolated 静态方法
- `getVoiceDirectory()` - 返回语音目录路径
- `getImageDirectory()` - 返回图片目录路径
- `getVideoDirectory()` - 返回视频目录路径

```swift
// 修复前
let localURL = fileName.map {
    FileStorageManager.shared.voiceDirectory.appendingPathComponent($0)
}

// 修复后
let localURL = fileName.map {
    FileStorageManager.getVoiceDirectory().appendingPathComponent($0)
}
```

---

### 4. ChatViewModel.swift - Async 调用问题

**问题**：在非 async 函数中调用 async 方法

**修复**：将所有调用 repository async 方法的函数包装在 `Task { }` 中

**影响的方法**：
- `loadMessages()` - 包装 `repository.loadMessages()`
- `sendTextMessage(_:)` - 包装 `repository.sendTextMessage(text:)`
- `sendVoiceMessage(url:duration:)` - 包装 `repository.sendVoiceMessage(tempURL:duration:)`
- `sendLocationMessage(latitude:longitude:address:)` - 包装 `repository.sendLocationMessage(...)`
- `deleteMessage(id:)` - 包装 `repository.deleteMessage(id:)`
- `recallMessage(id:)` - 包装 `repository.recallMessage(id:)`
- `markAsPlayed(id:)` - 包装 `repository.markAsPlayed(id:)`
- `sendMessageToServer(id:)` - 添加 `await` 到 `repository.updateSendStatus(...)`

```swift
// 修复前
func sendTextMessage(_ text: String) {
    do {
        let message = try repository.sendTextMessage(text: text)
        messages.append(message)
    } catch {
        self.error = error as? ChatError ?? .unknown(error)
    }
}

// 修复后
func sendTextMessage(_ text: String) {
    Task {
        do {
            let message = try await repository.sendTextMessage(text: text)
            messages.append(message)
        } catch {
            self.error = error as? ChatError ?? .unknown(error)
        }
    }
}
```

---

### 5. MessageActionHandler.swift - 默认参数 Actor 隔离

**问题**：在 nonisolated 的 init 中使用默认参数访问 `@MainActor` 隔离的 `.shared` 单例

**修复**：移除默认参数，要求显式传递依赖
```swift
// 修复前
init(player: AudioPlaybackService = VoicePlaybackManager.shared)

// 修复后
init(player: AudioPlaybackService)
```

---

### 6. InputCoordinator.swift - 默认参数 Actor 隔离

**问题**：在 nonisolated 的 init 中使用默认参数访问 `@MainActor` 隔离的 `.shared` 单例

**修复**：移除所有默认参数，要求显式传递依赖
```swift
// 修复前
init(recorder: AudioRecordService = VoiceRecordManager.shared,
     player: AudioPlaybackService = VoicePlaybackManager.shared,
     photoPicker: PhotoPickerService = PhotoPickerManager.shared)

// 修复后
init(recorder: AudioRecordService,
     player: AudioPlaybackService,
     photoPicker: PhotoPickerService)
```

---

### 7. ChatViewModel.swift - 添加 PhotoPickerService 依赖

**问题**：ViewController 需要访问 `photoPickerService`，但 ViewModel 中未暴露

**修复**：
- 添加 `photoPickerService` 属性（internal）
- 更新 init 方法接受 `photoPickerService` 参数
- 更新 `AppDependencies.makeChatViewModel()` 传递依赖

---

### 8. VoiceChatViewController.swift - 更新依赖注入

**问题**：InputCoordinator 移除默认参数后，初始化调用缺少参数

**修复**：显式传递所有依赖
```swift
// 修复前
inputCoordinator = InputCoordinator()

// 修复后
inputCoordinator = InputCoordinator(
    recorder: viewModel.recordService,
    player: viewModel.playbackService,
    photoPicker: viewModel.photoPickerService
)
```

---

### 9. VideoCacheManager.swift - Actor Init 中访问属性

**问题**：在 actor 的 init 中直接访问 stored property `memoryWarningObserver` 会触发编译器警告

**修复**：使用延迟初始化
```swift
// 修复前
private init() {
    // ...
    memoryWarningObserver = NotificationCenter.default.addObserver(...)
}

// 修复后
private init() {
    // ...
    Task { @MainActor in
        await self.setupMemoryWarning()
    }
}

private func setupMemoryWarning() {
    memoryWarningObserver = NotificationCenter.default.addObserver(...)
}
```

---

## 修复总结

### 修复的文件
1. `VoiceIM/Managers/VideoCacheManager.swift`
2. `VoiceIM/Core/Repository/MessageRepository.swift`
3. `VoiceIM/Models/ChatMessage.swift`
4. `VoiceIM/Core/Storage/FileStorageManager.swift`
5. `VoiceIM/Core/ViewModel/ChatViewModel.swift`
6. `VoiceIM/Managers/MessageActionHandler.swift`
7. `VoiceIM/Managers/InputCoordinator.swift`
8. `VoiceIM/ViewControllers/VoiceChatViewController.swift`
9. `VoiceIM/Core/DependencyInjection/AppDependencies.swift`

### 修复的错误类型
- Actor 隔离违规：6 处
- Async/await 调用缺失：11 处
- Codable 与 actor 兼容性：3 处
- 默认参数 actor 隔离问题：2 处
- 依赖注入不完整：2 处

### 构建状态
✅ **BUILD SUCCEEDED**

---

## 下一步建议

虽然编译成功，但项目中仍存在其他问题（详见 `PROJECT_ISSUES.md`）：

### 高优先级（建议立即修复）
1. 数组访问边界检查（6 处）
2. Info.plist 缺失权限描述（3 个）
3. NotificationCenter 观察者泄漏（ImageCacheManager）
4. UIRequiredDeviceCapabilities 配置错误

### 中优先级
1. 文件操作错误处理
2. 音频操作错误回调
3. AVAudioRecorder/Player delegate 清理

### 架构改进
1. 缓存管理器代码去重（~300 行）
2. 依赖注入完全迁移
3. 测试覆盖补充（当前仅 8.5%）

详细的问题分析和修复建议请参考 `PROJECT_ISSUES.md`。
