# 文件组织优化方案

生成时间：2026-04-06

---

## 当前问题

**Managers/ 目录混乱**：混合了多种职责
- 缓存管理：ImageCacheManager, VideoCacheManager, VoiceCacheManager
- 音频服务：VoiceRecordManager, VoicePlaybackManager
- 视频播放：VideoPlayerManager
- 相册选择：PhotoPickerManager
- 业务逻辑：InputCoordinator, MessageActionHandler
- 数据源：MessageDataSource
- 预加载：MessagePreloader
- 键盘管理：KeyboardManager

---

## 优化后的目录结构

```
VoiceIM/
├── App/                              # 应用入口
│   ├── AppDelegate.swift
│   └── SceneDelegate.swift
│
├── Core/                             # 核心层（业务无关）
│   ├── DependencyInjection/
│   │   └── AppDependencies.swift
│   ├── Error/
│   │   ├── ChatError.swift
│   │   └── ErrorHandler.swift
│   ├── Logging/
│   │   └── Logger.swift
│   ├── Repository/
│   │   └── MessageRepository.swift
│   ├── Storage/
│   │   ├── FileStorageManager.swift
│   │   └── MessageStorage.swift
│   └── ViewModel/
│       └── ChatViewModel.swift
│
├── Services/                         # 服务层（可复用）
│   ├── Audio/
│   │   ├── VoiceRecordManager.swift
│   │   ├── VoicePlaybackManager.swift
│   │   └── VoiceCacheManager.swift
│   ├── Cache/
│   │   ├── ImageCacheManager.swift
│   │   ├── VideoCacheManager.swift
│   │   └── MessagePreloader.swift
│   ├── Media/
│   │   ├── PhotoPickerManager.swift
│   │   └── VideoPlayerManager.swift
│   └── UI/
│       └── KeyboardManager.swift
│
├── Coordinators/                     # 协调器（业务逻辑）
│   ├── InputCoordinator.swift
│   └── MessageActionHandler.swift
│
├── DataSources/                      # 数据源
│   └── MessageDataSource.swift
│
├── ViewControllers/                  # 视图控制器
│   ├── VoiceChatViewController.swift
│   ├── ImagePreviewViewController.swift
│   ├── VideoPreviewViewController.swift
│   └── RecordingOverlayViewController.swift
│
├── Views/                            # 自定义视图
│   ├── ChatInputView.swift
│   ├── WaveformProgressView.swift
│   ├── VideoPlayerView.swift
│   ├── RecordingOverlayView.swift
│   ├── ToastView.swift
│   └── AvatarView.swift
│
├── Cells/                            # 列表 Cell
│   ├── ChatBubbleCell.swift
│   ├── TextMessageCell.swift
│   ├── VoiceMessageCell.swift
│   ├── ImageMessageCell.swift
│   ├── VideoMessageCell.swift
│   ├── LocationMessageCell.swift
│   └── RecalledMessageCell.swift
│
├── ViewModels/                       # Cell ViewModel
│   └── MessageCellViewModel.swift
│
├── Models/                           # 数据模型
│   ├── ChatMessage.swift
│   └── Sender.swift
│
├── Protocols/                        # 协议定义
│   ├── AudioServices.swift
│   ├── StorageProtocols.swift
│   ├── MessageCellConfigurable.swift
│   └── MessageCellInteractive.swift
│
├── Utilities/                        # 工具类
│   └── CacheUtilities.swift
│
└── Transitions/                      # 转场动画
    ├── ZoomTransitionController.swift
    └── ZoomTransition+UIViewController.swift
```

---

## 文件移动清单

### 从 Managers/ 移动到 Services/Audio/
- [x] VoiceRecordManager.swift
- [x] VoicePlaybackManager.swift
- [x] VoiceCacheManager.swift

### 从 Managers/ 移动到 Services/Cache/
- [x] ImageCacheManager.swift
- [x] VideoCacheManager.swift
- [x] MessagePreloader.swift

### 从 Managers/ 移动到 Services/Media/
- [x] PhotoPickerManager.swift
- [x] VideoPlayerManager.swift

