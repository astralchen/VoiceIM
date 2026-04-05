# InputCoordinator 依赖倒置改进方案讨论

## 当前问题分析

### 现状代码
```swift
@MainActor
final class InputCoordinator {
    private let recorder: VoiceRecordManager
    private let player: VoicePlaybackManager
    
    init(recorder: VoiceRecordManager = .shared,
         player: VoicePlaybackManager = .shared) {
        self.recorder = recorder
        self.player = player
    }
}
```

### 问题点

1. **依赖具体类**：依赖 `VoiceRecordManager` 和 `VoicePlaybackManager` 具体实现
2. **难以测试**：无法 mock 录音器和播放器进行单元测试
3. **耦合度高**：更换实现需要修改 `InputCoordinator` 代码
4. **违反 DIP**：高层模块（InputCoordinator）依赖低层模块（具体的 Manager）

---

## 改进方案对比

### 方案 1：协议抽象（推荐）⭐⭐⭐⭐⭐

#### 设计思路
定义协议，让 `InputCoordinator` 依赖协议而非具体类。

#### 实现代码

```swift
// MARK: - 协议定义

/// 音频录制服务协议
@MainActor
protocol AudioRecordService {
    var isRecording: Bool { get }
    var currentTime: TimeInterval { get }
    var normalizedPowerLevel: Float { get }
    
    func requestPermission() async -> Bool
    func startRecording() throws -> URL
    func stopRecording() -> URL?
    func cancelRecording()
}

/// 音频播放服务协议
@MainActor
protocol AudioPlaybackService {
    var playingID: UUID? { get }
    
    func stopCurrent()
    func isPlaying(id: UUID) -> Bool
}

// MARK: - 现有类实现协议

extension VoiceRecordManager: AudioRecordService {
    // 已有的方法自动满足协议要求
}

extension VoicePlaybackManager: AudioPlaybackService {
    // 已有的方法自动满足协议要求
}

// MARK: - InputCoordinator 改进

@MainActor
final class InputCoordinator {
    
    // 依赖协议，不依赖具体类
    private let recorder: AudioRecordService
    private let player: AudioPlaybackService
    
    // 构造器注入（移除默认值）
    init(recorder: AudioRecordService,
         player: AudioPlaybackService) {
        self.recorder = recorder
        self.player = player
    }
    
    // 使用方式不变
    private func beginRecording() {
        Task { @MainActor in
            let granted = await self.recorder.requestPermission()
            guard granted else {
                self.showToast?("请在设置中开启麦克风权限")
                return
            }
            // ...
        }
    }
}

// MARK: - ViewController 使用

class VoiceChatViewController: UIViewController {
    
    private lazy var inputCoordinator = InputCoordinator(
        recorder: VoiceRecordManager.shared,  // 注入具体实现
        player: VoicePlaybackManager.shared
    )
}
```

#### 优点
- ✅ 符合依赖倒置原则
- ✅ 易于单元测试（可以 mock）
- ✅ 易于替换实现
- ✅ 代码改动最小
- ✅ 类型安全

#### 缺点
- ⚠️ 需要定义协议（增加代码量）
- ⚠️ 需要修改 ViewController 的初始化代码

#### 测试示例
```swift
// Mock 实现
@MainActor
final class MockRecordService: AudioRecordService {
    var isRecording = false
    var currentTime: TimeInterval = 0
    var normalizedPowerLevel: Float = 0.5
    var shouldGrantPermission = true
    
    func requestPermission() async -> Bool {
        return shouldGrantPermission
    }
    
    func startRecording() throws -> URL {
        isRecording = true
        return URL(fileURLWithPath: "/tmp/test.m4a")
    }
    
    func stopRecording() -> URL? {
        isRecording = false
        return URL(fileURLWithPath: "/tmp/test.m4a")
    }
    
    func cancelRecording() {
        isRecording = false
    }
}

// 单元测试
class InputCoordinatorTests: XCTestCase {
    
    @MainActor
    func testRecordingPermissionDenied() async {
        let mockRecorder = MockRecordService()
        mockRecorder.shouldGrantPermission = false
        
        let coordinator = InputCoordinator(
            recorder: mockRecorder,
            player: MockPlaybackService()
        )
        
        var toastMessage: String?
        coordinator.showToast = { message in
            toastMessage = message
        }
        
        // 模拟开始录音
        // ...
        
        XCTAssertEqual(toastMessage, "请在设置中开启麦克风权限")
        XCTAssertFalse(mockRecorder.isRecording)
    }
}
```

