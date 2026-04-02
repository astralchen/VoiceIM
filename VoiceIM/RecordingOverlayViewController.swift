import UIKit

/// 录音浮层容器控制器
///
/// 通过 `present(_:animated:)` 呈现，`modalPresentationStyle = .custom`。
/// `RecordingOverlayPresentationController` 负责：
///   - 将浮层定位在屏幕底部，高度固定为 `overlayHeight`
///   - 在浮层上方添加半透明遮罩（dimmingView），随转场淡入淡出
@MainActor
final class RecordingOverlayViewController: UIViewController {

    private let overlayView = RecordingOverlayView()

    /// 强持有 transitioningDelegate：UIViewController 对其只保持弱引用，
    /// 不自行持有会导致转场开始时 delegate 已被释放。
    private let transitionDelegate = RecordingOverlayTransitionDelegate()

    override func loadView() {
        view = overlayView
    }

    override init(nibName: String?, bundle: Bundle?) {
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .custom
        transitioningDelegate = transitionDelegate
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 公共接口（代理给 overlayView）

    func setState(_ state: RecordingOverlayView.State) {
        overlayView.setState(state)
    }

    func updateSeconds(_ seconds: Int) {
        overlayView.updateSeconds(seconds)
    }
}

// MARK: - Transitioning Delegate

private final class RecordingOverlayTransitionDelegate: NSObject, UIViewControllerTransitioningDelegate {

    func presentationController(forPresented presented: UIViewController,
                                presenting: UIViewController?,
                                source: UIViewController) -> UIPresentationController? {
        RecordingOverlayPresentationController(presentedViewController: presented,
                                               presenting: presenting)
    }

    func animationController(forPresented presented: UIViewController,
                             presenting: UIViewController,
                             source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        RecordingOverlayPresentAnimator()
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        RecordingOverlayDismissAnimator()
    }
}

// MARK: - Presentation Controller

/// 保持呈现方视图可见（浮层含半透明背景，需透出下方聊天内容），浮层充满容器。
private final class RecordingOverlayPresentationController: UIPresentationController {

    override var shouldRemovePresentersView: Bool { false }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        presentedView?.frame = containerView?.bounds ?? .zero
    }
}

// MARK: - 呈现动画：淡入

private final class RecordingOverlayPresentAnimator: NSObject, UIViewControllerAnimatedTransitioning {

    func transitionDuration(using ctx: UIViewControllerContextTransitioning?) -> TimeInterval { 0.25 }

    func animateTransition(using ctx: UIViewControllerContextTransitioning) {
        // custom presentation 下 ctx.view(forKey:) 可能返回 nil，回退到 VC.view
        let toView = ctx.view(forKey: .to) ?? ctx.viewController(forKey: .to)?.view
        guard let toView else { ctx.completeTransition(false); return }

        let container = ctx.containerView
        container.addSubview(toView)
        // 触发 PresentationController.containerViewWillLayoutSubviews，
        // 在动画开始前把浮层 frame 定位到底部 118pt
        container.layoutIfNeeded()

        toView.alpha = 0
        UIView.animate(withDuration: transitionDuration(using: ctx)) {
            toView.alpha = 1
        } completion: { _ in
            ctx.completeTransition(!ctx.transitionWasCancelled)
        }
    }
}

// MARK: - 消失动画：淡出

private final class RecordingOverlayDismissAnimator: NSObject, UIViewControllerAnimatedTransitioning {

    func transitionDuration(using ctx: UIViewControllerContextTransitioning?) -> TimeInterval { 0.2 }

    func animateTransition(using ctx: UIViewControllerContextTransitioning) {
        let fromView = ctx.view(forKey: .from) ?? ctx.viewController(forKey: .from)?.view
        guard let fromView else { ctx.completeTransition(false); return }
        UIView.animate(withDuration: transitionDuration(using: ctx)) {
            fromView.alpha = 0
        } completion: { _ in
            ctx.completeTransition(!ctx.transitionWasCancelled)
        }
    }
}
