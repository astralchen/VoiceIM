import UIKit

/// 所有消息 Cell 的基类，封装三项共用能力：
///   - **时间分隔行**：与上一条消息间隔 >5 分钟时显示，高度自动折叠（不留白）
///   - **头像**：圆形颜色占位，位置随收/发方向切换
///   - **收/发方向**：自己靠右、对方靠左，通过激活/停用两套约束实现，无动画抖动
///
/// 子类只需向 `bubble` 中添加自己的内容视图，并在 `configure` 开头调用 `configureCommon`。
@MainActor
class ChatBubbleCell: UICollectionViewCell {

    // MARK: - 共用子视图

    /// 时间分隔标签，位于 cell 顶部，全宽居中
    private let timeLabel = UILabel()
    /// 发送者头像（36×36 圆形）
    let avatarView = AvatarView()
    /// 气泡容器；子类将自己的内容视图添加到此视图内
    let bubble = UIView()

    // MARK: - 状态指示器（消息发送状态展示）

    /// 发送中状态指示器：旋转的加载动画，仅在 `.sending` 状态时显示
    let statusIndicator = UIActivityIndicatorView(style: .medium)

    /// 发送失败按钮：红色感叹号图标，仅在 `.failed` 状态时显示，可点击重试
    let failedButton = UIButton(type: .system)

    /// 失败按钮点击回调：由 ViewController 在 cell provider 中设置，触发重试逻辑
    var onRetryTap: (() -> Void)?

    /// 上下文菜单提供者：由 ViewController 在 cell provider 中设置，返回菜单配置
    /// 参数：当前消息对象
    /// 返回：UIMenu 对象，包含所有菜单项
    var contextMenuProvider: ((ChatMessage) -> UIMenu?)?

    /// 当前消息对象，用于上下文菜单判断
    var currentMessage: ChatMessage?

    // MARK: - 动态约束

    /// 控制 timeLabel 高度（0 = 隐藏且不占高，28 = 显示）
    private var timeHeightConstraint: NSLayoutConstraint!

    /// 收（靠左）布局：头像在左，气泡在头像右侧
    private var incomingConstraints: [NSLayoutConstraint] = []
    /// 发（靠右）布局：头像在右，气泡在头像左侧
    private var outgoingConstraints: [NSLayoutConstraint] = []

    // MARK: - 时间格式化器
    //
    // DateFormatter 初始化开销较大（约 0.5ms），cell provider 会被高频调用，
    // 用 static 单例复用同一实例，每次只更新 dateFormat 字符串即可。
    // 由于整个类标记 @MainActor，此静态属性只在主线程访问，无线程安全顾虑。

    private static let timeFmt: DateFormatter = DateFormatter()

    // MARK: - 初始化

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupCommonUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 布局搭建

    private func setupCommonUI() {
        // 时间分隔标签
        timeLabel.font = .systemFont(ofSize: 12)
        timeLabel.textColor = .secondaryLabel
        timeLabel.textAlignment = .center
        timeLabel.setContentHuggingPriority(.required, for: .vertical)
        timeLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(timeLabel)

        // 头像
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(avatarView)

        // 气泡容器
        bubble.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
        bubble.layer.cornerRadius = 14
        bubble.layer.masksToBounds = true
        bubble.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bubble)

        // 状态指示器（发送中）
        statusIndicator.hidesWhenStopped = true
        statusIndicator.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(statusIndicator)

        // 发送失败按钮：点击触发重试逻辑
        failedButton.setImage(UIImage(systemName: "exclamationmark.circle.fill"), for: .normal)
        failedButton.tintColor = .systemRed
        failedButton.isHidden = true
        failedButton.translatesAutoresizingMaskIntoConstraints = false
        failedButton.addTarget(self, action: #selector(failedButtonTapped), for: .touchUpInside)
        contentView.addSubview(failedButton)

        // 添加上下文菜单交互
        let contextMenuInteraction = UIContextMenuInteraction(delegate: self)
        bubble.addInteraction(contextMenuInteraction)

        // 注意：timeHeightConstraint 初始值为 0，与 isHidden 配合使用。
        // 仅设置 isHidden = true 无法折叠高度——AutoLayout 仍会为隐藏视图保留空间；
        // 必须同时将高度约束改为 0，才能让 cell 高度随之收缩，不留空白。
        timeHeightConstraint = timeLabel.heightAnchor.constraint(equalToConstant: 0)
        timeHeightConstraint.priority = .required

        // 常驻约束（收发共用，整个 cell 生命周期内不变）
        NSLayoutConstraint.activate([
            // timeLabel：顶部全宽，高度由 timeHeightConstraint 动态控制
            timeLabel.topAnchor.constraint(equalTo: contentView.topAnchor),
            timeLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            timeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            timeHeightConstraint,

            // avatarView：固定尺寸，水平/垂直位置由下方方向约束决定
            avatarView.widthAnchor.constraint(equalToConstant: 36),
            avatarView.heightAnchor.constraint(equalToConstant: 36),

            // 注意：bubble.top 始终锚定在 timeLabel.bottom + 4，
            // 当 timeLabel 高度为 0（隐藏）时，等同于 cell 顶部 + 4pt 的小边距；
            // 当 timeLabel 可见（高度 28）时，bubble 自然下移，无需额外代码。
            bubble.topAnchor.constraint(equalTo: timeLabel.bottomAnchor, constant: 4),
            bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            bubble.widthAnchor.constraint(greaterThanOrEqualToConstant: 50),
            // 最大宽度 65%，为头像（36pt）+ 两侧边距（各 8pt）共 52pt 留出空间
            bubble.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.65),

            // 状态指示器：位于气泡左侧（发送方消息）
            statusIndicator.centerYAnchor.constraint(equalTo: bubble.centerYAnchor),
            statusIndicator.widthAnchor.constraint(equalToConstant: 20),
            statusIndicator.heightAnchor.constraint(equalToConstant: 20),

            // 发送失败按钮：位于气泡左侧（发送方消息）
            failedButton.centerYAnchor.constraint(equalTo: bubble.centerYAnchor),
            failedButton.widthAnchor.constraint(equalToConstant: 24),
            failedButton.heightAnchor.constraint(equalToConstant: 24),
        ])

