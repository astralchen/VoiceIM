import UIKit

/// 消息 Cell 统一配置协议。
///
/// 每种消息类型的 Cell 均需实现此协议，由 DiffableDataSource cell provider 统一调用，
/// 避免 provider 内出现随消息类型增长的 switch 分支。
///
/// # 新增消息类型步骤
/// 1. 创建 Cell 类，在 extension 中实现本协议
/// 2. 在 `ChatMessage.Kind.reuseID` 追加对应 `case`（编译器会提示遗漏）
/// 3. 在 `VoiceChatViewController.setupCollectionView` 调用 `NewCell.register(in:)`
@MainActor
protocol MessageCellConfigurable: AnyObject {

    static var reuseID: String { get }

    /// 统一配置入口，由 cell provider 调用。
    /// `deps` 提供 cell 可能需要的外部上下文，不需要的字段直接忽略即可。
    func configure(with message: ChatMessage, deps: MessageCellDependencies)
}

extension MessageCellConfigurable where Self: UICollectionViewCell {

    /// 将本 Cell 类型注册到指定 collectionView。
    /// 通过泛型约束自动推断类型与 reuseID，无需手动传参。
    static func register(in collectionView: UICollectionView) {
        collectionView.register(Self.self, forCellWithReuseIdentifier: reuseID)
    }
}

/// Cell provider 向各 Cell 传递的外部依赖。
///
/// 将依赖聚合成一个结构体，好处是：
/// - 协议签名固定为 `configure(with:deps:)`，不因新依赖而变动
/// - 各 Cell 只取用自己关心的字段，其余字段无需感知
struct MessageCellDependencies {

    /// 查询某条消息当前是否正在播放
    let isPlaying: (UUID) -> Bool

    /// 是否在此消息上方显示时间分隔行（由 ViewController 根据与上一条消息的时间差计算）
    let showTimeHeader: Bool

    /// 语音 Cell 的事件委托；文本等其他 Cell 忽略此字段
    weak var voiceDelegate: VoiceMessageCellDelegate?

    /// 图片 Cell 的事件委托
    weak var imageDelegate: ImageMessageCellDelegate?

    /// 视频 Cell 的事件委托
    weak var videoDelegate: VideoMessageCellDelegate?

    /// 位置 Cell 的事件委托
    weak var locationDelegate: LocationMessageCellDelegate?

    /// 文本消息中链接点击的回调（URL、电话号等）
    var onLinkTapped: ((URL, NSTextCheckingResult.CheckingType) -> Void)?
}
