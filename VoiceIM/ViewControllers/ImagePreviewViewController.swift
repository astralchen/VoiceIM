import UIKit

/// 图片预览页面，支持缩放和关闭
@MainActor
final class ImagePreviewViewController: UIViewController {

    private let imageURL: URL
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let closeButton = UIButton(type: .system)

    // MARK: - 初始化

    init(imageURL: URL) {
        self.imageURL = imageURL
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupUI()
        loadImage()
    }

    // MARK: - UI 搭建

    private func setupUI() {
        // ScrollView 用于支持缩放
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 3.0
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        // ImageView
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)

        // 关闭按钮
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        closeButton.layer.cornerRadius = 20
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            imageView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.heightAnchor),

            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 40),
            closeButton.heightAnchor.constraint(equalToConstant: 40),
        ])

        // 双击缩放
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }

    // MARK: - 加载图片

    private func loadImage() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self,
                  let data = try? Data(contentsOf: self.imageURL),
                  let image = UIImage(data: data) else { return }

            DispatchQueue.main.async {
                self.imageView.image = image
            }
        }
    }

    // MARK: - 事件处理

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > 1.0 {
            scrollView.setZoomScale(1.0, animated: true)
        } else {
            let location = gesture.location(in: imageView)
            let rect = CGRect(x: location.x - 50, y: location.y - 50, width: 100, height: 100)
            scrollView.zoom(to: rect, animated: true)
        }
    }
}

// MARK: - UIScrollViewDelegate

extension ImagePreviewViewController: UIScrollViewDelegate {

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return imageView
    }
}
