import UIKit

/// 录音过程中显示在屏幕中央的浮层
final class RecordingOverlayView: UIView {

    enum State {
        case recording    // 正常录音
        case cancelReady  // 上滑预备取消
    }

    // MARK: - 子视图

    private let iconView = UIImageView()
    private let timeLabel = UILabel()
    private let hintLabel = UILabel()

    // MARK: - 初始化

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 搭建

    private func setupUI() {
        backgroundColor = UIColor.black.withAlphaComponent(0.68)
        layer.cornerRadius = 18
        layer.masksToBounds = true

        iconView.image = UIImage(systemName: "mic.fill")
        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        timeLabel.text = "0\""
        timeLabel.textColor = .white
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 38, weight: .semibold)
        timeLabel.textAlignment = .center
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(timeLabel)

        hintLabel.text = "上滑取消"
        hintLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        hintLabel.font = .systemFont(ofSize: 13)
        hintLabel.textAlignment = .center
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hintLabel)

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 28),
            iconView.widthAnchor.constraint(equalToConstant: 46),
            iconView.heightAnchor.constraint(equalToConstant: 46),

            timeLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            timeLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 10),
            timeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            hintLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            hintLabel.topAnchor.constraint(equalTo: timeLabel.bottomAnchor, constant: 8),
            hintLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -22),
        ])
    }

    // MARK: - 公共接口

    func setState(_ state: State) {
        switch state {
        case .recording:
            iconView.image = UIImage(systemName: "mic.fill")
            iconView.tintColor = .white
            backgroundColor = UIColor.black.withAlphaComponent(0.68)
            hintLabel.text = "上滑取消"
        case .cancelReady:
            iconView.image = UIImage(systemName: "xmark.circle.fill")
            iconView.tintColor = .systemRed
            backgroundColor = UIColor(red: 0.35, green: 0, blue: 0, alpha: 0.82)
            hintLabel.text = "松手取消"
        }
    }

    func updateSeconds(_ seconds: Int) {
        timeLabel.text = String(format: "%d\"", seconds)
    }
}