---

### 方案 2：闭包注入（轻量级）⭐⭐⭐⭐

#### 设计思路
不定义协议，直接注入闭包函数。

#### 实现代码

```swift
@MainActor
final class InputCoordinator {
    
    // MARK: - 依赖闭包
    
    var requestRecordPermission: () async -> Bool
    var startRecording: () throws -> URL
    var stopRecording: () -> URL?
    var cancelRecording: () -> Void
    var isRecording: () -> Bool
    var currentRecordTime: () -> TimeInterval
    var normalizedPowerLevel: () -> Float
    
    var stopPlayback: () -> Void
    
    // MARK: - Init
    
    init(
        requestRecordPermission: @escaping () async -> Bool,
        startRecording: @escaping () throws -> URL,
        stopRecording: @escaping () -> URL?,
        cancelRecording: @escaping () -> Void,
        isRecording: @escaping () -> Bool,
        currentRecordTime: @escaping () -> TimeInterval,
        normalizedPowerLevel: @escaping () -> Float,
        stopPlayback: @escaping () -> Void
    ) {
        self.requestRecordPermission = requestRecordPermission
        self.startRecording = startRecording
        self.stopRecording = stopRecording
        self.cancelRecording = cancelRecording
        self.isRecording = isRecording
        self.currentRecordTime = currentRecordTime
        self.normalizedPowerLevel = normalizedPowerLevel
        self.stopPlayback = stopPlayback
    }
    
    // 使用
    private func beginRecording() {
        guard !isRecording() else { return }
        
        Task { @MainActor in
            let granted = await requestRecordPermission()
            guard granted else {
                showToast?("请在设置中开启麦克风权限")
                return
            }
            // ...
        }
    }
}

// MARK: - ViewController 使用

class VoiceChatViewController: UIViewController {
    
    private lazy var inputCoordinator: InputCoordinator = {
        let recorder = VoiceRecordManager.shared
        let player = VoicePlaybackManager.shared
        
        return InputCoordinator(
            requestRecordPermission: { await recorder.requestPermission() },
            startRecording: { try recorder.startRecording() },
            stopRecording: { recorder.stopRecording() },
            cancelRecording: { recorder.cancelRecording() },
            isRecording: { recorder.isRecording },
            currentRecordTime: { recorder.currentTime },
            normalizedPowerLevel: { recorder.normalizedPowerLevel },
            stopPlayback: { player.stopCurrent() }
        )
    }()
}
```

#### 优点
- ✅ 无需定义协议
- ✅ 灵活性高
- ✅ 易于测试

#### 缺点
- ❌ 构造器参数过多（8 个）
- ❌ 类型安全性较差
- ❌ 初始化代码冗长
- ❌ 容易出错（参数顺序）

---

### 方案 3：依赖注入容器（企业级）⭐⭐⭐

#### 设计思路
使用依赖注入容器统一管理所有依赖。

#### 实现代码

```swift
// MARK: - 依赖容器

@MainActor
final class AppDependencies {
    
    // 单例服务
    let recordService: AudioRecordService
    let playbackService: AudioPlaybackService
    let cacheService: VoiceCacheManager
    
    init() {
        self.recordService = VoiceRecordManager.shared
        self.playbackService = VoicePlaybackManager.shared
        self.cacheService = VoiceCacheManager.shared
    }
    
    // 工厂方法
    func makeInputCoordinator() -> InputCoordinator {
        return InputCoordinator(
            recorder: recordService,
            player: playbackService
        )
    }
    
    func makeVoiceChatViewController() -> VoiceChatViewController {
        return VoiceChatViewController(dependencies: self)
    }
}

// MARK: - ViewController 改进

class VoiceChatViewController: UIViewController {
    
    private let dependencies: AppDependencies
    private lazy var inputCoordinator = dependencies.makeInputCoordinator()
    
    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("Use init(dependencies:)")
    }
}

// MARK: - SceneDelegate 使用

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    
    var window: UIWindow?
    let dependencies = AppDependencies()
    
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, ...) {
        guard let windowScene = scene as? UIWindowScene else { return }
        
        let window = UIWindow(windowScene: windowScene)
        let vc = dependencies.makeVoiceChatViewController()
        window.rootViewController = vc
        window.makeKeyAndVisible()
        self.window = window
    }
}
```

