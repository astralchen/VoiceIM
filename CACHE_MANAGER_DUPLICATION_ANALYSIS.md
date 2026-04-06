# 缓存管理器重复代码分析报告

生成时间：2026-04-06

---

## 概述

项目中有 3 个缓存管理器，存在大量重复代码：

| 文件 | 行数 | 职责 |
|------|------|------|
| ImageCacheManager.swift | 436 行 | 图片缓存（内存 + 磁盘 + 网络） |
| VideoCacheManager.swift | 387 行 | 视频缓存 + 缩略图缓存 |
| VoiceCacheManager.swift | 92 行 | 语音文件缓存 |
| **总计** | **915 行** | |

**估计重复代码**：约 300 行（33%）

---

## 重复代码详细分析

### 1. 稳定哈希算法（完全相同）

**ImageCacheManager.swift:381-392**
```swift
nonisolated func stableDiskFileName(for url: URL) -> String {
    if url.isFileURL {
        return url.lastPathComponent
    }
    let string = url.absoluteString
    var hash: UInt64 = 5381
    for byte in string.utf8 {
        hash = hash &* 127 &+ UInt64(byte)
    }
    let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
    return "\(hash).\(ext)"
}
```

**VideoCacheManager.swift:349-360**
```swift
nonisolated func stableDiskFileName(for url: URL) -> String {
    if url.isFileURL {
        return url.lastPathComponent
    }
    let string = url.absoluteString
    var hash: UInt64 = 5381
    for byte in string.utf8 {
        hash = hash &* 127 &+ UInt64(byte)
    }
    let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
    return "\(hash).\(ext)"
}
```

**重复度**：100%（仅默认扩展名不同）

---

### 2. 缓存目录初始化（完全相同）

**ImageCacheManager.swift:78-86**
```swift
guard let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
    fatalError("Failed to get caches directory")
}
diskCacheURL = cacheDir.appendingPathComponent("ImageCache", isDirectory: true)
do {
    try FileManager.default.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
} catch {
    print("Failed to create image cache directory: \(error)")
}
```

**VideoCacheManager.swift:50-62**
```swift
guard let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
    fatalError("Failed to get caches directory")
}
videoCacheURL = cacheDir.appendingPathComponent("VideoCache", isDirectory: true)
thumbnailCacheURL = cacheDir.appendingPathComponent("VideoThumbnailCache", isDirectory: true)

do {
    try FileManager.default.createDirectory(at: videoCacheURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: thumbnailCacheURL, withIntermediateDirectories: true)
} catch {
    print("Failed to create video cache directories: \(error)")
}
```

**VoiceCacheManager.swift:13-23**
```swift
guard let base = FileManager.default
    .urls(for: .cachesDirectory, in: .userDomainMask).first else {
    fatalError("Failed to get caches directory")
}
cacheDir = base.appendingPathComponent("IMVoiceCache", isDirectory: true)
do {
    try FileManager.default.createDirectory(
        at: cacheDir, withIntermediateDirectories: true)
} catch {
    print("Failed to create voice cache directory: \(error)")
}
```

**重复度**：95%（仅目录名不同）

---

### 3. 内存警告处理（完全相同）

**ImageCacheManager.swift:88-94**
```swift
memoryWarningObserver = NotificationCenter.default.addObserver(
    forName: UIApplication.didReceiveMemoryWarningNotification,
    object: nil,
    queue: .main
) { [weak self] _ in
    self?.clearMemoryCache()
}
```

**VideoCacheManager.swift:74-82**
```swift
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

**重复度**：90%（仅 actor 调用方式不同）

---

### 4. 并发去重机制（完全相同）

**ImageCacheManager.swift（inFlightLoads）**
```swift
// 检查是否已有进行中的任务
if let existingTask = inFlightLoads[url] {
    return try await existingTask.value
}

// 创建新任务
let task = Task<UIImage?, Error> {
    // ... 加载逻辑
}
inFlightLoads[url] = task

do {
    let result = try await task.value
    inFlightLoads.removeValue(forKey: url)
    return result
} catch {
    inFlightLoads.removeValue(forKey: url)
    throw error
}
```

**VideoCacheManager.swift（thumbnailTasks, downloadTasks）**
```swift
// 检查是否已有进行中的任务
if let existingTask = thumbnailTasks[videoURL] {
    return try await existingTask.value
}

