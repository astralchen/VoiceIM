# 图片和视频问题调试指南 🔍

## 快速诊断

现在运行应用后，点击图片或视频时会显示具体的错误提示：

| 错误提示 | 原因 | 解决方案 |
|---------|------|---------|
| "消息类型错误" | message.kind 不是 .image 或 .video | 数据不同步问题 |
| "图片文件不存在" | localURL 和 remoteURL 都是 nil | 文件保存失败 |
| "视频文件不存在" | localURL 和 remoteURL 都是 nil | 文件保存失败 |

---

## 详细调试步骤

### 步骤 1：运行应用并测试

```bash
open VoiceIM.xcodeproj
# 在 Xcode 中运行到模拟器
```

### 步骤 2：测试图片功能

1. 点击"+"按钮
2. 选择"相册"
3. 选择一张图片
4. 观察：
   - ✅ 图片是否显示在列表中？
   - ✅ 点击图片后有什么提示？

### 步骤 3：测试视频功能

1. 点击"+"按钮
2. 选择"相册"
3. 选择一个视频
4. 观察：
   - ✅ 视频缩略图是否显示？
   - ✅ 点击视频后有什么提示？

### 步骤 4：查看控制台日志

在 Xcode 控制台查看日志输出，寻找：
- `Sent image message: ...`
- `Sent video message: ...`
- `Failed to send ...`

---

## 可能的问题和解决方案

### 问题 1：提示"消息类型错误"

**原因**：数据不同步，Cell 中的 message 类型不正确

**解决方案**：
```swift
// 在 VoiceChatViewController.swift 中添加日志
func cellDidTapImage(_ cell: ImageMessageCell, message: ChatMessage) {
    print("🔍 Message ID: \(message.id)")
    print("🔍 Message kind: \(message.kind)")
    
    guard case .image(let localURL, let remoteURL) = message.kind else {
        print("❌ Message is not an image type!")
        ToastView.show("消息类型错误", in: view)
        return
    }
    // ...
}
```

### 问题 2：提示"图片/视频文件不存在"

**原因**：localURL 和 remoteURL 都是 nil

**可能的子原因**：

#### 2.1 文件保存失败

检查 `MessageRepository.sendImageMessage()`：

```swift
func sendImageMessage(tempURL: URL) throws -> ChatMessage {
    do {
        print("💾 Saving image from: \(tempURL)")
        let permanentURL = try fileStorage.saveImageFile(from: tempURL)
        print("✅ Image saved to: \(permanentURL)")
        
        let message = ChatMessage.image(localURL: permanentURL)
        try storage.append(message)
        
        return message
    } catch {
        print("❌ Failed to save image: \(error)")
        throw error
    }
}
```

#### 2.2 FileStorageManager 未实现

检查 `FileStorageManager` 是否有这些方法：
- `saveImageFile(from:) -> URL`
- `saveVideoFile(from:) -> URL`

如果没有，需要实现：

```swift
// FileStorageManager.swift
func saveImageFile(from tempURL: URL) throws -> URL {
    let fileName = UUID().uuidString + ".jpg"
    let permanentURL = imagesDirectory.appendingPathComponent(fileName)
    
    try FileManager.default.copyItem(at: tempURL, to: permanentURL)
    
    return permanentURL
}

func saveVideoFile(from tempURL: URL) throws -> URL {
    let fileName = UUID().uuidString + ".mp4"
    let permanentURL = videosDirectory.appendingPathComponent(fileName)
    
    try FileManager.default.copyItem(at: tempURL, to: permanentURL)
    
    return permanentURL
}
```

#### 2.3 目录不存在

检查 `FileStorageManager` 是否创建了目录：

```swift
private let imagesDirectory: URL
private let videosDirectory: URL

init() {
    let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    imagesDirectory = base.appendingPathComponent("Images", isDirectory: true)
    videosDirectory = base.appendingPathComponent("Videos", isDirectory: true)
    
    // 创建目录
    try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: videosDirectory, withIntermediateDirectories: true)
}
```

### 问题 3：图片/视频显示但点击无反应

**原因**：Cell 的 delegate 未设置

**解决方案**：

检查 `MessageDataSource` 的 cell provider：

```swift
// 在 setupCollectionView() 中
messageDataSource.dependencies = MessageCellDependencies(
    isPlaying: player.isPlaying(id:),
    currentProgress: player.currentProgress(for:),
    voiceDelegate: self,
    imageDelegate: self,      // ← 确保设置
    videoDelegate: self,      // ← 确保设置
    locationDelegate: self,
    onLinkTapped: { [weak self] url, type in
        self?.handleLinkTapped(url: url, type: type)
    })
```