#### 优点
- ✅ 集中管理依赖
- ✅ 易于切换环境（开发/测试/生产）
- ✅ 符合企业级架构
- ✅ 易于维护

#### 缺点
- ❌ 增加复杂度
- ❌ 对小项目过度设计
- ❌ 需要修改 SceneDelegate

---

### 方案 4：保持现状 + 改进测试（务实）⭐⭐⭐⭐

#### 设计思路
保持单例，但通过协议 + 默认参数支持测试。

#### 实现代码

```swift
// MARK: - 协议定义（同方案 1）

@MainActor
protocol AudioRecordService { ... }

@MainActor
protocol AudioPlaybackService { ... }

extension VoiceRecordManager: AudioRecordService { }
extension VoicePlaybackManager: AudioPlaybackService { }

// MARK: - InputCoordinator 改进

@MainActor
final class InputCoordinator {
    
    private let recorder: AudioRecordService
    private let player: AudioPlaybackService
    
    // 默认使用单例，测试时可注入 mock
    init(recorder: AudioRecordService = VoiceRecordManager.shared,
         player: AudioPlaybackService = VoicePlaybackManager.shared) {
        self.recorder = recorder
        self.player = player
    }
}

// MARK: - 生产环境使用（无需改动）

class VoiceChatViewController: UIViewController {
    
    // 使用默认参数，代码不变
    private lazy var inputCoordinator = InputCoordinator()
}

// MARK: - 测试环境使用

class InputCoordinatorTests: XCTestCase {
    
    @MainActor
    func testRecording() {
        let mockRecorder = MockRecordService()
        let mockPlayer = MockPlaybackService()
        
        // 注入 mock
        let coordinator = InputCoordinator(
            recorder: mockRecorder,
            player: mockPlayer
        )
        
        // 测试逻辑
    }
}
```

#### 优点
- ✅ 生产代码无需改动
- ✅ 支持单元测试
- ✅ 改动最小
- ✅ 务实平衡

#### 缺点
- ⚠️ 仍然依赖单例（但可测试）
- ⚠️ 需要定义协议

---

## 方案对比总结

| 方案 | 复杂度 | 可测试性 | 代码改动 | 适用场景 | 推荐度 |
|------|--------|----------|----------|----------|--------|
| 方案 1：协议抽象 | 中 | ⭐⭐⭐⭐⭐ | 中 | 中大型项目 | ⭐⭐⭐⭐⭐ |
| 方案 2：闭包注入 | 低 | ⭐⭐⭐⭐ | 大 | 小型项目 | ⭐⭐⭐⭐ |
| 方案 3：DI 容器 | 高 | ⭐⭐⭐⭐⭐ | 大 | 企业级项目 | ⭐⭐⭐ |
| 方案 4：保持现状 + 改进 | 低 | ⭐⭐⭐⭐ | 小 | 当前项目 | ⭐⭐⭐⭐ |

---

## 推荐方案

### 🏆 最佳选择：方案 4（保持现状 + 改进测试）

**理由**：
1. ✅ 代码改动最小（只需定义协议 + extension）
2. ✅ 生产代码无需修改（使用默认参数）
3. ✅ 支持单元测试（可注入 mock）
4. ✅ 符合依赖倒置原则
5. ✅ 务实平衡（不过度设计）

**实施步骤**：

#### 步骤 1：定义协议（新建文件）

```swift
// AudioServices.swift

import Foundation
import AVFoundation

@MainActor
protocol AudioRecordService {
    var isRecording: Bool { get }
    var currentTime: TimeInterval { get }
    var normalizedPowerLevel: Float { get }
    
    func requestPermission() async -> Bool
    func startRecording() throws -> URL
    func stopRecording() -> URL?
    func cancelRecording()
}

@MainActor
protocol AudioPlaybackService {
    var playingID: UUID? { get }
    
    func stopCurrent()
    func isPlaying(id: UUID) -> Bool
}
```

#### 步骤 2：现有类实现协议

