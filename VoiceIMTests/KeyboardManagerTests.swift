import Testing
import UIKit
@testable import VoiceIM

/// KeyboardManager 单元测试
@Suite("KeyboardManager Tests")
@MainActor
struct KeyboardManagerTests {

    // MARK: - Mock Components

    /// 创建测试用的 ScrollView
    func makeTestScrollView() -> UIScrollView {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 375, height: 667))
        scrollView.contentSize = CGSize(width: 375, height: 1000)
        return scrollView
    }

    /// 创建测试用的约束
    func makeTestConstraint() -> NSLayoutConstraint {
        let view = UIView()
        return view.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: 0)
    }

    // MARK: - Initialization Tests

    @Test("初始化 KeyboardManager")
    func testInitialization() {
        let scrollView = makeTestScrollView()
        let constraint = makeTestConstraint()

        let manager = KeyboardManager(
            scrollView: scrollView,
            inputViewBottomConstraint: constraint,
            safeAreaProvider: { UIEdgeInsets(top: 0, left: 0, bottom: 34, right: 0) }
        )

        #expect(manager != nil)
    }

    // MARK: - Observer Tests

    @Test("开始和停止监听键盘通知")
    func testStartStopObserving() {
        let scrollView = makeTestScrollView()
        let constraint = makeTestConstraint()

        let manager = KeyboardManager(
            scrollView: scrollView,
            inputViewBottomConstraint: constraint,
            safeAreaProvider: { .zero }
        )

        // 开始监听
        manager.startObserving()

        // 停止监听
        manager.stopObserving()

        // 验证没有崩溃
        #expect(true)
    }

    // MARK: - Callback Tests

    @Test("设置回调函数")
    func testCallbackSetup() {
        let scrollView = makeTestScrollView()
        let constraint = makeTestConstraint()

        let manager = KeyboardManager(
            scrollView: scrollView,
            inputViewBottomConstraint: constraint,
            safeAreaProvider: { .zero }
        )

        var isNearBottomCalled = false
        var scrollToBottomCalled = false

        manager.isNearBottom = {
            isNearBottomCalled = true
            return true
        }

        manager.scrollToBottom = {
            scrollToBottomCalled = true
        }

        // 验证回调可以被设置
        #expect(manager.isNearBottom != nil)
        #expect(manager.scrollToBottom != nil)

        // 验证回调可以被调用
        _ = manager.isNearBottom?()
        manager.scrollToBottom?()

        #expect(isNearBottomCalled)
        #expect(scrollToBottomCalled)
    }

    // MARK: - Keyboard Notification Tests

    @Test("模拟键盘显示通知")
    func testKeyboardWillShow() async {
        let scrollView = makeTestScrollView()
        let constraint = makeTestConstraint()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 667))
        window.addSubview(scrollView)

        let manager = KeyboardManager(
            scrollView: scrollView,
            inputViewBottomConstraint: constraint,
            safeAreaProvider: { UIEdgeInsets(top: 0, left: 0, bottom: 34, right: 0) }
        )

        var scrollToBottomCalled = false
        manager.isNearBottom = { true }
        manager.scrollToBottom = {
            scrollToBottomCalled = true
        }

        manager.startObserving()

        // 模拟键盘显示通知
        let keyboardHeight: CGFloat = 300
        let endFrame = CGRect(x: 0, y: 667 - keyboardHeight, width: 375, height: keyboardHeight)

        let userInfo: [AnyHashable: Any] = [
            UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: endFrame),
            UIResponder.keyboardAnimationDurationUserInfoKey: NSNumber(value: 0.25),
            UIResponder.keyboardAnimationCurveUserInfoKey: NSNumber(value: UIView.AnimationCurve.easeInOut.rawValue)
        ]

        NotificationCenter.default.post(
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            userInfo: userInfo
        )

        // 等待动画完成
        try? await Task.sleep(for: .milliseconds(300))

        // 验证约束被更新
        #expect(constraint.constant < 0)

        manager.stopObserving()
    }

    @Test("模拟键盘隐藏通知")
    func testKeyboardWillHide() async {
        let scrollView = makeTestScrollView()
        let constraint = makeTestConstraint()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 667))
        window.addSubview(scrollView)

        let safeAreaBottom: CGFloat = 34
        let manager = KeyboardManager(
            scrollView: scrollView,
            inputViewBottomConstraint: constraint,
            safeAreaProvider: { UIEdgeInsets(top: 0, left: 0, bottom: safeAreaBottom, right: 0) }
        )

        manager.startObserving()

        // 模拟键盘隐藏通知（endFrame.minY == 屏幕底部）
        let endFrame = CGRect(x: 0, y: 667, width: 375, height: 300)

        let userInfo: [AnyHashable: Any] = [
            UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: endFrame),
            UIResponder.keyboardAnimationDurationUserInfoKey: NSNumber(value: 0.25),
            UIResponder.keyboardAnimationCurveUserInfoKey: NSNumber(value: UIView.AnimationCurve.easeInOut.rawValue)
        ]

        NotificationCenter.default.post(
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            userInfo: userInfo
        )

        // 等待动画完成
        try? await Task.sleep(for: .milliseconds(300))

        // 验证约束恢复到安全区域底部
        #expect(constraint.constant == -safeAreaBottom)

        manager.stopObserving()
    }
}
