import UIKit

@MainActor
protocol ImageMessageCellDelegate: AnyObject {
    func cellDidTapImage(_ cell: ImageMessageCell, message: ChatMessage)
}

/// 图片消息 Cell，继承 ChatBubbleCell 获得时间分隔行、头像和收/发方向布局。
/// 本类只负责图片显示。
@MainActor
final class ImageMessageCell: ChatBubbleCell {

    nonisolated static let reuseID = "ImageMessageCell"

    weak var delegate: ImageMessageCellDelegate?
    private(set) var message: ChatMessage?

    // MARK: - 子视图

    private let imageView = UIImageView()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)

    // 动态尺寸约束
    private var imageWidthConstraint: NSLayoutConstraint!
    private var imageHeightConstraint: NSLayoutConstraint!

    // MARK: - 初始化

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupImageUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - UI 搭建

    private func setupImageUI() {
        // 图片视图
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .systemGray6
        imageView.isUserInteractionEnabled = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(imageView)

        // 添加点击手势
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(imageTapped))
        imageView.addGestureRecognizer(tapGesture)

        // 加载指示器
        loadingIndicator.hidesWhenStopped = true
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(loadingIndicator)

        // 创建动态尺寸约束
        imageWidthConstraint = imageView.widthAnchor.constraint(equalToConstant: 200)
        imageHeightConstraint = imageView.heightAnchor.constraint(equalToConstant: 200)

        NSLayoutConstraint.activate([
            // 图片视图填充整个气泡
            imageView.topAnchor.constraint(equalTo: bubble.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bubble.bottomAnchor),
            // 动态宽高约束
            imageWidthConstraint,
            imageHeightConstraint,

            // 加载指示器居中
            loadingIndicator.centerXAnchor.constraint(equalTo: bubble.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: bubble.centerYAnchor),
        ])
    }

    // MARK: - 配置

    func configure(with message: ChatMessage, imageURL: URL?) {
        self.message = message

        if let url = imageURL {
            loadImage(from: url)
        } else {
            imageView.image = nil
            loadingIndicator.stopAnimating()
        }
    }

    private func loadImage(from url: URL) {
        loadingIndicator.startAnimating()

        // 简单的图片加载（生产环境应使用 SDWebImage 等库）
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let data = try? Data(contentsOf: url),
                  let image = UIImage(data: data) else {
                DispatchQueue.main.async {
                    self?.loadingIndicator.stopAnimating()
                }
                return
            }

            DispatchQueue.main.async {
                self?.imageView.image = image
                self?.loadingIndicator.stopAnimating()
                // 根据图片尺寸更新约束
                self?.updateImageSize(for: image)
            }
        }
    }

    /// 根据图片实际尺寸计算显示尺寸
    ///
    /// 规则：
    /// - 最大宽度：250pt
    /// - 最大高度：350pt
    /// - 最小宽度：80pt
    /// - 最小高度：80pt
    /// - 保持原图宽高比
    /// - 特殊处理：超长图（高宽比 > 3）、超宽图（宽高比 > 3）
    private func updateImageSize(for image: UIImage) {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }

        let maxWidth: CGFloat = 250
        let maxHeight: CGFloat = 350
        let minWidth: CGFloat = 80
        let minHeight: CGFloat = 80

        let aspectRatio = imageSize.width / imageSize.height

        var displayWidth: CGFloat
        var displayHeight: CGFloat

        // 超宽图（宽高比 > 3）：限制高度，宽度按比例
        if aspectRatio > 3 {
            displayHeight = max(minHeight, min(100, imageSize.height))
            displayWidth = displayHeight * aspectRatio
            displayWidth = min(displayWidth, maxWidth)
            displayHeight = displayWidth / aspectRatio
        }
        // 超长图（高宽比 > 3）：限制宽度，高度按比例
        else if aspectRatio < 1.0 / 3.0 {
            displayWidth = max(minWidth, min(100, imageSize.width))
            displayHeight = displayWidth / aspectRatio
            displayHeight = min(displayHeight, maxHeight)
            displayWidth = displayHeight * aspectRatio
        }
        // 普通图片：按宽高比缩放到最大尺寸内
        else {
            if aspectRatio > 1 {
                // 横图：宽度优先
                displayWidth = min(imageSize.width, maxWidth)
                displayHeight = displayWidth / aspectRatio
                if displayHeight > maxHeight {
                    displayHeight = maxHeight
                    displayWidth = displayHeight * aspectRatio
                }
            } else {
                // 竖图或方图：高度优先
                displayHeight = min(imageSize.height, maxHeight)
                displayWidth = displayHeight * aspectRatio
                if displayWidth > maxWidth {
                    displayWidth = maxWidth
                    displayHeight = displayWidth / aspectRatio
                }
            }

            // 确保不小于最小尺寸
            if displayWidth < minWidth {
                displayWidth = minWidth
                displayHeight = displayWidth / aspectRatio
            }
            if displayHeight < minHeight {
                displayHeight = minHeight
                displayWidth = displayHeight * aspectRatio
            }
        }

        // 更新约束
        imageWidthConstraint.constant = displayWidth
        imageHeightConstraint.constant = displayHeight
    }

    // MARK: - 事件处理

    @objc private func imageTapped() {
        guard let msg = message else { return }
        delegate?.cellDidTapImage(self, message: msg)
    }
}

// MARK: - MessageCellConfigurable

extension ImageMessageCell: MessageCellConfigurable {

    func configure(with message: ChatMessage, deps: MessageCellDependencies) {
        // 先调基类方法更新时间分隔行、头像和收/发方向
        configureCommon(message: message, showTimeHeader: deps.showTimeHeader)

        // 设置 delegate
        delegate = deps.imageDelegate

        // 获取图片 URL
        let imageURL: URL?
        if case .image(let localURL, let remoteURL) = message.kind {
            imageURL = localURL ?? remoteURL
        } else {
            imageURL = nil
        }

        // 更新图片显示
        configure(with: message, imageURL: imageURL)
    }
}
