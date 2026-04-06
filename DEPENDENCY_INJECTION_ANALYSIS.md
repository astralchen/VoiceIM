# 依赖注入迁移分析报告

生成时间：2026-04-06

---

## 📊 当前状态

### ✅ 系统单例（不需要迁移）

这些是 iOS 系统提供的单例，无需迁移：
- `AVAudioSession.sharedInstance()`
- `UIApplication.shared`
- `URLSession.shared`
- `FileManager.default`

### ❌ 需要迁移的单例

共发现 **40 处**使用自定义单例的地方。

---

## 🔍 详细分析

### 1. AppDependencies.swift（7 处）

**问题**：依赖注入容器内部仍使用 `.shared` 单例

**位置**：
- 第 85 行：`ErrorHandler.shared`
- 第 86 行：`MessageStorage.shared`
- 第 87 行：`FileStorageManager.shared`
- 第 90 行：`VoiceRecordManager.shared`
- 第 91 行：`VoicePlaybackManager.shared`
- 第 92 行：`VoiceCacheManager.shared`
- 第 95 行：`PhotoPickerManager.shared`

**影响**：
- 这是设计问题：依赖注入容器本身依赖单例
- 导致无法在测试中替换这些依赖
- 违反了依赖注入的初衷

**建议方案**：
```swift
// 方案 1：完全移除 .shared，在 AppDependencies 中创建实例
private init() {
    // 创建新实例而非使用单例
    self.logger = CompositeLogger(...)
    self.errorHandler = ErrorHandler()
    self.messageStorage = MessageStorage()
    self.fileStorageManager = FileStorageManager()
    self.recordService = VoiceRecordManager()
    self.playbackService = VoicePlaybackManager()
    self.cacheService = VoiceCacheManager()
    self.photoPickerService = PhotoPickerManager()
}

// 方案 2：保留 .shared 但添加测试初始化方法
#if DEBUG
static func makeForTesting(
    errorHandler: ErrorHandler? = nil,
    messageStorage: MessageStorage? = nil,
    // ... 其他参数
) -> AppDependencies {
    let deps = AppDependencies()
    // 使用反射或其他方式替换依赖
    return deps
}
#endif
```

**优先级**：🟡 低（当前设计可接受，但不利于测试）

---

### 2. VoiceChatViewController.swift（6 处）

**问题**：混用依赖注入和直接访问单例

**位置**：
- 第 26 行：`MessagePreloader.shared`
- 第 189 行：`ErrorHandler.shared`
- 第 541 行：`ImageCacheManager.shared.resolveImageURL()`
- 第 555 行：`ImageCacheManager.shared.cachedImage()`
- 第 562 行：`ImageCacheManager.shared.loadImage()`
- 第 645 行：`VideoCacheManager.shared.resolveVideoURL()`

**影响**：
- 部分依赖通过 ViewModel 注入，部分直接访问
- 架构不一致，难以测试

**建议方案**：
```swift
// 在 ChatViewModel 中添加这些服务
@MainActor
final class ChatViewModel: ObservableObject {
    let playbackService: AudioPlaybackService
    let recordService: AudioRecordService
    let photoPickerService: PhotoPickerService
    let imageCacheService: ImageCacheManager  // 添加
    let videoCacheService: VideoCacheManager  // 添加
    let errorHandler: ErrorHandler  // 添加
    let messagePreloader: MessagePreloader  // 添加
}

// 在 VoiceChatViewController 中通过 viewModel 访问
let resolvedURL = viewModel.imageCacheService.resolveImageURL(...)
viewModel.errorHandler.handle(error, in: self)
```

**优先级**：🟠 中（影响架构一致性）

---

### 3. MessageRepository.swift（4 处）

**问题**：
1. 默认参数使用 `.shared`（第 25-26 行）
2. 直接调用 `ImageCacheManager.shared`（第 109 行）
3. 直接调用 `VideoCacheManager.shared`（第 140 行）

