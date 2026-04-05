import UIKit

// MARK: - ZoomTransitionTarget

/// 支持缩放转场的预览页实现此协议，向控制器提供内容视图、展示区域和手势开关。
@MainActor
protocol ZoomTransitionTarget: AnyObject {
    /// 转场期间需要隐藏的内容视图（由飞行快照代替显示）
    var zoomContentView: UIView { get }
    /// 当前内容在 `self.view` 坐标系中的展示区域，作为关闭动画的起始 frame
    var zoomDisplayFrame: CGRect { get }
    /// 是否允许当前开始下滑关闭手势（子类根据内部状态决定，默认 `true`）
    var zoomDismissGestureEnabled: Bool { get }
}

extension ZoomTransitionTarget {
    var zoomDismissGestureEnabled: Bool { true }
}

// MARK: - ZoomTransitionController

/// 苹果相册风格的缩放转场控制器
///
/// 负责打开/关闭动画与下滑交互关闭的全部逻辑，预览页只需实现 `ZoomTransitionTarget`。
///
/// 典型用法：
/// ```swift
/// let tc = ZoomTransitionController(sourceView: cell.bubble, sourceImage: image)
/// zoomTransitionController = tc          // 保持强引用
/// tc.attach(to: previewVC)               // 配置转场代理与展示样式
/// present(previewVC, animated: true)     // 标准 UIKit 展示
/// ```
@MainActor
final class ZoomTransitionController: NSObject {

    // MARK: - 公开属性

    /// 来源视图（消息气泡），提供起止 frame 和圆角半径
    private(set) weak var sourceView: UIView?

    /// 转场动画中使用的缩略图
    let sourceImage: UIImage?

    // MARK: - 私有状态

    private var isPresenting = true
    private weak var presentedViewController: UIViewController?
    private var isDismissing = false

    // MARK: - 初始化

    init(sourceView: UIView, sourceImage: UIImage?) {
        self.sourceView = sourceView
        self.sourceImage = sourceImage
    }

    // MARK: - 公开 API

    /// 将转场控制器绑定到目标 VC。
    ///
    /// 内部自动完成以下操作，调用方无需再设置任何属性：
    /// - 设置 `transitioningDelegate` 和 `modalPresentationStyle = .custom`
    /// - 将控制器以关联对象形式存储在目标 VC 上，生命周期随 VC 自动管理
    /// - 展示动画完成后自动安装下滑关闭手势
    func attach(to viewController: UIViewController) {
        viewController.transitioningDelegate  = self
        viewController.modalPresentationStyle = .custom
        presentedViewController = viewController
        // 通过关联对象持有自身——VC 释放时控制器随之释放，调用方无需保存强引用
        viewController.zoomTransitionRetained = self
    }
}

// MARK: - UIViewControllerTransitioningDelegate

extension ZoomTransitionController: UIViewControllerTransitioningDelegate {

    func animationController(
        forPresented presented: UIViewController,
        presenting: UIViewController,
        source: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        isPresenting = true
        return self
    }

    func animationController(
        forDismissed dismissed: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        isPresenting = false
        return self
    }
}

// MARK: - UIViewControllerAnimatedTransitioning

extension ZoomTransitionController: UIViewControllerAnimatedTransitioning {

    func transitionDuration(using ctx: UIViewControllerContextTransitioning?) -> TimeInterval {
        isPresenting ? 0.38 : 0.30
    }

    func animateTransition(using ctx: UIViewControllerContextTransitioning) {
        isPresenting ? animatePresent(ctx) : animateDismiss(ctx)
    }

    // MARK: Present

