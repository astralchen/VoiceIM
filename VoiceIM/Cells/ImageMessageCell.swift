import UIKit

@MainActor
protocol ImageMessageCellDelegate: AnyObject {
    func cellDidTapImage(_ cell: ImageMessageCell, message: ChatMessage)
    func cellDidLoadImage(_ cell: ImageMessageCell, heightDelta: CGFloat)
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

    // 【关键属性】当前加载的 URL，用于避免重复加载
    // 原因：Cell 复用时会多次调用 configure，需要判断是否是同一张图片
    // 效果：相同 URL 不会重复加载，提升性能
    private var currentImageURL: URL?

    // 【已废弃】使用统一的 ImageCacheManager 替代
    // 原因：ImageCacheManager 提供更完善的缓存策略（内存+磁盘+下采样）
    // private nonisolated(unsafe) static var imageCache = NSCache<NSURL, UIImage>()

    // MARK: - 初始化

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupImageUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Cell 复用

    override func prepareForReuse() {
        super.prepareForReuse()

        // 【关键清理】重置 Cell 状态，避免复用时显示错误内容
        // 原因：CollectionView 会复用 Cell，如果不清理，可能显示上一条消息的图片
        // 效果：确保每次配置 Cell 时都是干净的状态
        imageView.image = nil
        loadingIndicator.stopAnimating()
        currentImageURL = nil
    }

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

        // 【关键设置】降低优先级，避免与 Cell 自动计算的高度冲突
        // 原因：CollectionView 会自动计算 Cell 的高度（UIView-Encapsulated-Layout-Height）
        //      如果图片约束是 .required 优先级，会与自动高度约束冲突
        // 效果：避免约束冲突警告，让系统可以灵活调整布局
        // 优先级：.defaultHigh (750) < .required (1000)
        imageWidthConstraint.priority = .defaultHigh
        imageHeightConstraint.priority = .defaultHigh

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

        // 【关键优化】避免重复加载：如果 URL 相同且图片已加载，跳过
        // 原因：Cell 复用时会多次调用 configure，但图片已在内存中，无需重新加载
        // 效果：减少磁盘 I/O，避免闪烁，提升滚动性能
        if let url = imageURL, url == currentImageURL, imageView.image != nil {
            return
        }

        currentImageURL = imageURL

        if let url = imageURL {
            loadImage(from: url)
        } else {
            imageView.image = nil
            loadingIndicator.stopAnimating()
        }
    }

    private func loadImage(from url: URL) {
        loadingIndicator.startAnimating()

        // 【性能优化】使用统一的 ImageCacheManager
        // 优势：
        // 1. 两级缓存（内存 + 磁盘）
        // 2. 图片下采样（减少内存占用）
        // 3. 异步解码（避免阻塞主线程）
        // 4. 自动内存管理
        Task { [weak self] in
            guard let self else { return }

            // 计算目标尺寸（用于下采样优化）
            let targetSize = CGSize(width: 250, height: 350)

            // 异步加载图片
            let image = await ImageCacheManager.shared.loadImage(from: url, targetSize: targetSize)

            await MainActor.run {
                // 【关键检查】防止 Cell 复用错乱
                guard self.currentImageURL == url else { return }

                self.loadingIndicator.stopAnimating()

                guard let image = image else {
                    VoiceIM.logger.warning("Failed to load image: \(url)")
                    return
                }

                self.imageView.image = image

                // 根据图片尺寸更新约束，获取高度变化量
                let heightDelta = self.updateImageSize(for: image)

                // 【关键步骤】通知 CollectionView 重新计算布局
                var view = self.superview
                while view != nil && !(view is UICollectionView) {
                    view = view?.superview
                }
                if let collectionView = view as? UICollectionView {
                    collectionView.performBatchUpdates(nil)
                }

                // 【关键回调】通知 ViewController 图片已加载
                if heightDelta != 0 {
                    self.delegate?.cellDidLoadImage(self, heightDelta: heightDelta)
                }
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
    ///
    /// - Returns: 高度变化量（用于滚动补偿）
    private func updateImageSize(for image: UIImage) -> CGFloat {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return 0 }

        // 【关键】记录旧高度，用于计算变化量
        // 原因：ViewController 需要知道高度变化了多少，才能精确补偿滚动位置
        // 效果：用户阅读中间消息时，位置保持不变
        let oldHeight = imageHeightConstraint.constant

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

        // 【关键】返回高度变化量
        // 原因：ViewController 需要这个值来决定是否调整滚动位置
        // 效果：实现智能滚动补偿
        return displayHeight - oldHeight
    }

    // MARK: - 事件处理

    @objc private func imageTapped() {
        guard let msg = message else { return }
        delegate?.cellDidTapImage(self, message: msg)
    }
}

// MARK: - MessageCellConfigurable

extension ImageMessageCell: MessageCellConfigurable {

    func configure(with message: ChatMessage, deps: MessageCellDependencies, context: MessageCellContext) {
        // 先调基类方法更新时间分隔行、头像和收/发方向
        configureCommon(message: message, showTimeHeader: context.showTimeHeader)

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
