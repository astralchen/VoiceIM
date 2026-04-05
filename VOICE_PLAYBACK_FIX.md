# 语音播放问题诊断和修复

## 问题描述

发送语音消息后无法播放。

## 问题分析

### 数据流程

```
1. 发送语音
InputCoordinator.onSendVoice(url, duration)
  ↓
ChatViewModel.sendVoiceMessage(url, duration)
  ↓
repository.sendVoiceMessage(tempURL, duration)
  ↓
fileStorage.saveVoiceFile(from: tempURL) → permanentURL
  ↓
ChatMessage.voice(localURL: permanentURL, ...)
  ↓
messages.append(message)  // ViewModel 的 messages
  ↓
@Published messages 触发更新
  ↓
ViewController.updateMessages(messages)
  ↓
messageDataSource.appendMessage(message)  // DataSource 的 messages

2. 播放语音
VoiceMessageCell.cellDidTapPlay(cell, message)
  ↓
ViewController 从 messageDataSource.messages 获取消息
  ↓
ChatViewModel.playVoiceMessage(id)
  ↓
从 ViewModel.messages 查找消息  ← 问题在这里！
  ↓
提取 localURL
  ↓
playbackService.play(id, url)
```

### 根本原因

**数据不同步**：
- ViewModel 有一份 `messages` 数组
- MessageDataSource 有另一份 `messages` 数组
- Cell 点击时传递的是 MessageDataSource 中的消息
- 但 `playVoiceMessage()` 从 ViewModel 的 messages 查找

**可能的情况**：
1. ViewModel.messages 和 MessageDataSource.messages 不同步
2. ViewModel.messages 中的消息 localURL 为 nil
3. 消息 ID 不匹配

---

## 解决方案

### 方案 1：修改 Cell Delegate（推荐）✅

让 Cell 直接传递消息对象，而不是只传递 ID：

```swift
// VoiceMessageCellDelegate
protocol VoiceMessageCellDelegate: AnyObject {
    func cellDidTapPlay(_ cell: VoiceMessageCell, message: ChatMessage)
}

// VoiceChatViewController
func cellDidTapPlay(_ cell: VoiceMessageCell, message: ChatMessage) {
    // 直接使用 message，不需要再查找
    guard case .voice(let localURL, _, _) = message.kind,
          let url = localURL else { return }
    
    do {
        try viewModel.playbackService.play(id: message.id, url: url)
        
        // 标记为已播放
        if !message.isPlayed && !message.isOutgoing {
            viewModel.markAsPlayed(id: message.id)
        }
    } catch {
        // 处理错误
    }
}
```

### 方案 2：从 MessageDataSource 查找

修改 `playVoiceMessage()` 从 MessageDataSource 查找：

```swift
func playVoiceMessage(id: UUID, from dataSource: MessageDataSourceProtocol) {
    guard let message = dataSource.messages.first(where: { $0.id == id }),
          case .voice(let localURL, _, _) = message.kind,
          let url = localURL else { return }
    
    do {
        try playbackService.play(id: id, url: url)
        playingMessageID = id
        
        if !message.isPlayed && !message.isOutgoing {
            markAsPlayed(id: id)
        }
    } catch {
        logger.error("Failed to play voice message: \(error)")
        self.error = .playbackStartFailed
    }
}
```

### 方案 3：同步两份 messages

确保 ViewModel.messages 和 MessageDataSource.messages 始终同步。

---

## 推荐修复

使用**方案 1**，因为：
1. Cell 已经有消息对象，无需再查找
2. 避免数据不同步问题
3. 代码更简洁高效

---

## 临时调试

添加日志查看问题：

```swift
func playVoiceMessage(id: UUID) {
    logger.debug("Attempting to play message: \(id)")
    logger.debug("ViewModel messages count: \(messages.count)")
    
    guard let message = messages.first(where: { $0.id == id }) else {
        logger.error("Message not found in ViewModel.messages")
        return
    }
    
    logger.debug("Found message: \(message)")
    
    guard case .voice(let localURL, _, _) = message.kind else {
        logger.error("Message is not a voice message")
        return
    }
    
    guard let url = localURL else {
        logger.error("Voice message localURL is nil")
        return
    }
    
    logger.debug("Playing voice from URL: \(url)")
    
    do {
        try playbackService.play(id: id, url: url)
        playingMessageID = id
        
        if !message.isPlayed && !message.isOutgoing {
            markAsPlayed(id: id)
        }
    } catch {
        logger.error("Failed to play voice message: \(error)")
        self.error = .playbackStartFailed
    }
}
```

---

## 下一步

1. 添加日志查看具体错误
2. 实施方案 1 修复问题
3. 测试验证
