import UIKit

/// 消息 Cell 交互能力协议
///
/// 定义 Cell 可能需要的交互回调设置接口，
/// 通过协议统一配置，避免 ViewController 中出现类型判断。
@MainActor
protocol MessageCellInteractive: AnyObject {

    /// 设置重试按钮点击回调（用于发送失败的消息）
    func setRetryHandler(_ handler: @escaping () -> Void)

    /// 设置上下文菜单提供者（长按菜单）
    func setContextMenuProvider(_ provider: @escaping (ChatMessage) -> UIMenu?)
}

/// 为不需要交互的 Cell 提供默认空实现
extension MessageCellInteractive {
    func setRetryHandler(_ handler: @escaping () -> Void) {}
    func setContextMenuProvider(_ provider: @escaping (ChatMessage) -> UIMenu?) {}
}

/// 撤回消息 Cell 交互协议
@MainActor
protocol RecalledMessageCellInteractive: AnyObject {

    /// 设置撤回消息点击回调（用于重新编辑）
    func setTapHandler(_ handler: @escaping () -> Void)
}

extension RecalledMessageCellInteractive {
    func setTapHandler(_ handler: @escaping () -> Void) {}
}
