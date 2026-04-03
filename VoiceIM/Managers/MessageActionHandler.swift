import UIKit

/// 消息交互处理器：统一处理长按菜单、删除、撤回、重试等操作
///
/// # 职责
/// - 显示消息长按菜单（撤回/删除）
/// - 处理消息删除逻辑（停止播放、触发回调）
/// - 处理消息撤回逻辑（停止播放、触发回调）
/// - 处理消息重试逻辑（发送失败后重新发送）
/// - 处理撤回消息点击（文本消息重新编辑）
///
/// # 设计考量
/// 将所有消息交互逻辑从 ViewController 中提取出来，通过回调与 ViewController 通信。
/// ViewController 只需在初始化时设置回调，无需关心具体的交互细节。
///
/// # 撤回规则
/// - 仅自己发送的消息可撤回
/// - 发送状态必须为 .delivered（已送达）
/// - 发送时间在 3 分钟以内
@MainActor
final class MessageActionHandler {

    // MARK: - Dependencies

    weak var viewController: UIViewController?
    private let player: VoicePlaybackManager

    // MARK: - Callbacks

    /// 删除消息回调
    /// 参数：消息 ID
    var onDelete: ((UUID) -> Void)?

    /// 撤回消息回调
    /// 参数：消息 ID
    var onRecall: ((UUID) -> Void)?

    /// 重试消息回调
    /// 参数：消息 ID
    var onRetry: ((UUID) -> Void)?

    /// 撤回消息点击回调（用于重新编辑文本）
    /// 参数：撤回消息对象
    var onRecalledMessageTap: ((ChatMessage) -> Void)?

    // MARK: - Init

    init(player: VoicePlaybackManager = .shared) {
        self.player = player
    }

    // MARK: - Public Methods

    /// 处理消息长按事件
    ///
    /// 显示 UIAlertController 菜单，根据消息状态动态显示可用操作：
    /// - 撤回：仅自己发送、已送达、3 分钟内的消息
    /// - 删除：所有消息均可删除
    ///
    /// - Parameter message: 被长按的消息
    func handleLongPress(on message: ChatMessage) {
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)

        // 撤回条件判断（同时满足）：
        // 1. 自己发送的消息（isOutgoing = true）
        // 2. 发送状态为 .delivered（已送达，排除发送中和失败的消息）
        // 3. 发送时间在 3 分钟以内
        let canRecall = message.isOutgoing
            && message.sendStatus == .delivered
            && Date().timeIntervalSince(message.sentAt) <= 3 * 60

        if canRecall {
            sheet.addAction(UIAlertAction(title: "撤回", style: .default) { [weak self] _ in
                self?.recallMessage(message.id)
            })
        }

        sheet.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            self?.deleteMessage(message.id)
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))

        viewController?.present(sheet, animated: true)
    }

    /// 删除消息
    ///
    /// 删除前先停止播放（若正在播放该消息），避免播放器持有悬空 URL。
    /// 实际删除逻辑由 ViewController 通过 onDelete 回调处理。
    ///
    /// - Parameter id: 消息 ID
    func deleteMessage(_ id: UUID) {
        // 正在播放该条消息时先停止，避免播放器持有悬空 URL
        if player.isPlaying(id: id) {
            player.stopCurrent()
        }
        onDelete?(id)
    }

    /// 撤回消息
    ///
    /// 撤回前先停止播放（若正在播放该消息）。
    /// 实际撤回逻辑由 ViewController 通过 onRecall 回调处理。
    ///
    /// - Parameter id: 消息 ID
    func recallMessage(_ id: UUID) {
        // 正在播放该条消息时先停止
        if player.isPlaying(id: id) {
            player.stopCurrent()
        }
        onRecall?(id)
    }

    /// 重试发送失败的消息
    ///
    /// 实际重试逻辑由 ViewController 通过 onRetry 回调处理：
    /// 1. 删除失败的消息
    /// 2. 根据消息类型重新创建新消息
    /// 3. 追加到列表底部并触发发送
    ///
    /// - Parameter id: 消息 ID
    func retryMessage(_ id: UUID) {
        onRetry?(id)
    }

    /// 处理撤回消息点击
    ///
    /// 仅文本消息撤回后可重新编辑：
    /// 1. 检查是否为撤回消息且有原文本内容
    /// 2. 检查是否为自己发送的消息
    /// 3. 触发回调，由 ViewController 填充文本到输入框
    ///
    /// - Parameter message: 撤回消息对象
    func handleRecalledMessageTap(_ message: ChatMessage) {
        guard case .recalled(let originalText) = message.kind,
              let _ = originalText,
              message.isOutgoing else { return }

        onRecalledMessageTap?(message)
    }
}
