# VoiceIM

iOS IM 应用完整实现，支持语音、文字、图片、视频消息，包含录制、发送、播放、进度控制、未读提醒、消息状态管理全流程。

## 功能特性

### 语音消息
- 长按"按住说话"开始录音，实时显示秒数
- 上滑进入取消状态，松手取消；下滑恢复正常录音
- 松手发送（< 1s 提示"说话时间太短"）
- 最长 30s，到达上限自动发送
- 点击播放，再次点击停止；同时只播放一条
- 可拖拽进度条跳转，播放中实时显示剩余时长
- 支持本地语音和远程语音（自动下载并缓存，相同 URL 不重复下载）
- 未播放消息显示红点，首次播放时淡出消失

### 文字消息
- 文字输入框支持多行输入，自动调整高度（最多 5 行）
- 回车键发送，空消息不可发送
- 文字/语音模式一键切换

### 图片和视频消息
- 扩展功能按钮（+）打开相册选择器
- 支持发送图片（200×200pt 固定尺寸）
- 支持发送视频（显示缩略图、播放按钮、时长）
- 点击图片全屏预览，支持双指缩放（1.0x-3.0x）
- 点击视频全屏播放，自动播放

### 消息状态管理
- 发送中：显示旋转加载指示器
- 已送达：单勾（UI 暂未实现）
- 已读：双勾（UI 暂未实现）
- 发送失败：红色感叹号，点击重试

### 消息撤回
- 自己发送的消息可撤回（3 分钟内，已送达状态）
- 文本消息撤回后可点击重新编辑
- 其他类型撤回后显示"你撤回了一条消息"

### 消息列表
- 发送后追加到列表；浏览历史时发送不强制滚动到底
- 时间分隔行（间隔 > 5 分钟显示）
- 下拉加载历史消息，保持阅读位置
- 长按消息可删除或撤回

## 环境要求

- Xcode 16+
- iOS 15.0+
- Swift 6.0

## 运行

```bash
# 安装 xcodegen（仅首次）
brew install xcodegen

# 生成 Xcode 工程
xcodegen generate

# 打开工程
open VoiceIM.xcodeproj
```

在 Xcode 中选择模拟器或真机，配置开发者账号后 Run。真机需在 **Signing & Capabilities** 中设置 Team。

## 技术栈

| 项目 | 说明 |
|------|------|
| Swift 6.0 | 严格并发，全面使用 async/await |
| UIKit | 纯代码布局，无 Storyboard（Launch Screen 除外） |
| AVFoundation | AVAudioRecorder 录音，AVAudioPlayer 播放，AVAsset 视频处理 |
| AVKit | AVPlayerViewController 视频播放 |
| PhotosUI | PHPickerViewController 相册选择（iOS 14+） |
| UICollectionViewDiffableDataSource | iOS 13，消息列表数据管理 |
| UICollectionViewCompositionalLayout | iOS 13，单列自适应高度布局 |
| actor | VoiceCacheManager，保证下载并发安全 |

## 项目结构

```
VoiceIM/
├── CLAUDE.md                          # Claude Code 工程指引
├── REQUIREMENTS.md                    # 完整需求文档
├── project.yml                        # xcodegen 配置
├── VoiceIM.xcodeproj
└── VoiceIM/
    ├── App/                           # 应用入口
    │   ├── AppDelegate.swift
    │   └── SceneDelegate.swift
    ├── Models/                        # 数据模型
    │   ├── ChatMessage.swift          # 通用消息模型（voice/text/image/video/recalled）
    │   └── Sender.swift               # 发送者身份
    ├── Views/                         # 视图组件
    │   ├── AvatarView.swift           # 圆形头像占位视图
    │   ├── ChatInputView.swift        # 输入栏（文字/语音切换 + 扩展按钮）
    │   ├── RecordingOverlayView.swift # 录音浮层
    │   └── ToastView.swift            # Toast 提示
    ├── ViewControllers/               # 视图控制器
    │   ├── VoiceChatViewController.swift          # 主页面（协调层）
    │   ├── RecordingOverlayViewController.swift   # 录音浮层控制器
    │   ├── ImagePreviewViewController.swift       # 图片全屏预览
    │   └── VideoPreviewViewController.swift       # 视频全屏播放
    ├── Managers/                      # 业务逻辑管理器
    │   ├── VoiceRecordManager.swift   # 录音管理
    │   ├── VoicePlaybackManager.swift # 播放管理（播放互斥）
    │   ├── VoiceCacheManager.swift    # 下载缓存（actor，线程安全）
    │   ├── PhotoPickerManager.swift   # 相册选择（async/await）
    │   ├── MessageDataSource.swift    # 消息列表数据源封装
    │   ├── MessageActionHandler.swift # 消息交互处理（删除/撤回/重试）
    │   ├── InputCoordinator.swift     # 输入协调器（录音/扩展菜单）
    │   └── KeyboardManager.swift      # 键盘管理器
    ├── Cells/                         # 消息 Cell
    │   ├── ChatBubbleCell.swift       # Cell 基类
    │   ├── VoiceMessageCell.swift     # 语音消息 Cell
    │   ├── TextMessageCell.swift      # 文本消息 Cell
    │   ├── ImageMessageCell.swift     # 图片消息 Cell
    │   ├── VideoMessageCell.swift     # 视频消息 Cell
    │   └── RecalledMessageCell.swift  # 撤回消息 Cell
    ├── Protocols/                     # 协议定义
    │   └── MessageCellConfigurable.swift  # Cell 统一配置协议
    └── Info.plist
```

## 关键设计

- **架构重构**：VoiceChatViewController 从 1052 行精简到 519 行，职责分离为 4 个管理器
  - `MessageDataSource`：封装 DiffableDataSource 和 snapshot 更新逻辑
  - `MessageActionHandler`：统一处理消息交互（删除/撤回/重试）
  - `InputCoordinator`：管理录音状态机和扩展功能
  - `KeyboardManager`：处理键盘显示/隐藏时的布局调整
- **消息类型扩展**：通过 `MessageCellConfigurable` 协议统一 Cell 配置接口，新增消息类型只需实现协议并注册
- **状态管理**：`ChatMessage.Hashable` 仅基于 `id`，可变状态（`isPlayed`、`sendStatus`）通过 `reloadItems` 更新
- **播放互斥**：`VoicePlaybackManager` 单例管理，播放新消息时自动停止当前播放
- **下载缓存**：`VoiceCacheManager` 使用 `actor` 保证线程安全，同一 URL 复用同一个下载任务
- **布局切换**：收/发方向通过两套预构建约束切换，避免 cell 复用时的约束冲突
- **头像颜色**：基于 `sender.id` UTF-8 字节求和映射到固定调色板，跨 session 保持一致

## 开发说明

完整的技术细节、架构决策、并发模型说明请参考 `REQUIREMENTS.md` 和 `CLAUDE.md`。