// 创建新任务
let task = Task<UIImage?, Error> {
    // ... 生成逻辑
}
thumbnailTasks[videoURL] = task

do {
    let result = try await task.value
    thumbnailTasks.removeValue(forKey: videoURL)
    return result
} catch {
    thumbnailTasks.removeValue(forKey: videoURL)
    throw error
}
```

**VoiceCacheManager.swift（inFlight）**
```swift
// 检查是否已有进行中的任务
if let existing = inFlight[remoteURL] {
    return try await existing.value
}

// 创建新任务
let task = Task<URL, Error> {
    try await Self.download(from: remoteURL, to: destination)
}
inFlight[remoteURL] = task

do {
    let result = try await task.value
    inFlight.removeValue(forKey: remoteURL)
    return result
} catch {
    inFlight.removeValue(forKey: remoteURL)
    throw error
}
```

**重复度**：100%（完全相同的模式）

---

### 5. NSCache 配置（相似）

**ImageCacheManager.swift:72-76**
```swift
memoryCache.countLimit = 50
memoryCache.totalCostLimit = 50 * 1024 * 1024  // 50 MB

tempMemoryCache.countLimit = 10
tempMemoryCache.totalCostLimit = 20 * 1024 * 1024  // 20 MB
```

**VideoCacheManager.swift:45-47**
```swift
thumbnailCache.countLimit = 100  // 最多缓存 100 张缩略图
thumbnailCache.totalCostLimit = 20 * 1024 * 1024  // 最多 20MB
```

**重复度**：80%（配置逻辑相同，参数不同）

---

### 6. 磁盘清理逻辑（相似）

**ImageCacheManager.swift:399-409（DiskCacheActor）**
```swift
func clearDirectory(_ url: URL) {
    do {
        let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
        VoiceIM.logger.info("Cleared directory: \(url.lastPathComponent) (\(files.count) files)")
    } catch {
        VoiceIM.logger.error("Failed to clear directory: \(error)")
    }
}
```

**VideoCacheManager.swift（类似逻辑分散在多处）**

**重复度**：70%

---

## 重复代码统计

| 重复类型 | 重复次数 | 每次行数 | 总重复行数 |
|---------|---------|---------|-----------|
| 稳定哈希算法 | 2 | 12 | 24 |
| 缓存目录初始化 | 3 | 10 | 30 |
| 内存警告处理 | 2 | 10 | 20 |
| 并发去重机制 | 3 | 20 | 60 |
| NSCache 配置 | 2 | 5 | 10 |
| 磁盘清理逻辑 | 2 | 15 | 30 |
| deinit 清理 | 2 | 5 | 10 |
| **总计** | | | **~184 行** |

**实际重复更多**（包括相似但不完全相同的代码）：估计 **300+ 行**

---

## 问题影响

### 1. 维护成本高
- 修改一个 bug 需要在 3 个文件中重复修改
- 容易遗漏某个文件

### 2. 代码不一致
- VoiceCacheManager 使用 `hashValue`（不稳定）
- ImageCacheManager 和 VideoCacheManager 使用 djb2（稳定）
- 内存警告处理方式不同

### 3. 测试困难
- 相同逻辑需要重复测试
- 测试覆盖率低

### 4. 违反 DRY 原则
- Don't Repeat Yourself
- 重复代码占比 33%

---

## 重构建议

### 方案 1：提取通用基类（不推荐）

```swift
class BaseCacheManager {
    let cacheDirectory: URL
    var memoryWarningObserver: NSObjectProtocol?
    
    init(subdirectory: String) {
        // 通用初始化逻辑
    }
    
    func stableDiskFileName(for url: URL, defaultExtension: String) -> String {
        // djb2 哈希算法
    }
}

