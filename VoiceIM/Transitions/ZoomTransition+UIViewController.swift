import UIKit

/// UIViewController 缩放转场便捷扩展
///
/// API 风格完全对齐 iOS 18 `preferredTransition = .zoom { ... }`，并自动适配系统版本：
///
/// ```swift
/// let previewVC = ImagePreviewViewController(image: image, imageURL: url)
/// previewVC.setZoomTransition(from: { [weak cell] in cell?.bubble }, image: image)
/// present(previewVC, animated: true)
/// ```
///
/// - **iOS 18+**：使用系统原生 `UIViewController.preferredTransition = .zoom`，
///   享受系统级的弹性曲线、交互式关闭手势和连续动画优化。
/// - **iOS 15–17**：自动降级到 `ZoomTransitionController` 自定义实现，
///   视觉效果与原生保持一致。
///
/// 调用后直接 `present(vc, animated: true)` 即可，**无需在调用方保存任何对象**。
@MainActor
extension UIViewController {

    /// 为当前 VC 设置缩放转场。
    ///
    /// - Parameters:
    ///   - sourceViewProvider: 返回来源视图的闭包（消息气泡、缩略图等），
    ///     打开和关闭动画均以此视图为锚点。
    ///     使用 `[weak cell]` 捕获以安全处理 Cell 复用或滚出屏幕的情况。
    ///   - image: 转场动画使用的缩略图（iOS 18+ 由系统截图，此参数仅在 iOS 15–17 生效）。
    func setZoomTransition(
        from sourceViewProvider: @escaping @MainActor () -> UIView?,
        image: UIImage? = nil
    ) {
        if #available(iOS 18, *) {
            // 使用系统原生缩放转场——系统负责弹性动画、暗色背景渐变和交互式关闭
            modalPresentationStyle = .overFullScreen
            preferredTransition    = .zoom { [sourceViewProvider] _ in sourceViewProvider() }
        } else {
            // iOS 15–17 降级：ZoomTransitionController 完整实现等效效果
            guard let sourceView = sourceViewProvider() else { return }
            let controller = ZoomTransitionController(sourceView: sourceView, sourceImage: image)
            // attach(to:) 内部通过关联对象持有控制器，调用方无需保存引用
            controller.attach(to: self)
        }
    }
}