    private func animatePresent(_ ctx: UIViewControllerContextTransitioning) {
        guard
            let toVC   = ctx.viewController(forKey: .to),
            let toView = ctx.view(forKey: .to)
        else { ctx.completeTransition(false); return }

        let container  = ctx.containerView
        let finalFrame = ctx.finalFrame(for: toVC)

        toView.frame           = finalFrame
        toView.backgroundColor = .clear
        container.addSubview(toView)

        guard
            let src      = sourceView,
            let srcFrame = src.superview?.convert(src.frame, to: container),
            srcFrame.width > 0
        else {
            // 源视图不可用：退路淡入
            UIView.animate(withDuration: transitionDuration(using: ctx)) {
                toView.backgroundColor = .black
            } completion: { _ in
                ctx.completeTransition(!ctx.transitionWasCancelled)
            }
            return
        }

        let target = toVC as? ZoomTransitionTarget
        target?.zoomContentView.alpha = 0                       // 内容视图由快照代替

        let destFrame = aspectFitFrame(for: sourceImage?.size, in: finalFrame)
        let snapshot  = makeSnapshot(frame: srcFrame, cornerRadius: src.layer.cornerRadius)
        container.addSubview(snapshot)
        src.alpha = 0                                           // 隐藏源视图避免重影

        UIView.animate(
            withDuration: transitionDuration(using: ctx),
            delay: 0,
            usingSpringWithDamping: 0.88,
            initialSpringVelocity: 0.15,
            options: [.curveEaseInOut],
            animations: {
                snapshot.frame              = destFrame
                snapshot.layer.cornerRadius = 0
                toView.backgroundColor      = .black
            },
            completion: { [weak self] _ in
                src.alpha = 1
                target?.zoomContentView.alpha = 1
                snapshot.removeFromSuperview()
                ctx.completeTransition(!ctx.transitionWasCancelled)
                // 展示完成后安装下滑手势，手势由控制器统一管理
                self?.installDismissGesture(on: toVC)
            }
        )
    }

    // MARK: Dismiss

    private func animateDismiss(_ ctx: UIViewControllerContextTransitioning) {
        guard
            let fromVC   = ctx.viewController(forKey: .from),
            let fromView = ctx.view(forKey: .from)
        else { ctx.completeTransition(false); return }

        let container    = ctx.containerView
        let displayFrame = (fromVC as? ZoomTransitionTarget)?.zoomDisplayFrame
        let startFrame   = displayFrame.map { fromVC.view.convert($0, to: container) } ?? fromView.frame

        let snapshot = makeSnapshot(frame: startFrame, cornerRadius: 0)
        container.addSubview(snapshot)
        fromView.alpha = 0

        let src        = sourceView
        let srcVisible = src?.window != nil && src?.isHidden == false && (src?.alpha ?? 0) > 0

        let targetFrame: CGRect
        let targetRadius: CGFloat

        if srcVisible,
           let sv = src,
           let destFrame = sv.superview?.convert(sv.frame, to: container),
           destFrame.width > 0 {
            targetFrame  = destFrame
            targetRadius = sv.layer.cornerRadius
            sv.alpha     = 0
        } else {
            let cx = startFrame.midX, cy = startFrame.midY
            targetFrame  = CGRect(x: cx - 4, y: cy - 4, width: 8, height: 8)
            targetRadius = 4
        }

        UIView.animate(
            withDuration: transitionDuration(using: ctx),
            delay: 0,
            usingSpringWithDamping: 0.90,
            initialSpringVelocity: 0.10,
            options: [.curveEaseInOut],
            animations: {
                snapshot.frame              = targetFrame
                snapshot.layer.cornerRadius = targetRadius
                if !srcVisible { snapshot.alpha = 0 }
                fromView.backgroundColor    = .clear
            },
            completion: { [weak self] _ in
                if srcVisible { self?.sourceView?.alpha = 1 }
                snapshot.removeFromSuperview()
                fromView.removeFromSuperview()
                ctx.completeTransition(!ctx.transitionWasCancelled)
            }
        )
    }
}

// MARK: - 下滑交互关闭

extension ZoomTransitionController {

    private func installDismissGesture(on viewController: UIViewController) {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
        pan.delegate = self
        viewController.view.addGestureRecognizer(pan)
    }

    @objc private func handleDismissPan(_ pan: UIPanGestureRecognizer) {
        guard let vc = presentedViewController else { return }

        let translation = pan.translation(in: vc.view)
        let ty          = max(0, translation.y)
        let progress    = min(ty / 280, 1.0)

        switch pan.state {
        case .began:
            isDismissing = true

        case .changed:
            guard isDismissing else { return }
            let scale = 1.0 - progress * 0.28
            vc.view.transform      = CGAffineTransform(translationX: translation.x * 0.35, y: ty)
                .scaledBy(x: scale, y: scale)
            vc.view.backgroundColor = UIColor.black.withAlphaComponent(max(0, 1.0 - progress * 1.8))

        case .ended, .cancelled:
            guard isDismissing else { return }
            isDismissing = false

            let velocity      = pan.velocity(in: vc.view)
            let shouldDismiss = ty > 80 || velocity.y > 700

            if shouldDismiss {
                completeDismissPan(vc: vc)
            } else {
                UIView.animate(
                    withDuration: 0.38, delay: 0,
                    usingSpringWithDamping: 0.75, initialSpringVelocity: 0.2
                ) {
                    vc.view.transform       = .identity
                    vc.view.backgroundColor = .black
                }
            }

        default:
            isDismissing = false
        }
    }

