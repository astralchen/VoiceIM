import UIKit
import AVKit
import AVFoundation

/// 视频预览页面，支持播放控制和关闭
@MainActor
final class VideoPreviewViewController: UIViewController {

    private let videoURL: URL
    private var player: AVPlayer?
    private var playerViewController: AVPlayerViewController?
    private let closeButton = UIButton(type: .system)

    // MARK: - 初始化

    init(videoURL: URL) {
        self.videoURL = videoURL
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupPlayer()
        setupUI()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 页面显示后自动播放视频
        player?.play()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        player?.pause()
    }

    // MARK: - 播放器设置

    private func setupPlayer() {
        player = AVPlayer(url: videoURL)

        let playerVC = AVPlayerViewController()
        playerVC.player = player
        playerVC.showsPlaybackControls = true
        playerVC.view.translatesAutoresizingMaskIntoConstraints = false

        addChild(playerVC)
        view.addSubview(playerVC.view)
        playerVC.didMove(toParent: self)

        playerViewController = playerVC

        NSLayoutConstraint.activate([
            playerVC.view.topAnchor.constraint(equalTo: view.topAnchor),
            playerVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - UI 搭建

    private func setupUI() {
        // 关闭按钮
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        closeButton.layer.cornerRadius = 20
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)

        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 40),
            closeButton.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    // MARK: - 事件处理

    @objc private func closeTapped() {
        dismiss(animated: true)
    }
}
