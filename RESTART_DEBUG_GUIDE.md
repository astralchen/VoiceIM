# 重启后消息显示问题 - 调试指南

## ✅ 已完成的准备工作

1. ✅ 添加详细的调试日志
2. ✅ 编译成功验证
3. ✅ 准备就绪

## 🔍 调试步骤

### 步骤 1：运行应用

```bash
open VoiceIM.xcodeproj
```

在 Xcode 中运行到模拟器。

### 步骤 2：发送测试消息

1. **发送语音消息**
   - 长按"按住说话"按钮
   - 说几秒钟
   - 松手发送

2. **发送图片消息**（可选）
   - 点击"+"按钮
   - 选择"相册"
   - 选择一张图片

3. **发送视频消息**（可选）
   - 点击"+"按钮
   - 选择"相册"
   - 选择一个视频

### 步骤 3：重启应用

在 Xcode 中：
1. 点击停止按钮（⏹）
2. 再次点击运行按钮（▶️）

### 步骤 4：查看控制台日志

在 Xcode 控制台（底部面板）查找以下日志：

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
期望看到的日志：
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[INFO] Loaded 3 messages

[DEBUG] Voice message: <UUID>
[DEBUG]   localURL: Optional(file:///path/to/voice.m4a)
[DEBUG]   file exists: true

[DEBUG] Image message: <UUID>
[DEBUG]   localURL: Optional(file:///path/to/image.jpg)
[DEBUG]   file exists: true

[DEBUG] Video message: <UUID>
[DEBUG]   localURL: Optional(file:///path/to/video.mp4)
[DEBUG]   file exists: true

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### 步骤 5：观察界面

重启后观察：
- ✅ 消息是否显示在列表中？
- ✅ 消息内容是否正确？
- ✅ 点击消息有什么反应？
- ✅ 有错误提示吗？

---

## 📊 可能的问题和对应日志

### 情况 1：file exists: false

**日志示例**：
```
[DEBUG] Voice message: <UUID>
[DEBUG]   localURL: Optional(file:///var/.../voice.m4a)
[DEBUG]   file exists: false  ← 问题在这里
```

**原因**：文件路径失效或文件被删除

**解决方案**：
- 修改存储策略，使用永久目录
- 或者只保存文件名，加载时重新构建路径

### 情况 2：localURL: nil

**日志示例**：
```
[DEBUG] Voice message: <UUID>
[DEBUG]   localURL: nil  ← 问题在这里
[DEBUG]   file exists: false
```

**原因**：JSON 反序列化失败，URL 丢失

**解决方案**：
- 检查 JSON 文件内容
- 修复 Codable 实现

### 情况 3：没有加载到消息

**日志示例**：
```
[INFO] Loaded 0 messages  ← 问题在这里
```

**原因**：
- JSON 文件不存在
- JSON 文件为空
- 反序列化失败

**解决方案**：
- 检查 messages.json 文件是否存在
- 检查文件内容是否正确

### 情况 4：加载失败

**日志示例**：
```
[ERROR] Failed to load messages: <error>
```

**原因**：读取或解码错误

**解决方案**：
- 查看具体错误信息
- 检查 JSON 格式

---

## 📝 需要提供的信息

请把以下信息告诉我：

### 1. 控制台日志

复制粘贴完整的日志输出，特别是：
- `[INFO] Loaded X messages`
- `[DEBUG] Voice/Image/Video message: ...`
- `[DEBUG]   localURL: ...`
- `[DEBUG]   file exists: ...`
- 任何 `[ERROR]` 日志

### 2. 界面观察

- 消息是否显示？
- 显示的内容是什么？
- 点击消息有什么反应？
- 有错误提示吗？

### 3. JSON 文件内容（可选）

如果方便，可以查看 JSON 文件内容：

```bash
# 在模拟器中查找文件
find ~/Library/Developer/CoreSimulator/Devices -name "messages.json" -exec cat {} \;
```

---

## 🔧 我会根据日志进行修复

根据你提供的日志，我会：

1. **如果 file exists: false**
   - 修改为使用永久目录
   - 或改为只保存文件名

2. **如果 localURL: nil**
   - 修复 Codable 实现
   - 确保 URL 正确序列化

3. **如果加载失败**
   - 修复 JSON 格式
   - 添加错误恢复机制

---

## ✅ 编译状态

```
✅ BUILD SUCCEEDED
✅ 调试日志已添加
✅ 准备就绪
```

---

**现在请运行应用，按照步骤操作，然后把日志告诉我！**

我会根据具体情况立即修复问题。

---

**调试指南创建时间**：2026-04-05
**编译状态**：✅ BUILD SUCCEEDED
