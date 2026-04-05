# 重启后文件路径失效问题 - 修复方案

## 问题确认 ✅

根据日志，问题已确认：

```
[DEBUG]   localURL: Optional(file:///.../Application/D02E6FE1-.../Voice/xxx.m4a)
[DEBUG]   file exists: false

[DEBUG]   localURL: Optional(file:///.../Application/E3259FFC-.../Voice/xxx.m4a)
[DEBUG]   file exists: false
```

**根本原因**：iOS 每次启动应用会分配新的 Application ID，导致完整路径失效。

## 解决方案

### 方案 1：修改 ChatMessage.Kind 结构（推荐）✅

改为只保存文件名，提供计算属性构建完整路径：

```swift
enum Kind: Sendable {
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
```

### 方案 2：自定义 Codable 实现

保持 API 不变，只在序列化时转换：

```swift
extension ChatMessage.Kind {
    enum CodingKeys: String, CodingKey {
        case type, fileName, remoteURL, duration, content, latitude, longitude, address, originalText
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch self {
        case .voice(let localURL, let remoteURL, let duration):
            try container.encode("voice", forKey: .type)
            // 只保存文件名
            if let localURL = localURL {
                try container.encode(localURL.lastPathComponent, forKey: .fileName)
            }
            try container.encodeIfPresent(remoteURL, forKey: .remoteURL)
            try container.encode(duration, forKey: .duration)
            
        case .image(let localURL, let remoteURL):
            try container.encode("image", forKey: .type)
            if let localURL = localURL {
                try container.encode(localURL.lastPathComponent, forKey: .fileName)
            }
            try container.encodeIfPresent(remoteURL, forKey: .remoteURL)
            
        case .video(let localURL, let remoteURL, let duration):
            try container.encode("video", forKey: .type)
            if let localURL = localURL {
                try container.encode(localURL.lastPathComponent, forKey: .fileName)
            }
            try container.encodeIfPresent(remoteURL, forKey: .remoteURL)
            try container.encode(duration, forKey: .duration)
            
        case .text(let content):
            try container.encode("text", forKey: .type)
            try container.encode(content, forKey: .content)
            
        case .recalled(let originalText):
            try container.encode("recalled", forKey: .type)
            try container.encodeIfPresent(originalText, forKey: .originalText)
            
        case .location(let latitude, let longitude, let address):
            try container.encode("location", forKey: .type)
            try container.encode(latitude, forKey: .latitude)
            try container.encode(longitude, forKey: .longitude)
            try container.encodeIfPresent(address, forKey: .address)
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
                FileStorageManager.shared.voicesDirectory.appendingPathComponent($0)
            }
            
            self = .voice(localURL: localURL, remoteURL: remoteURL, duration: duration)
            
        case "image":
            let fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
            let remoteURL = try container.decodeIfPresent(URL.self, forKey: .remoteURL)
            
            let localURL = fileName.map {
                FileStorageManager.shared.imagesDirectory.appendingPathComponent($0)
            }
            
            self = .image(localURL: localURL, remoteURL: remoteURL)
            
        case "video":
            let fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
            let remoteURL = try container.decodeIfPresent(URL.self, forKey: .remoteURL)
            let duration = try container.decode(TimeInterval.self, forKey: .duration)
            
            let localURL = fileName.map {
                FileStorageManager.shared.videosDirectory.appendingPathComponent($0)
            }
            
            self = .video(localURL: localURL, remoteURL: remoteURL, duration: duration)
            
        case "text":
            let content = try container.decode(String.self, forKey: .content)
            self = .text(content)
            
        case "recalled":
            let originalText = try container.decodeIfPresent(String.self, forKey: .originalText)
            self = .recalled(originalText: originalText)
            
        case "location":
            let latitude = try container.decode(Double.self, forKey: .latitude)
            let longitude = try container.decode(Double.self, forKey: .longitude)
            let address = try container.decodeIfPresent(String.self, forKey: .address)
            self = .location(latitude: latitude, longitude: longitude, address: address)
            
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown message type: \(type)"
            )
        }
    }
}
```

## 推荐方案

使用**方案 2**（自定义 Codable），因为：
1. ✅ 保持现有 API 不变，无需修改其他代码
2. ✅ 只在序列化/反序列化时处理
3. ✅ 向后兼容，旧数据也能正确加载

## 实施步骤

1. 在 `ChatMessage.swift` 中添加自定义 Codable 实现
2. 编译验证
3. 测试：发送消息 → 重启 → 验证显示

## 预期效果

修复后：
- ✅ 重启应用后消息正常显示
- ✅ 语音可以播放
- ✅ 图片可以查看
- ✅ 视频可以播放

---

**准备实施修复...**
