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
    private let bubbleStackView   = UIStackView()
    private let waveformView      = AudioLevelWaveformView()
    private let timeLabel         = UILabel()

    /// 取消指示圆圈（X 图标），cancelReady 时变红
    private let cancelCircleView  = UIView()
    private let cancelIconView    = UIImageView()

    /// 提示文字（松手发送 / 松手取消）
    private let hintLabel         = UILabel()

    /// 底部 118pt 渐变舞台
    private let stageView          = UIView()
    private let stageFillGradientLayer = CAGradientLayer()
    private let stageFillMaskLayer     = CAShapeLayer()
    private let stageStrokeGradientLayer = CAGradientLayer()
    private let stageStrokeMaskLayer     = CAShapeLayer()
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
        stageFillGradientLayer.frame = stageView.bounds
        stageStrokeGradientLayer.frame = stageView.bounds
        cancelCircleView.layer.cornerRadius = cancelCircleView.bounds.height / 2
        updateStagePath()
    }

    /// 使用设计稿 SVG 的 path-3（375x117.816455）按比例缩放到当前舞台尺寸。
    private func updateStagePath() {
        let bounds = stageView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        let path = makeStagePath(in: bounds)

        stageFillMaskLayer.frame = bounds
        stageFillMaskLayer.path = path.cgPath

        stageStrokeMaskLayer.frame = bounds
        stageStrokeMaskLayer.path = path.cgPath
        stageStrokeMaskLayer.fillColor = UIColor.clear.cgColor
        stageStrokeMaskLayer.strokeColor = UIColor.black.cgColor
        stageStrokeMaskLayer.lineWidth = 1
        stageStrokeMaskLayer.lineJoin = .round
        stageStrokeMaskLayer.lineCap = .round
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

        stageFillGradientLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
        stageFillGradientLayer.endPoint   = CGPoint(x: 0.5, y: 1.0)
        applyStageColors(cancelReady: false)
        stageFillGradientLayer.mask = stageFillMaskLayer
        stageView.layer.insertSublayer(stageFillGradientLayer, at: 0)

        // 对应 SVG linearGradient-2，作为路径描边高光
        stageStrokeGradientLayer.startPoint = CGPoint(x: 0.434104349, y: 0.4458284)
        stageStrokeGradientLayer.endPoint = CGPoint(x: 0.624221171, y: 0.54935366)
        stageStrokeGradientLayer.mask = stageStrokeMaskLayer
        stageView.layer.insertSublayer(stageStrokeGradientLayer, above: stageFillGradientLayer)

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

        waveformView.barColor = UIColor(red: 0.45, green: 0.22, blue: 0.75, alpha: 1)
        waveformView.setContentHuggingPriority(.required, for: .vertical)
        waveformView.setContentCompressionResistancePriority(.required, for: .vertical)

        timeLabel.text  = "0\""
        timeLabel.font  = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        timeLabel.textColor = .label
        timeLabel.textAlignment = .center
        timeLabel.setContentHuggingPriority(.required, for: .vertical)
        timeLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        bubbleStackView.axis = .vertical
        bubbleStackView.alignment = .center
        bubbleStackView.distribution = .fill
        bubbleStackView.spacing = 8
        bubbleStackView.translatesAutoresizingMaskIntoConstraints = false
        bubbleStackView.addArrangedSubview(waveformView)
        bubbleStackView.addArrangedSubview(timeLabel)
        bubbleView.addSubview(bubbleStackView)

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
            micImageView.topAnchor.constraint(equalTo:  stageView.topAnchor, constant: 28),

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

            // 气泡内：UIKit 版 VStack（上图标、下文本）
            bubbleStackView.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: 12),
            bubbleStackView.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -12),
            bubbleStackView.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: 20),
            bubbleStackView.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -20),
            bubbleStackView.centerXAnchor.constraint(equalTo: bubbleView.centerXAnchor),
        ])
    }

    // MARK: - 公共接口

    func setState(_ state: State) {
        let cancel = (state == .cancelReady)

        if cancel {
            bubbleView.backgroundColor    = .systemRed
            waveformView.barColor         = .white
            timeLabel.textColor           = .white
            cancelCircleView.backgroundColor = .systemRed
        } else {
            bubbleView.backgroundColor    = .white
            waveformView.barColor         = UIColor(red: 0.45, green: 0.22, blue: 0.75, alpha: 1)
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

    func updateAudioLevel(_ level: Float) {
        waveformView.update(level: CGFloat(level))
    }

    // MARK: - 私有

    private func applyStageColors(cancelReady: Bool) {
        if cancelReady {
            stageFillGradientLayer.colors = [
                UIColor.systemRed.cgColor,
                UIColor(red: 0.25, green: 0.02, blue: 0.02, alpha: 1).cgColor,
            ]
            stageStrokeGradientLayer.colors = [
                UIColor.white.withAlphaComponent(0.30).cgColor,
                UIColor.white.withAlphaComponent(0).cgColor,
            ]
        } else {
            // 来自设计稿 linearGradient-1 / linearGradient-2
            stageFillGradientLayer.colors = [
                UIColor(red: 0.204, green: 0.196, blue: 0.404, alpha: 1).cgColor, // #343267
                UIColor(red: 0.047, green: 0.094, blue: 0.196, alpha: 1).cgColor, // #0C1832
            ]
            stageStrokeGradientLayer.colors = [
                UIColor(red: 0.871, green: 0.875, blue: 0.894, alpha: 0.7).cgColor, // #DEDFE4 @ 70%
                UIColor(red: 0.224, green: 0.255, blue: 0.396, alpha: 0).cgColor,   // #394165 @ 0%
            ]
        }
    }

    private func makeStagePath(in bounds: CGRect) -> UIBezierPath {
        let designWidth: CGFloat = 375
        let designHeight: CGFloat = 117.816455

        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: x / designWidth * bounds.width,
                y: y / designHeight * bounds.height
            )
        }

        let path = UIBezierPath()
        path.move(to: p(0, 59.5320699))
        path.addLine(to: p(0, 117.816455))
        path.addLine(to: p(375, 117.816455))
        path.addLine(to: p(375, 56.5380362))
        path.addCurve(
            to: p(194, 0.0343900641),
            controlPoint1: p(320.333333, 20.594799),
            controlPoint2: p(260, 1.76025027)
        )
        path.addCurve(
            to: p(0, 59.5320699),
            controlPoint1: p(123.290266, -0.942431981),
            controlPoint2: p(58.6235991, 18.890128)
        )
        path.close()
        return path
    }
}

