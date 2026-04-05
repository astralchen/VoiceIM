# 重启后消息显示问题诊断

## 问题描述

发送完消息，重新启动应用后，消息显示都有问题。

## 问题分析

### 数据流程

```
启动应用
  ↓
viewDidLoad()
  ↓
viewModel.loadMessages()
  ↓
repository.loadMessages()
  ↓
storage.load() → 从 JSON 文件加载消息
  ↓
messages = [ChatMessage]
  ↓
@Published messages 触发更新
  ↓
updateMessages(messages)
  ↓
messageDataSource.appendMessage()
  ↓
Cell 显示
```

### 可能的问题

1. **文件路径问题**
   - 保存时：`localURL = /path/to/file.m4a`
   - 加载后：文件路径可能失效
   - 原因：临时目录路径可能变化

2. **JSON 序列化问题**
   - `ChatMessage.Kind` 包含 URL
   - URL 序列化后可能无法正确反序列化

3. **文件不存在**
   - 文件保存在临时目录
   - 重启后临时目录可能被清理

## 解决方案

### 方案 1：使用相对路径（推荐）✅

保存时只存储文件名，加载时重新构建完整路径：

```swift
// ChatMessage.swift
struct ChatMessage: Codable {
    enum Kind: Codable {
        case voice(fileName: String?, remoteURL: URL?, duration: TimeInterval)
        case image(fileName: String?, remoteURL: URL?)
        case video(fileName: String?, remoteURL: URL?, duration: TimeInterval)
        
        // 计算属性：根据文件名构建完整路径
        var localURL: URL? {
            switch self {
            case .voice(let fileName, _, _):
                guard let fileName = fileName else { return nil }
                return FileStorageManager.shared.voicesDirectory
                    .appendingPathComponent(fileName)
            case .image(let fileName, _):
                guard let fileName = fileName else { return nil }
                return FileStorageManager.shared.imagesDirectory
                    .appendingPathComponent(fileName)
            case .video(let fileName, _, _):
                guard let fileName = fileName else { return nil }
                return FileStorageManager.shared.videosDirectory
                    .appendingPathComponent(fileName)
            default:
                return nil
            }
        }
    }
}
```

### 方案 2：自定义 Codable 实现

```swift
extension ChatMessage.Kind {
    enum CodingKeys: String, CodingKey {
        case type
        case fileName
        case remoteURL
        case duration
        case content
        // ...
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch self {
        case .voice(let localURL, let remoteURL, let duration):
            try container.encode("voice", forKey: .type)
            // 只保存文件名，不保存完整路径
            if let localURL = localURL {
                try container.encode(localURL.lastPathComponent, forKey: .fileName)
            }
            try container.encodeIfPresent(remoteURL, forKey: .remoteURL)
            try container.encode(duration, forKey: .duration)
        // ...
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        
        switch type {
        case "voice":
            let fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
            let remoteURL = try container.decodeIfPresent(URL.self, forKey: .remoteURL)
            let duration = try container.decode(TimeInterval.self, forKey: .duration)
            
            // 根据文件名重新构建完整路径
            let localURL = fileName.map {
                FileStorageManager.shared.voicesDirectory
                    .appendingPathComponent($0)
            }
            
            self = .voice(localURL: localURL, remoteURL: remoteURL, duration: duration)
        // ...
        }
    }
}
```

### 方案 3：验证文件存在性

在 Cell 显示前验证文件是否存在：

```swift
func cellDidTapPlay(_ cell: VoiceMessageCell, message: ChatMessage) {
    guard case .voice(let localURL, _, _) = message.kind,
          let url = localURL else {
        ToastView.show("语音文件不存在", in: view)
        return
    }
    
    // 验证文件是否存在
    if !FileManager.default.fileExists(atPath: url.path) {
        ToastView.show("语音文件已被删除", in: view)
        return
    }
    
    // ...
}
```

## 临时调试

添加日志查看具体问题：

```swift
// ChatViewModel.loadMessages()
func loadMessages() {
    do {
        messages = try repository.loadMessages()
        logger.info("Loaded \(messages.count) messages")
        
        // 调试：检查每条消息的文件路径
        for message in messages {
            switch message.kind {
            case .voice(let localURL, _, _):
                logger.debug("Voice message: \(message.id)")
                logger.debug("  localURL: \(String(describing: localURL))")
                if let url = localURL {
                    let exists = FileManager.default.fileExists(atPath: url.path)
                    logger.debug("  file exists: \(exists)")
                }
            case .image(let localURL, _):
                logger.debug("Image message: \(message.id)")
                logger.debug("  localURL: \(String(describing: localURL))")
                if let url = localURL {
                    let exists = FileManager.default.fileExists(atPath: url.path)
                    logger.debug("  file exists: \(exists)")
                }
            case .video(let localURL, _, _):
                logger.debug("Video message: \(message.id)")
                logger.debug("  localURL: \(String(describing: localURL))")
                if let url = localURL {
                    let exists = FileManager.default.fileExists(atPath: url.path)
                    logger.debug("  file exists: \(exists)")
                }
            default:
                break
            }
        }
    } catch {
        logger.error("Failed to load messages: \(error)")
        self.error = error as? ChatError ?? .unknown(error)
    }
}
```

## 下一步

1. 运行应用并查看控制台日志
2. 发送一条语音消息
3. 重启应用
4. 查看日志输出：
   - 加载了多少条消息？
   - localURL 是什么？
   - 文件是否存在？
5. 告诉我日志内容

---

**诊断文档创建时间**：2026-04-05
