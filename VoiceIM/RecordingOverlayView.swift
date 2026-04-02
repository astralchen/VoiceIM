import UIKit

/// 录音操作全屏浮层
///
/// 布局从下到上：底部 118pt 渐变舞台（麦克风）→ 提示文字 → 取消圆圈 → 录音气泡
/// isUserInteractionEnabled = false，触摸穿透到下层手势识别器。
final class RecordingOverlayView: UIView {

    enum State {
        case recording    // 正常录音，松手发送
        case cancelReady  // 上滑预备取消，松手取消
    }

    // MARK: - 子视图

    /// 录音气泡（波形图标 + 时间计数）
    private let bubbleView        = UIView()
    private let waveformImageView = UIImageView()
    private let timeLabel         = UILabel()

    /// 取消指示圆圈（X 图标），cancelReady 时变红
    private let cancelCircleView  = UIView()
    private let cancelIconView    = UIImageView()

    /// 提示文字（松手发送 / 松手取消）
    private let hintLabel         = UILabel()

    /// 底部 118pt 渐变舞台
    private let stageView          = UIView()
    private let bgGradientLayer    = CAGradientLayer()
    private let stageMaskLayer     = CAShapeLayer()   // 顶部弧形遮罩
    private let micImageView       = UIImageView()

    // MARK: - 初始化

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 布局

    override func layoutSubviews() {
        super.layoutSubviews()
        bgGradientLayer.frame = stageView.bounds
        cancelCircleView.layer.cornerRadius = cancelCircleView.bounds.height / 2
        updateStageMask()
    }

