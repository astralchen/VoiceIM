import UIKit

/// 键盘管理器：处理键盘显示/隐藏时的布局调整
///
/// # 职责
/// - 监听键盘通知（UIResponder.keyboardWillChangeFrameNotification）
/// - 调整输入栏底部约束，避免被键盘遮挡
/// - 在键盘动画结束后滚动列表到底部（若用户在底部附近）
///
/// # 布局调整原理
/// 键盘显示时，将输入栏底部约束从 `-safeAreaInsets.bottom` 调整到 `-keyboardHeight`。
/// 键盘隐藏时，恢复到 `-safeAreaInsets.bottom`。
/// 使用键盘动画的 duration 和 curve 保持动画同步。
///
/// # 滚动策略
/// 仅当用户在底部附近时才滚动到底部，避免打断用户浏览历史消息。
/// 通过 `isNearBottom` 回调判断，通过 `scrollToBottom` 回调执行滚动。
///
/// # 设计考量
/// 将键盘处理逻辑从 ViewController 中提取出来，通过回调与 ViewController 通信。
/// ViewController 只需在初始化时设置回调，无需关心键盘通知的具体处理。
@MainActor
final class KeyboardManager {

    // MARK: - Properties

    private weak var scrollView: UIScrollView?
    private weak var inputViewBottomConstraint: NSLayoutConstraint?
    private let safeAreaProvider: () -> UIEdgeInsets

    /// 判断是否在底部附近的回调
    /// 返回 true 表示用户在底部附近，键盘动画结束后应滚动到底部
    var isNearBottom: (() -> Bool)?

    /// 滚动到底部的回调
    /// 键盘动画结束后调用，由 ViewController 实现具体的滚动逻辑
    var scrollToBottom: (() -> Void)?

    // MARK: - Init

    /// 初始化键盘管理器
    ///
    /// - Parameters:
    ///   - scrollView: 需要调整 contentInset 的 UIScrollView（通常是 UICollectionView）
    ///   - inputViewBottomConstraint: 输入栏底部约束（需要根据键盘高度调整）
    ///   - safeAreaProvider: 提供安全区域 insets 的闭包（通常是 view.safeAreaInsets）
    init(scrollView: UIScrollView,
         inputViewBottomConstraint: NSLayoutConstraint,
         safeAreaProvider: @escaping () -> UIEdgeInsets) {
        self.scrollView = scrollView
        self.inputViewBottomConstraint = inputViewBottomConstraint
        self.safeAreaProvider = safeAreaProvider
    }

    // MARK: - Public Methods

    /// 开始监听键盘通知
    func startObserving() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil)
    }

    /// 停止监听键盘通知
    func stopObserving() {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Private Methods

    /// 键盘 frame 变化通知处理
    ///
    /// 从通知中提取键盘信息：
    /// - endFrame：键盘最终位置
    /// - duration：动画时长
    /// - curve：动画曲线
    ///
    /// 计算键盘高度并调整输入栏底部约束：
    /// - 键盘显示：offset = -keyboardHeight
    /// - 键盘隐藏：offset = -safeAreaInsets.bottom
    ///
    /// 动画结束后，若用户在底部附近则滚动到底部。
    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let endFrame = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
            let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue,
            let curveRaw = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue,
            let scrollView = scrollView,
            let constraint = inputViewBottomConstraint
        else { return }

        // 计算键盘高度
        // 键盘完全收起时 endFrame.minY == 屏幕底部
        // 使用 scrollView 的 bounds 高度代替 UIScreen.main（iOS 16+ 废弃）
        let viewHeight = scrollView.window?.bounds.height ?? scrollView.bounds.height
        let keyboardHeight = max(viewHeight - endFrame.minY, 0)

        // 键盘遮挡高度 = 键盘高度 - 安全区域底部
        // （输入栏已超出安全区，不能重复计算）
        let safeInsets = safeAreaProvider()
        let offset = keyboardHeight > 0
            ? -keyboardHeight
            : -safeInsets.bottom

        let shouldScroll = isNearBottom?() ?? false
        let options = UIView.AnimationOptions(rawValue: curveRaw << 16)

        UIView.animate(withDuration: duration, delay: 0, options: options) {
            constraint.constant = offset
            scrollView.superview?.layoutIfNeeded()
        } completion: { _ in
            if shouldScroll {
                self.scrollToBottom?()
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