        // 注意：两套方向约束在 init 时只构建、不激活。
        // 首次 configureCommon 调用时才激活正确的一套。
        // 这样避免了在 init 时因方向未知而随意激活一套、再在 configure 时产生约束冲突。

        // 收（靠左）方向约束：头像在左，气泡在头像右侧
        incomingConstraints = [
            avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            avatarView.bottomAnchor.constraint(equalTo: bubble.bottomAnchor),
            bubble.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 8),
        ]

        // 发（靠右）方向约束：头像在右，气泡在头像左侧，状态指示器在气泡左侧
        outgoingConstraints = [
            avatarView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            avatarView.bottomAnchor.constraint(equalTo: bubble.bottomAnchor),
            bubble.trailingAnchor.constraint(equalTo: avatarView.leadingAnchor, constant: -8),
            statusIndicator.trailingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: -8),
            failedButton.trailingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: -8),
        ]
    }

    // MARK: - 共用配置入口

    /// 子类在自己的 `configure` 方法开头调用，完成时间分隔行、头像和方向布局的更新。
    ///
    /// - Parameters:
    ///   - message: 当前消息（提供 sender、sentAt、isOutgoing）
    ///   - showTimeHeader: 由 ViewController 根据与上一条消息的时间差计算后传入
    func configureCommon(message: ChatMessage, showTimeHeader: Bool) {
        // 保存消息对象供上下文菜单使用
        currentMessage = message

        // 时间分隔行：高度约束驱动折叠/展开，无需手动调整其他视图
        if showTimeHeader {
            timeLabel.text = Self.formatTime(message.sentAt)
            timeLabel.isHidden = false
            timeHeightConstraint.constant = 28
        } else {
            timeLabel.isHidden = true
            timeHeightConstraint.constant = 0
        }

        // 头像
        avatarView.configure(with: message.sender)

        // 注意：必须先 deactivate 两套约束，再 activate 正确的一套。
        // Cell 复用时方向可能改变（如收→发），若只 activate 新方向而不 deactivate 旧方向，
        // AutoLayout 会同时持有两套互斥约束，引发 [LayoutConstraints] unsatisfiable 警告
        // 并产生随机布局错误。统一 deactivate 全部再 activate 目标套，始终安全。
        NSLayoutConstraint.deactivate(incomingConstraints + outgoingConstraints)
        NSLayoutConstraint.activate(message.isOutgoing ? outgoingConstraints : incomingConstraints)

        // 发送方气泡用略深蓝色，接收方用浅灰色，提升视觉区分度
        bubble.backgroundColor = message.isOutgoing
            ? UIColor.systemBlue.withAlphaComponent(0.15)
            : UIColor.systemGray5

        // MARK: 状态指示器更新逻辑
        //
        // 仅自己发送的消息（isOutgoing = true）显示状态指示器。
        // 对方消息不显示任何状态（statusIndicator 停止，failedButton 隐藏）。
        //
        // 状态展示规则：
        // - .sending：显示旋转的加载动画
        // - .delivered / .read：隐藏所有指示器（暂未实现单勾/双勾 UI）
        // - .failed：显示红色感叹号按钮，可点击重试
        if message.isOutgoing {
            switch message.sendStatus {
            case .sending:
                statusIndicator.startAnimating()
                failedButton.isHidden = true
            case .delivered, .read:
                // 已送达、已读状态暂不处理 UI
                statusIndicator.stopAnimating()
                failedButton.isHidden = true
            case .failed:
                statusIndicator.stopAnimating()
                failedButton.isHidden = false
            }
        } else {
            statusIndicator.stopAnimating()
            failedButton.isHidden = true
        }
    }

    // MARK: - 时间格式化

    /// 根据距今时间返回合适的时间字符串。
    /// - 今天：`HH:mm`
    /// - 昨天：`昨天 HH:mm`
    /// - 更早：`M月d日 HH:mm`
    private static func formatTime(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            timeFmt.dateFormat = "HH:mm"
        } else if cal.isDateInYesterday(date) {
            timeFmt.dateFormat = "昨天 HH:mm"
        } else {
            timeFmt.dateFormat = "M月d日 HH:mm"
        }
        return timeFmt.string(from: date)
    }

    // MARK: - 失败按钮点击

    @objc private func failedButtonTapped() {
        onRetryTap?()
    }
}

// MARK: - UIContextMenuInteractionDelegate

extension ChatBubbleCell: UIContextMenuInteractionDelegate {

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                               configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let message = currentMessage,
              let menu = contextMenuProvider?(message) else { return nil }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            return menu
        }
    }
}
