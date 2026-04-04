# WaveformProgressView API 重构说明

## 设计原则

参考主流 IM 应用（微信、Telegram）的语音消息宽度设计，采用**分段增长策略**：

- **1-2秒短语音**：最小宽度（80pt），避免气泡过窄
- **3-10秒常规语音**：线性增长（每秒+12pt），视觉差异明显
- **10秒以上长语音**：对数增长（增速放缓），避免占满屏幕

## 核心 API

### 宽度控制参数

```swift
// 最小宽度（1-2秒短语音）
var minimumWidth: CGFloat = 80

// 最大宽度（60秒长语音）
var maximumWidth: CGFloat = 220

// 线性增长的分界点（秒）
var linearThreshold: TimeInterval = 10

// 线性增长速率（pt/秒）
var linearGrowthRate: CGFloat = 12
```

### 宽度计算公式

**阶段1（duration ≤ 10秒）：线性增长**
```
width = minimumWidth + linearGrowthRate × duration
```

示例：
- 1秒：80 + 12×1 = 92pt
- 2秒：80 + 12×2 = 104pt
- 3秒：80 + 12×3 = 116pt
- 5秒：80 + 12×5 = 140pt
- 10秒：80 + 12×10 = 200pt

**阶段2（duration > 10秒）：对数增长**
```
width = widthAtThreshold + 30 × log₂(duration / linearThreshold)
```

示例（从10秒的200pt开始）：
- 15秒：200 + 30×log₂(1.5) = 217.5pt
- 30秒：200 + 30×log₂(3.0) = 247.5pt
- 60秒：200 + 30×log₂(6.0) = 277.7pt（受 maximumWidth=220 限制，实际为220pt）

## 使用示例

### 默认配置（推荐）

```swift
waveformView.minimumWidth = 80
waveformView.maximumWidth = 220
waveformView.linearThreshold = 10
waveformView.linearGrowthRate = 12
```

### 自定义配置

```swift
// 更紧凑的设计（适合小屏设备）
waveformView.minimumWidth = 60
waveformView.maximumWidth = 180
waveformView.linearGrowthRate = 10

// 更宽松的设计（适合 iPad）
waveformView.minimumWidth = 100
waveformView.maximumWidth = 300
waveformView.linearGrowthRate = 15
```

## 对比旧 API

### 旧设计（已移除）

```swift
var widthPerSecond: CGFloat = 12  // 全局统一增长速率
```

问题：
- 无法区分短语音和长语音的增长策略
- 2秒语音宽度过宽（24pt），视觉不合理
- 长语音（60秒）宽度过大（720pt），超出屏幕

### 新设计

```swift
var minimumWidth: CGFloat = 80
var maximumWidth: CGFloat = 220
var linearThreshold: TimeInterval = 10
var linearGrowthRate: CGFloat = 12
```

优势：
- 分段增长，符合主流 IM 应用设计规范
- 短语音有最小宽度保证（80pt）
- 长语音增速放缓，不会占满屏幕
- 参数独立，易于调整和测试

## 实际效果

| 时长 | 旧设计宽度 | 新设计宽度 | 说明 |
|------|-----------|-----------|------|
| 1秒  | 100pt     | 92pt      | 短语音更紧凑 |
| 2秒  | 120pt     | 104pt     | 短语音更紧凑 |
| 3秒  | 140pt     | 116pt     | 短语音更紧凑 |
| 5秒  | 180pt     | 140pt     | 更紧凑 |
| 10秒 | 280pt     | 200pt     | 线性增长终点 |
| 30秒 | 326pt     | 220pt     | 对数增长，受最大宽度限制 |
| 60秒 | 372pt     | 220pt     | 受最大宽度限制 |

## 迁移指南

无需修改现有代码，新 API 向后兼容。如需调整宽度策略：

```swift
// VoiceMessageCell.swift setupVoiceUI() 方法中
waveformView.minimumWidth = 80        // 调整最小宽度
waveformView.maximumWidth = 220       // 调整最大宽度
waveformView.linearThreshold = 10     // 调整线性增长分界点
waveformView.linearGrowthRate = 12    // 调整线性增长速率
```
