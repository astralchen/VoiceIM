import UIKit

/// 撤回消息 Cell
final class RecalledMessageCell: UICollectionViewCell, MessageCellConfigurable {

    nonisolated static let reuseID = "RecalledMessageCell"

    // MARK: - UI

    private let recallLabel = UILabel()

    // MARK: - 回调

    var onTap: (() -> Void)?

    // MARK: - 初始化

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        // 撤回提示标签
        recallLabel.font = .systemFont(ofSize: 13)
        recallLabel.textColor = .tertiaryLabel
        recallLabel.textAlignment = .center
        recallLabel.numberOfLines = 0
        recallLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(recallLabel)

        // 添加点击手势
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        recallLabel.isUserInteractionEnabled = true
        recallLabel.addGestureRecognizer(tapGesture)

        NSLayoutConstraint.activate([
            recallLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            recallLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            recallLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            recallLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }

    @objc private func handleTap() {
        onTap?()
    }

    // MARK: - MessageCellConfigurable

    func configure(with message: ChatMessage, deps: MessageCellDependencies) {
        // 撤回消息不显示时间分隔行

        // 撤回提示文本
        guard case .recalled(let originalText) = message.kind else { return }

        if message.isOutgoing {
            if originalText != nil {
                recallLabel.text = "你撤回了一条消息（点击重新编辑）"
                recallLabel.textColor = .systemBlue
            } else {
                recallLabel.text = "你撤回了一条消息"
                recallLabel.textColor = .tertiaryLabel
            }
        } else {
            recallLabel.text = "对方撤回了一条消息"
            recallLabel.textColor = .tertiaryLabel
        }
    }
}
