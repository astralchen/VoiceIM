import UIKit
import AVFoundation

@MainActor
protocol VideoMessageCellDelegate: AnyObject {
    func cellDidTapVideo(_ cell: VideoMessageCell, message: ChatMessage)
}

/// 视频消息 Cell，继承 ChatBubbleCell 获得时间分隔行、头像和收/发方向布局。
/// 本类只负责视频缩略图和播放按钮显示。
@MainActor
final class VideoMessageCell: ChatBubbleCell {

    nonisolated static let reuseID = "VideoMessageCell"

    weak var delegate: VideoMessageCellDelegate?
    private(set) var message: ChatMessage?

    /// 当前加载的视频缩略图（供转场动画使用）
    var currentThumbnailImage: UIImage? { thumbnailView.image }

    // MARK: - 子视图

    private let thumbnailView = UIImageView()
    private let playButton = UIButton(type: .system)
    private let durationLabel = UILabel()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)

    /// 当前加载的视频 URL（防止 Cell 复用时加载错误）
    private var currentVideoURL: URL?

    // MARK: - 初始化

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupVideoUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Cell 复用

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailView.image = nil
        loadingIndicator.stopAnimating()
        playButton.isHidden = true
        currentVideoURL = nil
    }

    // MARK: - UI 搭建

    private func setupVideoUI() {
        // 缩略图视图
        thumbnailView.contentMode = .scaleAspectFill
        thumbnailView.clipsToBounds = true
        thumbnailView.backgroundColor = .systemGray5
        thumbnailView.isUserInteractionEnabled = true
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(thumbnailView)

        // 添加点击手势
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(videoTapped))
        thumbnailView.addGestureRecognizer(tapGesture)

        // 播放按钮（使用大号 SF Symbol，天然带圆形填充背景，无需额外背景色）
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        playButton.setImage(UIImage(systemName: "play.circle.fill", withConfiguration: symbolConfig), for: .normal)
        playButton.tintColor = .white
        playButton.isUserInteractionEnabled = false
        playButton.isHidden = true  // 缩略图加载完成前隐藏
        playButton.translatesAutoresizingMaskIntoConstraints = false
        // 投影让播放按钮在亮色缩略图上也清晰可见
        playButton.layer.shadowColor = UIColor.black.cgColor
        playButton.layer.shadowOpacity = 0.4
        playButton.layer.shadowRadius = 4
        playButton.layer.shadowOffset = CGSize(width: 0, height: 2)
        bubble.addSubview(playButton)

        // 时长标签右下角
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        durationLabel.textColor = .white
        durationLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        durationLabel.layer.cornerRadius = 4
        durationLabel.layer.masksToBounds = true
        durationLabel.textAlignment = .center
        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(durationLabel)

        // 加载指示器（large + white，在灰色背景上清晰可见，层级高于缩略图）
        loadingIndicator.style = .large
        loadingIndicator.color = .white
        loadingIndicator.hidesWhenStopped = true
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(loadingIndicator)

        // 降低宽高约束优先级，避免与 Cell 自动高度冲突
        let widthConstraint = thumbnailView.widthAnchor.constraint(equalToConstant: 200)
        widthConstraint.priority = .defaultHigh

        let heightConstraint = thumbnailView.heightAnchor.constraint(equalToConstant: 200)
        heightConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            // 缩略图填充整个气泡
            thumbnailView.topAnchor.constraint(equalTo: bubble.topAnchor),
            thumbnailView.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
            thumbnailView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
            thumbnailView.bottomAnchor.constraint(equalTo: bubble.bottomAnchor),
            widthConstraint,
            heightConstraint,

            // 播放按钮居中（尺寸由 SF Symbol pointSize 决定，不再硬设宽高）
            playButton.centerXAnchor.constraint(equalTo: bubble.centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: bubble.centerYAnchor),

            // 时长标签右下角
            durationLabel.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -8),
            durationLabel.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -8),
            durationLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
            durationLabel.heightAnchor.constraint(equalToConstant: 20),

            // 加载指示器居中（加载时独占中央，不与播放按钮重叠）
            loadingIndicator.centerXAnchor.constraint(equalTo: bubble.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: bubble.centerYAnchor),
        ])
    }

    // MARK: - 配置

    func configure(with message: ChatMessage, videoURL: URL?, duration: TimeInterval) {
        self.message = message

        // 显示时长
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        durationLabel.text = String(format: " %d:%02d ", mins, secs)

        // 【关键优化】避免重复加载：如果 URL 相同且缩略图已加载，跳过
        if let url = videoURL, url == currentVideoURL, thumbnailView.image != nil {
            return
        }

        currentVideoURL = videoURL

        if let url = videoURL {
            loadThumbnail(from: url)
        } else {
            thumbnailView.image = nil
            playButton.isHidden = true
            loadingIndicator.stopAnimating()
        }
    }

    private func loadThumbnail(from url: URL) {
        // 同步检查缓存（内存 + 磁盘），命中则立即显示，无任何闪烁
        if let cached = VideoCacheManager.shared.cachedThumbnail(for: url) {
            applyThumbnail(cached)
            return
        }

        // 缓存未命中：隐藏播放按钮，显示加载指示器
        playButton.isHidden = true
        loadingIndicator.startAnimating()

        Task { [weak self] in
            guard let self else { return }
            let thumbnail = await VideoCacheManager.shared.loadThumbnail(from: url)
            await MainActor.run {
                guard self.currentVideoURL == url else { return }
                self.loadingIndicator.stopAnimating()
                if let thumbnail {
                    self.applyThumbnail(thumbnail)
                } else {
                    VoiceIM.logger.warning("Failed to load video thumbnail: \(url)")
                }
            }
        }
    }

    /// 应用缩略图并显示播放按钮
    private func applyThumbnail(_ image: UIImage) {
        thumbnailView.image = image
        playButton.isHidden = false
    }

    // MARK: - 事件处理

    @objc private func videoTapped() {
        guard let msg = message else { return }
        delegate?.cellDidTapVideo(self, message: msg)
    }
}

// MARK: - MessageCellConfigurable

extension VideoMessageCell: MessageCellConfigurable {

    func configure(with message: ChatMessage, deps: MessageCellDependencies, context: MessageCellContext) {
        // 先调基类方法更新时间分隔行、头像和收/发方向
        configureCommon(message: message, showTimeHeader: context.showTimeHeader)

        // 设置 delegate
        delegate = deps.videoDelegate

        // 获取视频 URL（本地文件存在则优先，否则回退到远程 URL）
        let videoURL: URL?
        let duration: TimeInterval
        if case .video(let localURL, let remoteURL, let dur) = message.kind {
            videoURL = VideoCacheManager.shared.resolveVideoURL(local: localURL, remote: remoteURL)
            duration = dur
        } else {
            videoURL = nil
            duration = 0
        }

        // 更新视频显示
        configure(with: message, videoURL: videoURL, duration: duration)
    }
}