**位置**：
```swift
// 第 25-26 行
init(
    storage: MessageStorage = .shared,  // ❌
    fileStorage: FileStorageManager = .shared,  // ❌
    logger: Logger = VoiceIM.logger
)

// 第 109 行
let cacheURL = try await ImageCacheManager.shared.saveAndCacheImage(from: tempURL)

// 第 140 行
let cacheURL = try await VideoCacheManager.shared.saveAndCacheVideo(from: tempURL)
```

**影响**：
- 默认参数虽然在 AppDependencies 中被覆盖，但仍存在
- 直接调用缓存管理器，无法注入

**建议方案**：
```swift
// 1. 移除默认参数
init(
    storage: MessageStorage,
    fileStorage: FileStorageManager,
    imageCacheService: ImageCacheManager,  // 添加
    videoCacheService: VideoCacheManager,  // 添加
    logger: Logger
)

// 2. 使用注入的服务
let cacheURL = try await imageCacheService.saveAndCacheImage(from: tempURL)
let cacheURL = try await videoCacheService.saveAndCacheVideo(from: tempURL)
```

**优先级**：🟠 中（影响可测试性）

---

### 4. MessagePreloader.swift（2 处）

**问题**：直接使用缓存管理器单例

**位置**：
- 第 139 行：`ImageCacheManager.shared.preloadImage()`
- 第 148 行：`VideoCacheManager.shared.loadThumbnail()`

**影响**：
- MessagePreloader 本身是单例，又依赖其他单例
- 无法测试预加载逻辑

**建议方案**：
```swift
@MainActor
final class MessagePreloader {
    private let imageCacheService: ImageCacheManager
    private let videoCacheService: VideoCacheManager
    
    init(
        imageCacheService: ImageCacheManager,
        videoCacheService: VideoCacheManager
    ) {
        self.imageCacheService = imageCacheService
        self.videoCacheService = videoCacheService
    }
    
    // 使用注入的服务
    imageCacheService.preloadImage(from: imageURL, targetSize: targetSize)
    _ = await videoCacheService.loadThumbnail(from: videoURL)
}
```

**优先级**：🟡 低（预加载是辅助功能）

---

### 5. VideoMessageCell.swift（3 处）

**问题**：Cell 中直接使用 `VideoCacheManager.shared`

**位置**：
- 第 157 行：`VideoCacheManager.shared.cachedThumbnail()`
- 第 168 行：`VideoCacheManager.shared.loadThumbnail()`
- 第 210 行：`VideoCacheManager.shared.resolveVideoURL()`

**影响**：
- Cell 应该是纯 UI 组件，不应直接依赖服务
- 无法测试 Cell 的缓存逻辑

**建议方案**：
```swift
// 通过 MessageCellDependencies 注入
struct MessageCellDependencies {
    let isPlaying: (UUID) -> Bool
    let currentProgress: (UUID) -> Float
    let imageCacheService: ImageCacheManager  // 添加
    let videoCacheService: VideoCacheManager  // 添加
    // ...
}

// 在 Cell 中使用
if let cached = deps.videoCacheService.cachedThumbnail(for: url) {
    // ...
}
```

**优先级**：🟠 中（影响架构清晰度）

---

### 6. ImageMessageCell.swift（3 处）

**问题**：Cell 中直接使用 `ImageCacheManager.shared`

**位置**：
- 第 136 行：`ImageCacheManager.shared.cachedImage()`
- 第 151 行：`ImageCacheManager.shared.loadImage()`
- 第 305 行：`ImageCacheManager.shared.resolveImageURL()`

**影响**：同 VideoMessageCell

**建议方案**：同 VideoMessageCell

**优先级**：🟠 中（影响架构清晰度）

---

## 📊 统计总结

