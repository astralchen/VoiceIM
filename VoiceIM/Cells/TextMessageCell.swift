import UIKit

/// 文本消息气泡 Cell，继承 ChatBubbleCell 获得时间分隔行、头像和收/发方向布局。
/// 本类只负责文字内容的显示。
final class TextMessageCell: ChatBubbleCell {

    nonisolated static let reuseID = "TextMessageCell"

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupTextUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - UI 搭建

    private func setupTextUI() {
        label.font          = .systemFont(ofSize: 16)
        label.textColor     = .label
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -10),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
        ])
    }

    // MARK: - 配置

    func configure(with message: ChatMessage) {
        guard case .text(let content) = message.kind else { return }
        label.text = content
    }
}

// MARK: - MessageCellConfigurable

extension TextMessageCell: MessageCellConfigurable {

    func configure(with message: ChatMessage, deps: MessageCellDependencies) {
        // 先调基类方法更新时间分隔行、头像和收/发方向
        configureCommon(message: message, showTimeHeader: deps.showTimeHeader)
        // 再更新文字内容
        configure(with: message)
    }
}