    /// 更新顶部弧形 mask：顶边向上凸出一条二次贝塞尔曲线
    private func updateStageMask() {
        let w = stageView.bounds.width
        let h = stageView.bounds.height
        guard w > 0, h > 0 else { return }

        let arcHeight: CGFloat = 28   // 弧顶比两侧边缘高出的距离
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0, y: arcHeight))
        // 控制点在顶部中央（y = 0），形成向上凸出的弧形
        path.addQuadCurve(to: CGPoint(x: w, y: arcHeight),
                          controlPoint: CGPoint(x: w / 2, y: 0))
        path.addLine(to: CGPoint(x: w, y: h))
        path.addLine(to: CGPoint(x: 0, y: h))
        path.close()

        stageMaskLayer.path = path.cgPath
        stageView.layer.mask = stageMaskLayer
    }

    // MARK: - 搭建

    private func setupUI() {
        backgroundColor = UIColor.black.withAlphaComponent(0.45)
        isUserInteractionEnabled = false

        setupStage()
        setupBubble()
        setupCancelCircle()
        setupHintLabel()
        setupConstraints()
    }

    private func setupStage() {
        stageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stageView)

        bgGradientLayer.startPoint = CGPoint(x: 0.5, y: 1.0)
        bgGradientLayer.endPoint   = CGPoint(x: 0.5, y: 0.0)
        applyStageColors(cancelReady: false)
        stageView.layer.insertSublayer(bgGradientLayer, at: 0)

        let micConfig = UIImage.SymbolConfiguration(pointSize: 36, weight: .regular)
        micImageView.image = UIImage(systemName: "mic.fill", withConfiguration: micConfig)
        micImageView.tintColor = .white
        micImageView.contentMode = .scaleAspectFit
        micImageView.translatesAutoresizingMaskIntoConstraints = false
        stageView.addSubview(micImageView)
    }

    private func setupBubble() {
        bubbleView.layer.cornerRadius  = 16
        bubbleView.layer.shadowColor   = UIColor.black.cgColor
        bubbleView.layer.shadowOpacity = 0.15
        bubbleView.layer.shadowRadius  = 8
        bubbleView.layer.shadowOffset  = CGSize(width: 0, height: 2)
        bubbleView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bubbleView)

        let waveConfig = UIImage.SymbolConfiguration(pointSize: 26, weight: .regular)
        waveformImageView.image = UIImage(systemName: "waveform", withConfiguration: waveConfig)
        waveformImageView.tintColor = UIColor(red: 0.45, green: 0.22, blue: 0.75, alpha: 1)
        waveformImageView.contentMode = .scaleAspectFit
        waveformImageView.translatesAutoresizingMaskIntoConstraints = false
        bubbleView.addSubview(waveformImageView)

        timeLabel.text  = "0\""
        timeLabel.font  = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        timeLabel.textColor = .label
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        bubbleView.addSubview(timeLabel)

        bubbleView.backgroundColor = .white
    }

    private func setupCancelCircle() {
        cancelCircleView.backgroundColor = UIColor(white: 0.15, alpha: 0.90)
        cancelCircleView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cancelCircleView)

        let xConfig = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        cancelIconView.image = UIImage(systemName: "xmark", withConfiguration: xConfig)
        cancelIconView.tintColor = .white
        cancelIconView.contentMode = .scaleAspectFit
        cancelIconView.translatesAutoresizingMaskIntoConstraints = false
        cancelCircleView.addSubview(cancelIconView)
    }

    private func setupHintLabel() {
        hintLabel.text      = "松手发送"
        hintLabel.textColor = .white
        hintLabel.font      = .systemFont(ofSize: 14)
        hintLabel.textAlignment = .center
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hintLabel)
    }

    private func setupConstraints() {
        NSLayoutConstraint.activate([
            // 底部渐变舞台：高度固定 118pt，贴底
            stageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stageView.heightAnchor.constraint(equalToConstant: 118),

            // 麦克风：舞台垂直居中
            micImageView.centerXAnchor.constraint(equalTo: stageView.centerXAnchor),
            micImageView.centerYAnchor.constraint(equalTo: stageView.centerYAnchor),

            // 提示文字：舞台顶部上方 14pt
            hintLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            hintLabel.bottomAnchor.constraint(equalTo: stageView.topAnchor, constant: -14),

            // 取消圆圈：提示文字上方 16pt
            cancelCircleView.centerXAnchor.constraint(equalTo: centerXAnchor),
            cancelCircleView.bottomAnchor.constraint(equalTo: hintLabel.topAnchor, constant: -16),
            cancelCircleView.widthAnchor.constraint(equalToConstant: 58),
            cancelCircleView.heightAnchor.constraint(equalToConstant: 58),

            cancelIconView.centerXAnchor.constraint(equalTo: cancelCircleView.centerXAnchor),
            cancelIconView.centerYAnchor.constraint(equalTo: cancelCircleView.centerYAnchor),

            // 录音气泡：取消圆圈上方 20pt
            bubbleView.centerXAnchor.constraint(equalTo: centerXAnchor),
            bubbleView.bottomAnchor.constraint(equalTo: cancelCircleView.topAnchor, constant: -20),

            // 气泡内：波形（左）+ 时间（右），上下内边距 16pt
            waveformImageView.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: 20),
            waveformImageView.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: 16),
            waveformImageView.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -16),

            timeLabel.leadingAnchor.constraint(equalTo: waveformImageView.trailingAnchor, constant: 12),
            timeLabel.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -20),
            timeLabel.centerYAnchor.constraint(equalTo: bubbleView.centerYAnchor),
        ])
    }

    // MARK: - 公共接口

    func setState(_ state: State) {
        let cancel = (state == .cancelReady)

        if cancel {
            bubbleView.backgroundColor    = .systemRed
            waveformImageView.tintColor   = .white
            timeLabel.textColor           = .white
            cancelCircleView.backgroundColor = .systemRed
        } else {
            bubbleView.backgroundColor    = .white
            waveformImageView.tintColor   = UIColor(red: 0.45, green: 0.22, blue: 0.75, alpha: 1)
            timeLabel.textColor           = .label
            cancelCircleView.backgroundColor = UIColor(white: 0.15, alpha: 0.90)
        }

        hintLabel.text      = cancel ? "松手取消" : "松手发送"
        hintLabel.textColor = cancel ? .systemRed : .white

        applyStageColors(cancelReady: cancel)
    }

    func updateSeconds(_ seconds: Int) {
        timeLabel.text = String(format: "%d\"", seconds)
    }

    // MARK: - 私有

    private func applyStageColors(cancelReady: Bool) {
        if cancelReady {
            bgGradientLayer.colors = [
                UIColor.systemRed.cgColor,
                UIColor(red: 0.25, green: 0.02, blue: 0.02, alpha: 1).cgColor,
            ]
        } else {
            bgGradientLayer.colors = [
                UIColor(red: 0.38, green: 0.18, blue: 0.65, alpha: 1).cgColor,
                UIColor(red: 0.07, green: 0.03, blue: 0.16, alpha: 1).cgColor,
            ]
        }
    }
}
