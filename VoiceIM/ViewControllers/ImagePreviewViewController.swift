import UIKit

/// 图片预览页面，支持缩放和苹果相册风格的转场动画
///
/// 实现 `ZoomTransitionTarget` 后，`ZoomTransitionController` 会自动为本页面
/// 安装下滑关闭手势，无需在此添加任何转场相关代码。
@MainActor
final class ImagePreviewViewController: UIViewController {

    private let imageURL: URL?
    private let image: UIImage?
    private let scrollView  = UIScrollView()
    private let imageView   = UIImageView()
    private let closeButton = UIButton(type: .system)

    // MARK: - 初始化

    init(image: UIImage, imageURL: URL) {
        self.image    = image
        self.imageURL = imageURL
        super.init(nibName: nil, bundle: nil)
    }

    init(imageURL: URL) {
        self.image    = nil
        self.imageURL = imageURL
        super.init(nibName: nil, bundle: nil)
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
        scrollView.delegate                             = self
        scrollView.minimumZoomScale                     = 1.0
        scrollView.maximumZoomScale                     = 3.0
        scrollView.showsHorizontalScrollIndicator       = false
        scrollView.showsVerticalScrollIndicator         = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)

        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor          = .white
        closeButton.backgroundColor    = UIColor.black.withAlphaComponent(0.5)
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

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }

    // MARK: - 加载图片

    private func loadImage() {
        if let image {
            imageView.image = image
            return
        }
        guard let imageURL else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self,
                  let data  = try? Data(contentsOf: imageURL),
                  let image = UIImage(data: data) else { return }
            DispatchQueue.main.async { self.imageView.image = image }
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
            let rect     = CGRect(x: location.x - 50, y: location.y - 50, width: 100, height: 100)
            scrollView.zoom(to: rect, animated: true)
        }
    }
}

// MARK: - ZoomTransitionTarget

extension ImagePreviewViewController: ZoomTransitionTarget {

    var zoomContentView: UIView { imageView }

    /// 图片在当前 view 中 aspect-fit 后的实际展示区域
    var zoomDisplayFrame: CGRect {
        guard let img = imageView.image, img.size.width > 0, img.size.height > 0 else {
            return view.bounds
        }
        let ia = img.size.width / img.size.height
        let va = view.bounds.width / view.bounds.height
        let w: CGFloat = ia > va ? view.bounds.width      : view.bounds.height * ia
        let h: CGFloat = ia > va ? view.bounds.width / ia : view.bounds.height
        return CGRect(
            x: (view.bounds.width  - w) / 2,
            y: (view.bounds.height - h) / 2,
            width: w, height: h
        )
    }

    /// 未缩放时才允许下滑关闭（缩放中的下拉应由 scrollView 处理）
    var zoomDismissGestureEnabled: Bool {
        scrollView.zoomScale <= 1.0
    }
}

// MARK: - UIScrollViewDelegate

extension ImagePreviewViewController: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
}