| 文件 | .shared 使用次数 | 优先级 |
|------|-----------------|--------|
| AppDependencies.swift | 7 | 🟡 低 |
| VoiceChatViewController.swift | 6 | 🟠 中 |
| MessageRepository.swift | 4 | 🟠 中 |
| VideoMessageCell.swift | 3 | 🟠 中 |
| ImageMessageCell.swift | 3 | 🟠 中 |
| MessagePreloader.swift | 2 | 🟡 低 |
| **总计** | **25** | - |

---

## 🎯 迁移建议

### 立即修复（高优先级）

**无**。当前的单例使用不会导致运行时问题。

### 近期改进（中优先级）

1. **MessageRepository 依赖注入**（2-3 小时）
   - 移除默认参数
   - 注入 ImageCacheManager 和 VideoCacheManager
   - 更新 AppDependencies

2. **Cell 依赖注入**（3-4 小时）
   - 扩展 MessageCellDependencies
   - 在 VoiceChatViewController 中传递缓存服务
   - 更新所有 Cell 使用注入的服务

3. **VoiceChatViewController 统一依赖访问**（2-3 小时）
   - 通过 ViewModel 访问所有服务
   - 移除直接的 .shared 调用

### 长期改进（低优先级）

4. **AppDependencies 重构**（4-6 小时）
   - 移除内部的 .shared 使用
   - 创建真正的依赖注入容器
   - 添加测试支持

5. **MessagePreloader 依赖注入**（1-2 小时）
   - 注入缓存服务
   - 更新初始化逻辑

---

## 💡 设计建议

### 当前设计的优缺点

**优点**：
- ✅ 简单直接，易于理解
- ✅ 不需要大量的依赖传递
- ✅ 对于单例服务（如缓存）来说是合理的

**缺点**：
- ❌ 难以测试（无法 mock 依赖）
- ❌ 架构不一致（混用注入和直接访问）
- ❌ 依赖关系不明确

### 推荐的折中方案

**保留部分单例，但通过依赖注入访问**：

```swift
// 1. 保留 .shared 单例（向后兼容）
@MainActor
final class ImageCacheManager {
    static let shared = ImageCacheManager()
    
    private init() { }
}

// 2. 通过依赖注入访问
@MainActor
final class AppDependencies {
    let imageCacheService: ImageCacheManager
    
    private init() {
        // 使用单例，但通过属性暴露
        self.imageCacheService = ImageCacheManager.shared
    }
}

// 3. 在代码中通过依赖访问，而非直接 .shared
let image = await viewModel.imageCacheService.loadImage(...)
```

**好处**：
- ✅ 保留单例的简单性
- ✅ 通过依赖注入提高可测试性
- ✅ 架构更清晰一致
- ✅ 可以在测试中替换依赖

---

## 🚀 实施计划

### 阶段 1：MessageRepository（预计 2-3 小时）
1. 添加 imageCacheService 和 videoCacheService 参数
2. 移除默认参数
3. 更新 AppDependencies
4. 验证编译和运行

### 阶段 2：Cell 依赖注入（预计 3-4 小时）
1. 扩展 MessageCellDependencies
2. 更新 ImageMessageCell 和 VideoMessageCell
3. 在 VoiceChatViewController 中传递依赖
4. 验证功能正常

### 阶段 3：ViewController 统一（预计 2-3 小时）
1. 在 ChatViewModel 中添加缺失的服务
2. 更新 VoiceChatViewController 使用 viewModel
3. 移除直接的 .shared 调用
4. 验证功能正常

**总预计时间**：7-10 小时

---

## 📝 结论

当前的依赖注入迁移**部分完成**：

- ✅ 核心服务（录音、播放、相册）已通过 ViewModel 注入
- ✅ AppDependencies 容器已建立
- ⚠️ 缓存服务仍大量使用 .shared
- ⚠️ Cell 和 ViewController 混用注入和直接访问

**建议**：
- 如果项目时间紧张，当前状态可接受（不影响功能）
- 如果追求架构完整性，建议完成阶段 1-3 的迁移
- 阶段 4-5 可以作为长期优化目标

**优先级**：🟡 低到中（不影响功能，但影响代码质量和可测试性）
