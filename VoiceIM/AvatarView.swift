import UIKit

/// 圆形头像占位视图：固定背景色 + 发送者姓名首字母。
///
/// 颜色由 `sender.id` 的 UTF-8 字节求和决定，跨 session 保持一致
/// （不依赖 Swift 随机化的 `hashValue`）。
final class AvatarView: UIView {

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        // 直径 36pt，圆角 = 半径
        layer.cornerRadius = 18
        layer.masksToBounds = true

        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 配置

    func configure(with sender: Sender) {
        label.text = String(sender.displayName.prefix(1))
        backgroundColor = Self.color(for: sender.id)
    }

    // MARK: - 颜色映射

    private static func color(for id: String) -> UIColor {
        let palette: [UIColor] = [
            .systemBlue, .systemGreen, .systemOrange,
            .systemPurple, .systemPink, .systemTeal,
        ]
        // 注意：不能用 String.hashValue，Swift 对其做了随机化处理（SE-0206），
        // 同一字符串在不同进程/次启动中 hashValue 不同，导致头像颜色每次启动都会变化。
        // 改用 UTF-8 字节求和（溢出安全的 &+），结果确定且跨 session 不变。
        let idx = id.utf8.reduce(0) { ($0 &+ Int($1)) } % palette.count
        return palette[idx].withAlphaComponent(0.85)
    }
}
