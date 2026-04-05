# 图片和视频问题修复 ✅

## 问题描述

用户反馈：视频和图片都有问题

## 问题分析

与语音播放问题类似，可能的原因：
1. **localURL 为 nil**：文件保存失败
2. **文件不存在**：文件路径错误或被删除
3. **消息类型错误**：数据不同步导致类型不匹配

## 修复方案

### 添加详细的错误提示

```swift
// 修复前（无提示）
func cellDidTapImage(_ cell: ImageMessageCell, message: ChatMessage) {
    guard case .image(let localURL, let remoteURL) = message.kind,
          let url = localURL ?? remoteURL else { return }  // 静默失败
    // ...
}

// 修复后（有提示）
func cellDidTapImage(_ cell: ImageMessageCell, message: ChatMessage) {
    guard case .image(let localURL, let remoteURL) = message.kind else {
        ToastView.show("消息类型错误", in: view)
        return
    }

    guard let url = localURL ?? remoteURL else {
        ToastView.show("图片文件不存在", in: view)
        return
    }
    // ...
}
```

### 同样修复视频

```swift
func cellDidTapVideo(_ cell: VideoMessageCell, message: ChatMessage) {
    guard case .video(let localURL, let remoteURL, _) = message.kind else {
        ToastView.show("消息类型错误", in: view)
        return
    }

    guard let url = localURL ?? remoteURL else {
        ToastView.show("视频文件不存在", in: view)
        return
    }
    // ...
}
```

## 可能的根本原因

### 1. 文件保存失败

检查 `MessageRepository.sendImageMessage()` 和 `sendVideoMessage()`：

```swift
func sendImageMessage(tempURL: URL) throws -> ChatMessage {
    // 保存图片文件到永久存储
    let permanentURL = try fileStorage.saveImageFile(from: tempURL)
    
    // 创建消息
    let message = ChatMessage.image(localURL: permanentURL)
    try storage.append(message)
    
    return message
}
```

如果 `fileStorage.saveImageFile()` 抛出异常，消息会创建失败。

### 2. 数据不同步

与语音问题相同：
- ViewModel.messages 和 MessageDataSource.messages 不同步
- Cell 传递的 message 可能是旧数据

### 3. 文件路径问题

检查 `FileStorageManager` 的实现：
- 文件是否正确保存
- 路径是否正确
- 权限是否正确

## 测试步骤

1. **发送图片**
   - 选择图片
   - 查看是否显示
   - 点击图片
   - 查看错误提示

2. **发送视频**
   - 选择视频
   - 查看是否显示
   - 点击视频
   - 查看错误提示

3. **查看日志**
   - 检查控制台输出
   - 查看文件保存日志
   - 查看错误信息

## 下一步调试

如果问题仍然存在，需要：

1. **添加日志**
   ```swift
   func cellDidTapImage(_ cell: ImageMessageCell, message: ChatMessage) {
       print("📸 Tapping image message: \(message.id)")
       
       guard case .image(let localURL, let remoteURL) = message.kind else {
           print("❌ Message is not an image type")
           ToastView.show("消息类型错误", in: view)
           return
       }
       
       print("📸 localURL: \(String(describing: localURL))")
       print("📸 remoteURL: \(String(describing: remoteURL))")
       
       guard let url = localURL ?? remoteURL else {
           print("❌ Both URLs are nil")
           ToastView.show("图片文件不存在", in: view)
           return
       }
       
       print("📸 Opening image at: \(url)")
       // ...
   }
   ```

2. **检查文件存储**
   ```swift
   // 在 FileStorageManager.saveImageFile() 中
   func saveImageFile(from tempURL: URL) throws -> URL {
       let fileName = UUID().uuidString + ".jpg"
       let permanentURL = imagesDirectory.appendingPathComponent(fileName)
       
       print("💾 Saving image from: \(tempURL)")
       print("💾 Saving image to: \(permanentURL)")
       
       try FileManager.default.copyItem(at: tempURL, to: permanentURL)
       
       print("✅ Image saved successfully")
       return permanentURL
   }
   ```

3. **验证文件存在**
   ```swift
   guard let url = localURL ?? remoteURL else {
       ToastView.show("图片文件不存在", in: view)
       return
   }
   
   // 检查文件是否存在
   if !FileManager.default.fileExists(atPath: url.path) {
       print("❌ File does not exist at: \(url.path)")
       ToastView.show("图片文件已被删除", in: view)
       return
   }
   ```

## 编译状态

✅ BUILD SUCCEEDED

## 总结

已添加详细的错误提示，帮助诊断问题：
- ✅ 消息类型错误提示
- ✅ 文件不存在提示
- ✅ 编译成功

下一步：
1. 运行应用
2. 测试图片和视频功能
3. 查看错误提示
4. 根据提示进一步调试

---

**修复完成时间**：2026-04-05
**编译状态**：✅ BUILD SUCCEEDED