class ImageCacheManager: BaseCacheManager {
    // 图片特定逻辑
}
```

**缺点**：
- Swift 不推荐继承
- actor 不能继承
- 破坏封装性

---

### 方案 2：提取通用工具类（推荐）

```swift
// 1. 缓存目录管理器
struct CacheDirectoryManager {
    static func createCacheDirectory(named: String) throws -> URL {
        guard let cacheDir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw CacheError.directoryNotFound
        }
        let url = cacheDir.appendingPathComponent(named, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// 2. 稳定哈希工具
struct StableHash {
    static func djb2(_ string: String) -> UInt64 {
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = hash &* 127 &+ UInt64(byte)
        }
        return hash
    }
    
    static func fileName(for url: URL, defaultExtension: String) -> String {
        if url.isFileURL {
            return url.lastPathComponent
        }
        let hash = djb2(url.absoluteString)
        let ext = url.pathExtension.isEmpty ? defaultExtension : url.pathExtension
        return "\(hash).\(ext)"
    }
}

// 3. 并发去重管理器
actor TaskDeduplicator<Key: Hashable, Value> {
    private var inFlight: [Key: Task<Value, Error>] = [:]
    
    func deduplicate(key: Key, operation: @escaping () async throws -> Value) async throws -> Value {
        if let existing = inFlight[key] {
            return try await existing.value
        }
        
        let task = Task<Value, Error> {
            try await operation()
        }
        inFlight[key] = task
        
        do {
            let result = try await task.value
            inFlight.removeValue(forKey: key)
            return result
        } catch {
            inFlight.removeValue(forKey: key)
            throw error
        }
    }
}

// 4. 内存缓存包装器
@MainActor
class MemoryCacheWrapper<Key: Hashable, Value: AnyObject> {
    private let cache = NSCache<NSString, Value>()
    private var memoryWarningObserver: NSObjectProtocol?
    
    init(countLimit: Int, costLimit: Int) {
        cache.countLimit = countLimit
        cache.totalCostLimit = costLimit
        
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.cache.removeAllObjects()
        }
    }
    
    deinit {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    func get(_ key: Key) -> Value? {
        cache.object(forKey: String(describing: key) as NSString)
    }
    
    func set(_ value: Value, for key: Key, cost: Int = 0) {
        cache.setObject(value, forKey: String(describing: key) as NSString, cost: cost)
    }
    
    func clear() {
        cache.removeAllObjects()
    }
}
```

---

### 方案 3：使用协议 + 扩展（推荐）

```swift
protocol CacheManager {
    var cacheDirectory: URL { get }
    func stableDiskFileName(for url: URL) -> String
}

extension CacheManager {
    func stableDiskFileName(for url: URL, defaultExtension: String = "dat") -> String {
        if url.isFileURL {
            return url.lastPathComponent
        }
        let string = url.absoluteString
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = hash &* 127 &+ UInt64(byte)
        }
        let ext = url.pathExtension.isEmpty ? defaultExtension : url.pathExtension
        return "\(hash).\(ext)"
    }
}

// 使用
actor ImageCacheManager: CacheManager {
    let cacheDirectory: URL
    
    func fileName(for url: URL) -> String {
        stableDiskFileName(for: url, defaultExtension: "jpg")
    }
}
```

---

## 推荐实施方案

**阶段 1**：提取工具类（2-3 小时）
1. 创建 `CacheUtilities.swift`
2. 提取 `StableHash` 工具
3. 提取 `CacheDirectoryManager`
4. 更新 3 个缓存管理器使用工具类

**阶段 2**：提取并发去重（2-3 小时）
1. 创建 `TaskDeduplicator` actor
2. 更新 3 个缓存管理器使用去重器

**阶段 3**：提取内存缓存（1-2 小时）
1. 创建 `MemoryCacheWrapper`
2. 更新 ImageCacheManager 和 VideoCacheManager

**预计总时间**：5-8 小时

**预计减少代码**：200-250 行

---

## 总结

### 当前状态
- ❌ 重复代码约 300 行（33%）
- ❌ 维护成本高
- ❌ 代码不一致
- ❌ 违反 DRY 原则

### 重构后
- ✅ 减少 200-250 行重复代码
- ✅ 统一实现逻辑
- ✅ 提高可维护性
- ✅ 提高可测试性
- ✅ 符合 DRY 原则

### 优先级
🟡 **低到中**（不影响功能，但影响代码质量）

建议在有时间时进行重构，可以显著提升代码质量。
