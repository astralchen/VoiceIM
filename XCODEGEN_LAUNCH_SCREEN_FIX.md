# XcodeGen Launch Screen 配置修复

## 问题描述

每次运行 `xcodegen generate` 后，Launch Screen 配置会丢失。

## 原因

XcodeGen 默认不会自动添加 `UILaunchStoryboardName` 到 Info.plist，需要在 `project.yml` 中明确配置。

## 解决方案

在 `project.yml` 的 `info.properties` 中添加 `UILaunchStoryboardName` 配置：

```yaml
targets:
  VoiceIM:
    type: application
    platform: iOS
    info:
      path: VoiceIM/Info.plist
      properties:
        NSMicrophoneUsageDescription: "需要麦克风权限以录制语音消息"
        UIApplicationSupportsMultipleScenes: false
        UIApplicationSceneManifest:
          UIApplicationSupportsMultipleScenes: false
          UISceneConfigurations:
            UIWindowSceneSessionRoleApplication:
              - UISceneConfigurationName: Default Configuration
                UISceneDelegateClassName: $(PRODUCT_MODULE_NAME).SceneDelegate
        UILaunchStoryboardName: "Launch Screen"  # ← 添加这一行
        UISupportedInterfaceOrientations:
          - UIInterfaceOrientationPortrait
        UIRequiredDeviceCapabilities:
          - armv7
```

## 验证

运行以下命令验证配置：

```bash
# 重新生成项目
xcodegen generate

# 检查 Info.plist 中是否包含 Launch Screen 配置
grep -A 2 "UILaunchStoryboardName" VoiceIM/Info.plist
```

预期输出：
```xml
<key>UILaunchStoryboardName</key>
<string>Launch Screen</string>
```

## 注意事项

1. **Storyboard 文件名**：确保 `VoiceIM/Launch Screen.storyboard` 文件存在
2. **名称匹配**：`UILaunchStoryboardName` 的值必须与 storyboard 文件名一致（不含 `.storyboard` 扩展名）
3. **空格处理**：文件名中的空格需要保留（如 "Launch Screen"）

## 其他 Launch Screen 配置选项

### 使用 LaunchScreen.storyboard（推荐）

```yaml
UILaunchStoryboardName: "LaunchScreen"
```

### 使用 Assets Catalog（iOS 14+）

```yaml
UILaunchScreen:
  UIImageName: "LaunchImage"
  UIColorName: "LaunchBackgroundColor"
```

### 使用纯色背景（iOS 14+）

```yaml
UILaunchScreen:
  UIColorName: "SystemBackgroundColor"
```

## 常见问题

### Q: 为什么 Launch Screen 还是不显示？

**A**: 检查以下几点：
1. Storyboard 文件是否在 `sources` 路径中
2. 文件名是否完全匹配（包括大小写和空格）
3. 清理 Xcode 缓存：`rm -rf ~/Library/Developer/Xcode/DerivedData`
4. 删除并重新安装 App

### Q: 可以使用 XIB 文件吗？

**A**: 不推荐。iOS 13+ 推荐使用 Storyboard 或 Assets Catalog。

### Q: 如何禁用 Launch Screen？

**A**: 移除 `UILaunchStoryboardName` 配置，但不推荐这样做，因为 App Store 要求提供 Launch Screen。

## 相关文档

- [XcodeGen 官方文档](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md)
- [Apple Launch Screen 指南](https://developer.apple.com/design/human-interface-guidelines/launch-screen)

## 总结

✅ 在 `project.yml` 中添加 `UILaunchStoryboardName: "Launch Screen"`  
✅ 每次运行 `xcodegen generate` 后配置会自动保留  
✅ 无需手动修改 Info.plist
