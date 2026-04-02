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

        NSLayoutConstraint.activate([
            // 图片视图填充整个气泡
            imageView.topAnchor.constraint(equalTo: bubble.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bubble.bottomAnchor),
            // 固定宽高比，最大宽度由气泡约束控制
            imageView.widthAnchor.constraint(equalToConstant: 200),
            imageView.heightAnchor.constraint(equalToConstant: 200),

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
            }
        }
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
