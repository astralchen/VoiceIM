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
    /// - Parameters:
    ///   - message: 消息数据
    ///   - deps: 外部依赖（播放状态、委托等，整个会话期间不变）
    ///   - context: 动态上下文（每个 Cell 计算时确定的状态信息）
    func configure(with message: ChatMessage, deps: MessageCellDependencies, context: MessageCellContext)
}

extension MessageCellConfigurable where Self: UICollectionViewCell {

    /// 将本 Cell 类型注册到指定 collectionView。
    /// 通过泛型约束自动推断类型与 reuseID，无需手动传参。
    static func register(in collectionView: UICollectionView) {
        collectionView.register(Self.self, forCellWithReuseIdentifier: reuseID)
    }
}

/// Cell 外部依赖（静态，整个会话期间不变）
///
/// 包含 Cell 需要的外部能力：
/// - 播放状态查询函数
/// - 各类型 Cell 的事件委托
/// - 链接点击回调
struct MessageCellDependencies {

    /// 查询某条消息当前是否正在播放
    let isPlaying: (UUID) -> Bool

    /// 查询某条消息当前播放进度（0~1）
    let currentProgress: (UUID) -> Float

    /// 正在播放时由解码器得到的总时长（秒）；未播放或非当前消息为 0
    let playbackDuration: (UUID) -> TimeInterval

    /// 正在播放时由播放器计算的剩余时长（秒）；未播放或非当前消息为 0
    let playbackRemaining: (UUID) -> TimeInterval

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

/// Cell 动态上下文（每个 Cell 计算时确定）
///
/// 包含根据当前消息和上下文计算出的状态信息：
/// - 是否显示时间分隔行
/// - 上一条消息（用于某些 Cell 的特殊逻辑）
struct MessageCellContext {

    /// 是否在此消息上方显示时间分隔行（由 MessageDataSource 根据与上一条消息的时间差计算）
    let showTimeHeader: Bool

    /// 上一条消息（可选，用于某些 Cell 需要对比上下文的场景）
    let previousMessage: ChatMessage?
}