```swift
// VoiceRecordManager.swift
extension VoiceRecordManager: AudioRecordService {
    // 已有方法自动满足协议
}

// VoicePlaybackManager.swift
extension VoicePlaybackManager: AudioPlaybackService {
    // 已有方法自动满足协议
}
```

#### 步骤 3：修改 InputCoordinator

```swift
// InputCoordinator.swift

@MainActor
final class InputCoordinator {
    
    // 依赖协议
    private let recorder: AudioRecordService
    private let player: AudioPlaybackService
    
    // 默认参数保持向后兼容
    init(recorder: AudioRecordService = VoiceRecordManager.shared,
         player: AudioPlaybackService = VoicePlaybackManager.shared) {
        self.recorder = recorder
        self.player = player
    }
    
    // 其他代码不变
}
```

#### 步骤 4：添加单元测试（可选）

```swift
// InputCoordinatorTests.swift

@testable import VoiceIM
import XCTest

@MainActor
final class MockRecordService: AudioRecordService {
    var isRecording = false
    var currentTime: TimeInterval = 0
    var normalizedPowerLevel: Float = 0.5
    var shouldGrantPermission = true
    
    func requestPermission() async -> Bool {
        return shouldGrantPermission
    }
    
    func startRecording() throws -> URL {
        isRecording = true
        return URL(fileURLWithPath: "/tmp/test.m4a")
    }
    
    func stopRecording() -> URL? {
        isRecording = false
        return URL(fileURLWithPath: "/tmp/test.m4a")
    }
    
    func cancelRecording() {
        isRecording = false
    }
}

@MainActor
final class MockPlaybackService: AudioPlaybackService {
    var playingID: UUID?
    
    func stopCurrent() {
        playingID = nil
    }
    
    func isPlaying(id: UUID) -> Bool {
        return playingID == id
    }
}

final class InputCoordinatorTests: XCTestCase {
    
    @MainActor
    func testRecordingPermissionDenied() async {
        let mockRecorder = MockRecordService()
        mockRecorder.shouldGrantPermission = false
        
        let coordinator = InputCoordinator(
            recorder: mockRecorder,
            player: MockPlaybackService()
        )
        
        var toastMessage: String?
        coordinator.showToast = { message in
            toastMessage = message
        }
        
        // 测试逻辑
        // ...
        
        XCTAssertEqual(toastMessage, "请在设置中开启麦克风权限")
        XCTAssertFalse(mockRecorder.isRecording)
    }
}
```

---

## 其他需要改进的地方

### 1. MessageActionHandler

```swift
// 当前
final class MessageActionHandler {
    private let player: VoicePlaybackManager
    
    init(player: VoicePlaybackManager = .shared) {
        self.player = player
    }
}

// 改进
final class MessageActionHandler {
    private let player: AudioPlaybackService
    
    init(player: AudioPlaybackService = VoicePlaybackManager.shared) {
        self.player = player
    }
}
```

### 2. VoiceChatViewController

```swift
// 当前
final class VoiceChatViewController: UIViewController {
    private let player = VoicePlaybackManager.shared
}

// 改进
final class VoiceChatViewController: UIViewController {
    private let player: AudioPlaybackService
    
    init(player: AudioPlaybackService = VoicePlaybackManager.shared) {
        self.player = player
        super.init(nibName: nil, bundle: nil)
    }
}
```

---

## 总结

### 核心原则

> **依赖抽象，不依赖具体**

### 实施建议

1. **短期（1 周）**：实施方案 4
   - 定义协议
   - 添加 extension
   - 修改构造器（保留默认参数）

2. **中期（1 个月）**：添加单元测试
   - 创建 Mock 实现
   - 编写测试用例
   - 提高测试覆盖率

3. **长期（3 个月）**：考虑方案 3
   - 当项目规模增长时
   - 引入依赖注入容器
   - 统一管理依赖

### 关键收获

- ✅ 协议抽象是最佳平衡点
- ✅ 默认参数保持向后兼容
- ✅ 单元测试是改进的主要动力
- ✅ 不要过度设计，务实为先

---

## 需要我帮你实施吗？

如果你想实施方案 4，我可以帮你：
1. 创建 `AudioServices.swift` 协议文件
2. 修改 `InputCoordinator.swift`
3. 添加协议实现的 extension
4. 创建测试文件模板

要开始吗？