### 从 Managers/ 移动到 Services/UI/
- [x] KeyboardManager.swift

### 从 Managers/ 移动到 Coordinators/
- [x] InputCoordinator.swift
- [x] MessageActionHandler.swift

### 从 Managers/ 移动到 DataSources/
- [x] MessageDataSource.swift

---

## 实施步骤

### 方案 A：使用 Git 移动（推荐）
保留文件历史记录

```bash
# 1. 创建新目录
mkdir -p VoiceIM/Services/{Audio,Cache,Media,UI}
mkdir -p VoiceIM/Coordinators
mkdir -p VoiceIM/DataSources

# 2. 使用 git mv 移动文件
git mv VoiceIM/Managers/VoiceRecordManager.swift VoiceIM/Services/Audio/
git mv VoiceIM/Managers/VoicePlaybackManager.swift VoiceIM/Services/Audio/
git mv VoiceIM/Managers/VoiceCacheManager.swift VoiceIM/Services/Audio/

git mv VoiceIM/Managers/ImageCacheManager.swift VoiceIM/Services/Cache/
git mv VoiceIM/Managers/VideoCacheManager.swift VoiceIM/Services/Cache/
git mv VoiceIM/Managers/MessagePreloader.swift VoiceIM/Services/Cache/

git mv VoiceIM/Managers/PhotoPickerManager.swift VoiceIM/Services/Media/
git mv VoiceIM/Managers/VideoPlayerManager.swift VoiceIM/Services/Media/

git mv VoiceIM/Managers/KeyboardManager.swift VoiceIM/Services/UI/

git mv VoiceIM/Managers/InputCoordinator.swift VoiceIM/Coordinators/
git mv VoiceIM/Managers/MessageActionHandler.swift VoiceIM/Coordinators/

git mv VoiceIM/Managers/MessageDataSource.swift VoiceIM/DataSources/

# 3. 删除空的 Managers 目录
rmdir VoiceIM/Managers

# 4. 重新生成 Xcode 工程
xcodegen generate

# 5. 编译验证
xcodebuild -project VoiceIM.xcodeproj -scheme VoiceIM build
```

### 方案 B：仅更新 project.yml
不移动物理文件，只在 Xcode 中重新组织

---

## 优势

### 1. 清晰的职责分离
- **Services/**：可复用的服务层
- **Coordinators/**：业务逻辑协调
- **DataSources/**：数据源管理

### 2. 更好的可维护性
- 按功能分组，易于查找
- 新功能知道放在哪里

### 3. 更好的可测试性
- Services 可以独立测试
- Coordinators 可以 mock Services

### 4. 符合架构最佳实践
- 分层清晰
- 依赖方向明确

---

## 影响评估

### 文件数量
- 移动文件：13 个
- 创建目录：7 个
- 删除目录：1 个

### 编译影响
- ✅ 不影响编译（Xcode 自动处理导入）
- ✅ 不需要修改代码
- ✅ 仅需重新生成工程

### Git 历史
- ✅ 使用 `git mv` 保留历史
- ✅ 可以追溯文件变更

---

## 风险与缓解

### 风险 1：导入路径变化
**缓解**：Xcode 使用模块导入，不依赖文件路径

### 风险 2：团队协作冲突
**缓解**：在独立分支完成，合并前通知团队

### 风险 3：CI/CD 构建失败
**缓解**：重新生成工程后立即验证编译

---

## 预计时间

- 创建目录：5 分钟
- 移动文件：10 分钟
- 重新生成工程：2 分钟
- 编译验证：3 分钟
- 提交代码：5 分钟

**总计**：约 25 分钟

---

## 建议

**立即执行**：这是一个低风险、高收益的重构
- ✅ 不修改代码逻辑
- ✅ 不影响功能
- ✅ 显著提升代码组织
- ✅ 为未来开发奠定基础

---

## 后续优化

完成文件组织后，可以进一步：
1. 为每个 Service 创建协议
2. 统一命名规范
3. 补充单元测试
4. 完善文档注释