---

## 完整的调试版本代码

如果问题仍然存在，可以使用这个带详细日志的版本：

```swift
// MARK: - ImageMessageCellDelegate

extension VoiceChatViewController: ImageMessageCellDelegate {
    func cellDidTapImage(_ cell: ImageMessageCell, message: ChatMessage) {
        print("📸 ========== Image Tap Debug ==========")
        print("📸 Message ID: \(message.id)")
        print("📸 Message kind: \(message.kind)")
        print("📸 Is outgoing: \(message.isOutgoing)")
        
        guard case .image(let localURL, let remoteURL) = message.kind else {
            print("❌ Message is not an image type!")
            print("❌ Actual kind: \(message.kind)")
            ToastView.show("消息类型错误", in: view)
            return
        }
        
        print("📸 localURL: \(String(describing: localURL))")
        print("📸 remoteURL: \(String(describing: remoteURL))")
        
        guard let url = localURL ?? remoteURL else {
            print("❌ Both URLs are nil!")
            ToastView.show("图片文件不存在", in: view)
            return
        }
        
        print("📸 Using URL: \(url)")
        print("📸 File exists: \(FileManager.default.fileExists(atPath: url.path))")
        
        if !FileManager.default.fileExists(atPath: url.path) {
            print("❌ File does not exist at path!")
            ToastView.show("图片文件已被删除", in: view)
            return
        }
        
        print("✅ Opening image preview")
        let previewVC = ImagePreviewViewController(imageURL: url)
        previewVC.modalPresentationStyle = .fullScreen
        present(previewVC, animated: true)
        print("📸 ====================================")
    }
}

// MARK: - VideoMessageCellDelegate

extension VoiceChatViewController: VideoMessageCellDelegate {
    func cellDidTapVideo(_ cell: VideoMessageCell, message: ChatMessage) {
        print("🎬 ========== Video Tap Debug ==========")
        print("🎬 Message ID: \(message.id)")
        print("🎬 Message kind: \(message.kind)")
        
        guard case .video(let localURL, let remoteURL, let duration) = message.kind else {
            print("❌ Message is not a video type!")
            ToastView.show("消息类型错误", in: view)
            return
        }
        
        print("🎬 localURL: \(String(describing: localURL))")
        print("🎬 remoteURL: \(String(describing: remoteURL))")
        print("🎬 duration: \(duration)")
        
        guard let url = localURL ?? remoteURL else {
            print("❌ Both URLs are nil!")
            ToastView.show("视频文件不存在", in: view)
            return
        }
        
        print("🎬 Using URL: \(url)")
        print("🎬 File exists: \(FileManager.default.fileExists(atPath: url.path))")
        
        if !FileManager.default.fileExists(atPath: url.path) {
            print("❌ File does not exist at path!")
            ToastView.show("视频文件已被删除", in: view)
            return
        }
        
        print("✅ Opening video preview")
        let previewVC = VideoPreviewViewController(videoURL: url)
        previewVC.modalPresentationStyle = .fullScreen
        present(previewVC, animated: true)
        print("🎬 ====================================")
    }
}
```

---

## 检查清单

运行应用后，按照以下清单检查：

### 发送图片
- [ ] 点击"+"按钮能打开菜单
- [ ] 选择"相册"能打开相册
- [ ] 选择图片后能返回聊天页面
- [ ] 图片显示在消息列表中
- [ ] 图片有缩略图显示
- [ ] 点击图片后的提示是什么？

### 发送视频
- [ ] 点击"+"按钮能打开菜单
- [ ] 选择"相册"能打开相册
- [ ] 选择视频后能返回聊天页面
- [ ] 视频显示在消息列表中
- [ ] 视频有缩略图显示
- [ ] 点击视频后的提示是什么？

### 控制台日志
- [ ] 有 "Sent image message" 日志
- [ ] 有 "Sent video message" 日志
- [ ] 有文件保存相关日志
- [ ] 有错误日志吗？内容是什么？

---

## 下一步

1. **运行应用并测试**
2. **记录错误提示**
3. **查看控制台日志**
4. **告诉我具体的错误信息**

我会根据你提供的错误信息进一步诊断和修复。

---

**调试指南创建时间**：2026-04-05
**编译状态**：✅ BUILD SUCCEEDED