    /// 手势确认关闭：将内容快照动画回源气泡，再无动画 dismiss
    private func completeDismissPan(vc: UIViewController) {
        guard let window = vc.view.window else { vc.dismiss(animated: false); return }

        // 当前展示区域在窗口坐标中的 frame（含 vc.view.transform 变换）
        let displayFrame: CGRect = {
            if let target = vc as? ZoomTransitionTarget {
                return vc.view.convert(target.zoomDisplayFrame, to: window)
            }
            return vc.view.convert(vc.view.bounds, to: window)
        }()

        // 快照挂到 window 上，确保在 dismiss 过程中仍可见
        let snapshot = makeSnapshot(frame: displayFrame, cornerRadius: 0)
        window.addSubview(snapshot)

        vc.view.isHidden  = true
        vc.view.transform = .identity

        let srcVisible = sourceView?.window != nil
            && sourceView?.isHidden == false
            && (sourceView?.alpha ?? 0) > 0

        let targetFrame: CGRect
        let targetRadius: CGFloat

        if srcVisible,
           let sv = sourceView,
           let destFrame = sv.superview?.convert(sv.frame, to: window),
           destFrame.width > 0 {
            targetFrame  = destFrame
            targetRadius = sv.layer.cornerRadius
            sv.alpha     = 0
        } else {
            let c        = CGPoint(x: displayFrame.midX, y: displayFrame.midY)
            targetFrame  = CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)
            targetRadius = 4
        }

        UIView.animate(
            withDuration: 0.32, delay: 0,
            usingSpringWithDamping: 0.9, initialSpringVelocity: 0.3,
            options: [.curveEaseInOut],
            animations: {
                snapshot.frame              = targetFrame
                snapshot.layer.cornerRadius = targetRadius
                if !srcVisible { snapshot.alpha = 0 }
            },
            completion: { [weak self] _ in
                if srcVisible { self?.sourceView?.alpha = 1 }
                snapshot.removeFromSuperview()
                vc.view.isHidden = false
                vc.dismiss(animated: false)
            }
        )
    }
}

// MARK: - UIGestureRecognizerDelegate

extension ZoomTransitionController: UIGestureRecognizerDelegate {

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard
            let pan = gestureRecognizer as? UIPanGestureRecognizer,
            let vc  = presentedViewController
        else { return true }

        // 询问 VC 当前是否允许关闭手势（如 ImagePreview 可根据缩放比返回 false）
        if let target = vc as? ZoomTransitionTarget, !target.zoomDismissGestureEnabled {
            return false
        }

        let v = pan.velocity(in: vc.view)
        return v.y > 0 && abs(v.y) > abs(v.x)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }
}

// MARK: - UIViewController 关联对象（内部存储，仅 ZoomTransitionController 使用）

private extension UIViewController {
    /// 关联对象键——nonisolated(unsafe) 满足 Swift 6 并发检查要求
    nonisolated(unsafe) static var zoomRetainKey: UInt8 = 0

    /// 以 RETAIN 策略将 ZoomTransitionController 附着在 VC 上，生命周期与 VC 绑定
    var zoomTransitionRetained: ZoomTransitionController? {
        get { objc_getAssociatedObject(self, &Self.zoomRetainKey) as? ZoomTransitionController }
        set { objc_setAssociatedObject(self, &Self.zoomRetainKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

// MARK: - Helpers

private extension ZoomTransitionController {

    func makeSnapshot(frame: CGRect, cornerRadius: CGFloat) -> UIImageView {
        let iv = UIImageView(image: sourceImage)
        iv.contentMode       = .scaleAspectFill
        iv.clipsToBounds     = true
        iv.frame             = frame
        iv.layer.cornerRadius = cornerRadius
        return iv
    }

    func aspectFitFrame(for size: CGSize?, in box: CGRect) -> CGRect {
        guard let size, size.width > 0, size.height > 0 else { return box }
        let ia = size.width / size.height
        let ba = box.width  / box.height
        let w: CGFloat = ia > ba ? box.width       : box.height * ia
        let h: CGFloat = ia > ba ? box.width / ia  : box.height
        return CGRect(
            x: box.minX + (box.width  - w) / 2,
            y: box.minY + (box.height - h) / 2,
            width: w, height: h
        )
    }
}
