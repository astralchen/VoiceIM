import UIKit

/// 错误处理器：统一处理错误展示
///
/// 根据错误类型和严重程度选择合适的展示方式：
/// - Toast：轻量级提示（info/warning）
/// - Alert：需要用户确认的错误（error）
/// - Banner：持续显示的严重错误（critical）
final class ErrorHandler {

    // MARK: - Singleton

    nonisolated(unsafe) static let shared = ErrorHandler()

    private init() {}

    // MARK: - Public Methods (MainActor isolated)

    /// 处理错误并展示给用户
    ///
    /// - Parameters:
    ///   - error: 错误对象
    ///   - in view: 展示错误的视图
    ///   - completion: 错误处理完成后的回调
    @MainActor
    func handle(_ error: Error, in view: UIView, completion: (() -> Void)? = nil) {
        // 转换为 ChatError
        let chatError: ChatError
        if let err = error as? ChatError {
            chatError = err
        } else {
            chatError = .unknown(error)
        }

        // 记录日志
        if chatError.shouldLog {
            logError(chatError)
        }

        // 根据严重程度选择展示方式
        switch chatError.severity {
        case .info:
            showToast(chatError, in: view, completion: completion)
        case .warning:
            showToast(chatError, in: view, completion: completion)
        case .error:
            showAlert(chatError, in: view, completion: completion)
        case .critical:
            showAlert(chatError, in: view, completion: completion)
        }
    }

    /// 处理错误并展示给用户（ViewController 版本）
    ///
    /// - Parameters:
    ///   - error: 错误对象
    ///   - in viewController: 展示错误的视图控制器
    ///   - completion: 错误处理完成后的回调
    @MainActor
    func handle(_ error: Error, in viewController: UIViewController, completion: (() -> Void)? = nil) {
        handle(error, in: viewController.view, completion: completion)
    }

    // MARK: - Private Methods

    /// 显示 Toast 提示
    @MainActor
    private func showToast(_ error: ChatError, in view: UIView, completion: (() -> Void)?) {
        let message = error.errorDescription ?? "未知错误"
        ToastView.show(message, in: view)
        completion?()
    }

    /// 显示 Alert 对话框
    @MainActor
    private func showAlert(_ error: ChatError, in view: UIView, completion: (() -> Void)?) {
        guard let viewController = view.findViewController() else {
            // 如果找不到 ViewController，降级为 Toast
            showToast(error, in: view, completion: completion)
            return
        }

        let title = "错误"
        let message = [
            error.errorDescription,
            error.recoverySuggestion
        ].compactMap { $0 }.joined(separator: "\n\n")

        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in
            Task { @MainActor in
                completion?()
            }
        })

        viewController.present(alert, animated: true)
    }

    /// 记录错误日志
    private func logError(_ error: ChatError) {
        VoiceIM.logger.error("\(error.errorDescription ?? "Unknown error")")
        if let suggestion = error.recoverySuggestion {
            VoiceIM.logger.error("Recovery suggestion: \(suggestion)")
        }
    }
}

// MARK: - UIView Extension

private extension UIView {
    /// 查找包含此视图的 ViewController
    func findViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let nextResponder = responder?.next {
            if let viewController = nextResponder as? UIViewController {
                return viewController
            }
            responder = nextResponder
        }
        return nil
    }
}