/// 录音电平波形（UIKit 版），外观类似语音输入中的实时音频动画。
private final class AudioLevelWaveformView: UIView {

    var barColor: UIColor = .systemBlue {
        didSet { barLayers.forEach { $0.backgroundColor = barColor.cgColor } }
    }

    // 对齐设计稿 SVG：71 x 13
    override var intrinsicContentSize: CGSize { CGSize(width: 71, height: 13) }

    private struct BarSpec {
        let x: CGFloat
        let width: CGFloat
        let baseHeight: CGFloat
        let phase: CGFloat
    }

    private static let designSize = CGSize(width: 71, height: 13)
    private static let barSpecs: [BarSpec] = [
        // 左侧组（5 根）
        .init(x: 0.0000, width: 1.9722, baseHeight: 7.2982, phase: 0.0),
        .init(x: 3.9444, width: 1.9722, baseHeight: 3.6491, phase: 0.8),
        .init(x: 7.8889, width: 1.9722, baseHeight: 13.0000, phase: 1.6),
        .init(x: 11.8333, width: 1.9722, baseHeight: 9.2323, phase: 2.4),
        .init(x: 15.7778, width: 1.9722, baseHeight: 5.4737, phase: 3.2),

        // 中间组（9 根）
        .init(x: 18.9333 + 0.0000, width: 1.9490, baseHeight: 10.7250, phase: 0.5),
        .init(x: 18.9333 + 3.8980, width: 1.9490, baseHeight: 6.5000, phase: 1.1),
        .init(x: 18.9333 + 7.7961, width: 1.9490, baseHeight: 13.0000, phase: 1.7),
        .init(x: 18.9333 + 11.6941, width: 1.9490, baseHeight: 7.8000, phase: 2.3),
        .init(x: 18.9333 + 15.5922, width: 1.9490, baseHeight: 5.2000, phase: 2.9),
        .init(x: 18.9333 + 19.4902, width: 1.9490, baseHeight: 9.4250, phase: 3.5),
        .init(x: 18.9333 + 23.3882, width: 1.9490, baseHeight: 13.0000, phase: 4.1),
        .init(x: 18.9333 + 27.2863, width: 1.9490, baseHeight: 10.7250, phase: 4.7),
        .init(x: 18.9333 + 31.1843, width: 1.9490, baseHeight: 6.8250, phase: 5.3),

        // 右侧组（5 根）
        .init(x: 53.2500 + 0.0000, width: 1.9722, baseHeight: 7.2982, phase: 0.3),
        .init(x: 53.2500 + 3.9444, width: 1.9722, baseHeight: 3.6491, phase: 1.1),
        .init(x: 53.2500 + 7.8889, width: 1.9722, baseHeight: 13.0000, phase: 1.9),
        .init(x: 53.2500 + 11.8333, width: 1.9722, baseHeight: 9.2323, phase: 2.7),
        .init(x: 53.2500 + 15.7778, width: 1.9722, baseHeight: 5.4737, phase: 3.5),
    ]

    private var barLayers: [CALayer] = []
    private var smoothedLevel: CGFloat = 0
    private var tick: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false

        for _ in Self.barSpecs {
            let bar = CALayer()
            bar.backgroundColor = barColor.cgColor
            layer.addSublayer(bar)
            barLayers.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 初始布局显示低电平静态态，避免首次出现空白。
        apply(level: smoothedLevel, animated: false)
    }

    func update(level: CGFloat) {
        let clamped = max(0, min(level, 1))
        // 一阶平滑，减少抖动
        smoothedLevel = smoothedLevel * 0.72 + clamped * 0.28
        tick += 1
        apply(level: smoothedLevel, animated: true)
    }

    private func apply(level: CGFloat, animated: Bool) {
        guard bounds.width > 0, bounds.height > 0, !barLayers.isEmpty else { return }

        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.05 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))

        let sx = bounds.width / Self.designSize.width
        let sy = bounds.height / Self.designSize.height
        let minHeight = max(1.2 * sy, 1)

        for (idx, spec) in Self.barSpecs.enumerated() {
            // 录音越大，整体越接近设计稿原始高度；低音量也保持最小跳动。
            let envelope = 0.35 + level * 0.95
            let pulse = 1 + 0.18 * sin((tick * 0.45) + spec.phase)
            let gain = max(0.12, min(envelope * pulse, 1.25))

            let baseHeight = spec.baseHeight * sy
            let height = min(bounds.height, max(minHeight, baseHeight * gain))
            let width = max(1, spec.width * sx)
            let x = spec.x * sx
            let y = (bounds.height - height) * 0.5

            let bar = barLayers[idx]
            bar.cornerRadius = min(width * 0.5, height * 0.5)
            bar.frame = CGRect(x: x, y: y, width: width, height: height)
        }

        CATransaction.commit()
    }
}
