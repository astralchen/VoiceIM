import UIKit

/// 文本消息气泡 Cell，继承 ChatBubbleCell 获得时间分隔行、头像和收/发方向布局。
/// 本类只负责文字内容的显示。
/// 支持长按显示上下文菜单（复制、撤回、删除）。
/// 支持检测并高亮显示 URL、电话号，点击后通过回调传递给外部处理。
final class TextMessageCell: ChatBubbleCell {

    nonisolated static let reuseID = "TextMessageCell"

    private let label = UILabel()
    private var detectedLinks: [(range: NSRange, url: URL, type: NSTextCheckingResult.CheckingType)] = []

    /// 点击链接/电话的回调
    var onLinkTapped: ((URL, NSTextCheckingResult.CheckingType) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupTextUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - UI 搭建

    private func setupTextUI() {
        label.font = .systemFont(ofSize: 16)
        label.textColor = .label
        label.numberOfLines = 0
        label.isUserInteractionEnabled = true
        label.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -10),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
        ])

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        label.addGestureRecognizer(tapGesture)
    }

    // MARK: - 配置

    func configure(with message: ChatMessage) {
        guard case .text(let content) = message.kind else { return }

        // 检测并高亮 URL、电话号
        let attributedText = detectAndHighlightLinks(in: content)
        label.attributedText = attributedText
    }

    // MARK: - 链接检测与高亮

    private func detectAndHighlightLinks(in text: String) -> NSAttributedString {
        let attributedString = NSMutableAttributedString(string: text)

        // 设置默认样式
        attributedString.addAttributes([
            .font: UIFont.systemFont(ofSize: 16),
            .foregroundColor: UIColor.label
        ], range: NSRange(location: 0, length: text.utf16.count))

        // 使用 NSDataDetector 检测链接和电话号
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue | NSTextCheckingResult.CheckingType.phoneNumber.rawValue) else {
            return attributedString
        }

        detectedLinks.removeAll()
        let matches = detector.matches(in: text, range: NSRange(location: 0, length: text.utf16.count))

        for match in matches {
            // 电话号码类型可能没有 url，需要手动构造
            let url: URL?
            if match.resultType == .phoneNumber {
                if let phoneNumber = match.phoneNumber {
                    url = URL(string: "tel:\(phoneNumber)")
                } else {
                    url = nil
                }
            } else {
                url = match.url
            }

            guard let finalURL = url else { continue }

            // 高亮样式
            attributedString.addAttributes([
                .foregroundColor: UIColor.systemBlue,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: match.range)

            detectedLinks.append((range: match.range, url: finalURL, type: match.resultType))
        }

        // 检测银行卡号（16-19位数字，可能包含空格分隔）
        detectBankCards(in: text, attributedString: attributedString)

        return attributedString
    }

    /// 检测银行卡号并高亮
    private func detectBankCards(in text: String, attributedString: NSMutableAttributedString) {
        // 银行卡号正则：16-19位数字，可能每4位用空格分隔
        let pattern = "\\b(?:\\d{4}[\\s-]?){3,4}\\d{1,3}\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }

        let matches = regex.matches(in: text, range: NSRange(location: 0, length: text.utf16.count))

        for match in matches {
            let matchedText = (text as NSString).substring(with: match.range)
            let digits = matchedText.replacingOccurrences(of: "[\\s-]", with: "", options: .regularExpression)

            // 验证是否为有效银行卡号长度（16-19位）
            guard digits.count >= 16 && digits.count <= 19,
                  digits.allSatisfy({ $0.isNumber }) else { continue }

            // 使用自定义 scheme 标识银行卡号
            guard let url = URL(string: "bankcard:\(digits)") else { continue }

            // 高亮样式
            attributedString.addAttributes([
                .foregroundColor: UIColor.systemBlue,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: match.range)

            // 使用自定义类型标记（复用 .address 类型）
            detectedLinks.append((range: match.range, url: url, type: .address))
        }
    }

    // MARK: - 点击处理

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: label)

        guard let attributedText = label.attributedText else { return }

        // 创建 NSTextContainer 和 NSLayoutManager 来计算点击位置
        let textStorage = NSTextStorage(attributedString: attributedText)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: label.bounds.size)

        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = label.numberOfLines
        textContainer.lineBreakMode = label.lineBreakMode

        // 获取点击的字符索引
        let characterIndex = layoutManager.characterIndex(for: location, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)

        // 检查是否点击了链接
        for link in detectedLinks {
            if NSLocationInRange(characterIndex, link.range) {
                onLinkTapped?(link.url, link.type)
                return
            }
        }
    }
}

// MARK: - MessageCellConfigurable

extension TextMessageCell: MessageCellConfigurable {

    func configure(with message: ChatMessage, deps: MessageCellDependencies) {
        // 先调基类方法更新时间分隔行、头像和收/发方向
        configureCommon(message: message, showTimeHeader: deps.showTimeHeader)
        // 设置链接点击回调
        onLinkTapped = deps.onLinkTapped
        // 再更新文字内容
        configure(with: message)
    }
}
