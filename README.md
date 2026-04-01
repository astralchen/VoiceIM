# VoiceIM

iOS IM 语音消息功能完整实现，包含录制、发送、播放、进度控制、未读提醒全流程。

## 功能

**录制**
- 长按"按住说话"开始录音，实时显示秒数
- 上滑进入取消状态，松手取消；下滑恢复正常录音
- 松手发送（< 1s 提示"说话时间太短"）
- 最长 30s，到达上限自动发送

**播放**
- 点击播放，再次点击停止；同时只播放一条
- 可拖拽进度条跳转，播放中实时显示剩余时长
- 支持本地语音和远程语音（自动下载并缓存，相同 URL 不重复下载）

**消息列表**
- 发送后追加到列表；浏览历史时发送不强制滚动到底
- 未播放消息显示红点，首次播放时淡出消失

## 环境要求

- Xcode 16+
- iOS 13.0+
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
| AVFoundation | AVAudioRecorder 录音，AVAudioPlayer 播放 |
| UICollectionViewDiffableDataSource | iOS 13，消息列表数据管理 |
| UICollectionViewCompositionalLayout | iOS 13，单列自适应高度布局 |
| actor | VoiceCacheManager，保证下载并发安全 |

## 项目结构

```
Voice/
├── CLAUDE.md               # Claude Code 工程指引
├── REQUIREMENTS.md         # 完整需求文档
├── project.yml             # xcodegen 配置
├── VoiceIM.xcodeproj
└── VoiceIM/
    ├── VoiceMessage.swift              # 数据模型（含 isPlayed 持久化字段）
    ├── VoiceRecordManager.swift        # 录音管理
    ├── VoiceCacheManager.swift         # 下载缓存
    ├── VoicePlaybackManager.swift      # 播放管理（互斥）
    ├── VoiceMessageCell.swift          # 消息气泡 Cell
    ├── RecordingOverlayView.swift      # 录音浮层
    ├── ToastView.swift                 # Toast 提示
    ├── VoiceChatViewController.swift   # 主页面
    ├── AppDelegate.swift
    ├── SceneDelegate.swift
    └── Info.plist
```
