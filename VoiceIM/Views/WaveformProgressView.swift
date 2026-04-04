import UIKit
import AVFoundation

/// 音量条样式的进度视图，模仿抖音语音消息 UI
/// - 显示多个垂直音量条，已播放部分颜色亮，未播放部分颜色暗
/// - 垂直线指示当前播放进度
/// - 支持拖拽跳转播放位置
/// - 从音频文件提取真实波形数据
final class WaveformProgressView: UIControl {

    // MARK: - 公开属性

    /// 当前进度 (0.0 ~ 1.0)
    var progress: Float = 0 {
        didSet {
            progress = max(0, min(1, progress))
            setNeedsDisplay()
        }
    }

    /// 音量条数量
    var barCount: Int = 20 {
        didSet { setNeedsDisplay() }
    }

    /// 音量条宽度
    var barWidth: CGFloat = 2 {
        didSet { setNeedsDisplay() }
    }

    /// 音量条间距
    var barSpacing: CGFloat = 3 {
        didSet { setNeedsDisplay() }
    }

    /// 音量条圆角半径
    var barCornerRadius: CGFloat = 1 {
        didSet { setNeedsDisplay() }
    }

    /// 音频时长（秒），用于计算视图宽度
    var audioDuration: TimeInterval = 0 {
        didSet {
            audioDuration = max(0, audioDuration)  // 确保非负
            invalidateIntrinsicContentSize()
        }
    }

    /// 每秒对应的宽度（pt）
    /// 修改此值时会自动按比例调整 minimumWidth 和 maximumWidth 以保持逻辑一致性
    /// 默认：最小宽度对应 4 秒，最大宽度对应 10 秒
    ///
    /// 示例：widthPerSecond 从 12 改为 15
    /// - 比例：15/12 = 1.25
    /// - minimumWidth：48 × 1.25 = 60
    /// - maximumWidth：120 × 1.25 = 150
    var widthPerSecond: CGFloat = 12 {
        didSet {
            let oldValue = oldValue
            widthPerSecond = max(1, widthPerSecond)  // 至少 1pt/秒

            // 自动按比例调整 min/max，保持时长对应关系不变
            // 这样外部只需修改 widthPerSecond，无需手动计算 min/max
            if widthPerSecond != oldValue && oldValue > 0 {
                let ratio = widthPerSecond / oldValue
                minimumWidth = minimumWidth * ratio
                maximumWidth = maximumWidth * ratio
            }
            invalidateIntrinsicContentSize()
        }
    }

    /// 最小宽度（对应约 4 秒语音）
    /// 建议值：widthPerSecond × 4
    var minimumWidth: CGFloat = 48 {
        didSet {
            minimumWidth = max(20, minimumWidth)  // 至少 20pt
            if minimumWidth > maximumWidth {
                maximumWidth = minimumWidth  // 确保最小值不大于最大值
            }
            invalidateIntrinsicContentSize()
        }
    }

    /// 最大宽度（对应约 10 秒语音）
    /// 建议值：widthPerSecond × 10
    var maximumWidth: CGFloat = 120 {
        didSet {
            maximumWidth = max(minimumWidth, maximumWidth)  // 确保不小于最小值
            invalidateIntrinsicContentSize()
        }
    }

    /// 已播放部分颜色（亮色）
    var playedColor: UIColor = .systemBlue {
        didSet { setNeedsDisplay() }
    }

    /// 未播放部分颜色（暗色）
    var unplayedColor: UIColor = UIColor.systemGray.withAlphaComponent(0.3) {
        didSet { setNeedsDisplay() }
    }

    /// 进度指示线颜色
    var progressLineColor: UIColor = .systemBlue {
        didSet { setNeedsDisplay() }
    }

    /// 进度指示线宽度
    var progressLineWidth: CGFloat = 1.5 {
        didSet { setNeedsDisplay() }
    }

    // MARK: - 私有属性

    /// 音量条高度数组（归一化到 0.0 ~ 1.0）
    private var barHeights: [CGFloat] = []

    /// 用户是否正在拖拽
    private var isDragging = false

    // MARK: - 初始化

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .clear
        generateRandomHeights()

        // 添加手势支持拖拽
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }

    // MARK: - 固有尺寸

    override var intrinsicContentSize: CGSize {
        // 根据音频时长动态计算宽度
        // 公式：宽度 = 时长（秒） × 每秒宽度（pt）
        // 限制：在 minimumWidth 和 maximumWidth 之间
        let calculatedWidth = CGFloat(audioDuration) * widthPerSecond
        let clampedWidth = max(minimumWidth, min(maximumWidth, calculatedWidth))
        return CGSize(width: clampedWidth, height: UIView.noIntrinsicMetric)
    }

    // MARK: - 绘制

    override func draw(_ rect: CGRect) {
        super.draw(rect)

        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        // 根据视图实际宽度动态调整音量条数量，保持合理的视觉密度
        let totalBarWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
        let availableWidth = rect.width

        // 如果计算的总宽度超过可用宽度，自动减少音量条数量填充满视图
        // 否则居中显示
        let actualBarCount: Int
        let startX: CGFloat

        if totalBarWidth > availableWidth {
            // 根据可用宽度计算实际能显示的音量条数量（至少 10 个）
            actualBarCount = max(10, Int((availableWidth + barSpacing) / (barWidth + barSpacing)))
            startX = 0
        } else {
            actualBarCount = barCount
            startX = (availableWidth - totalBarWidth) / 2
        }

        let maxHeight = rect.height

        // 绘制音量条
        for i in 0..<actualBarCount {
            let x = startX + CGFloat(i) * (barWidth + barSpacing)

            // 从原始波形数据中按比例采样，保持波形形状
            let sampleIndex = min(i * barHeights.count / actualBarCount, barHeights.count - 1)
            let normalizedHeight = barHeights[sampleIndex]
            let barHeight = maxHeight * normalizedHeight
            let y = (maxHeight - barHeight) / 2

            let barRect = CGRect(x: x, y: y, width: barWidth, height: barHeight)

            // 判断当前音量条是否在已播放区域
            let barProgress = CGFloat(i) / CGFloat(actualBarCount - 1)
            let color = barProgress < CGFloat(progress) ? playedColor : unplayedColor

            ctx.setFillColor(color.cgColor)

            // 绘制圆角矩形
            let path = UIBezierPath(roundedRect: barRect, cornerRadius: barCornerRadius)
            ctx.addPath(path.cgPath)
            ctx.fillPath()
        }

        // 绘制进度指示线（使用渐变色：顶部和底部淡，中间深）
        if progress > 0 {
            let actualTotalWidth = CGFloat(actualBarCount) * barWidth + CGFloat(actualBarCount - 1) * barSpacing
            let lineX = startX + actualTotalWidth * CGFloat(progress)

            // 创建渐变色（中间深，两端淡）
            // 这样的渐变效果更自然，不会显得突兀
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let colors = [
                progressLineColor.withAlphaComponent(0.3).cgColor,  // 顶部淡
                progressLineColor.cgColor,                          // 中间深
                progressLineColor.withAlphaComponent(0.3).cgColor   // 底部淡
            ] as CFArray

            let locations: [CGFloat] = [0.0, 0.5, 1.0]

            guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) else {
                return
            }

            // 绘制渐变线
            ctx.saveGState()
            ctx.setLineWidth(progressLineWidth)
            ctx.setLineCap(.round)

            // 裁剪区域为线条路径，确保渐变只应用在线条上
            let linePath = CGMutablePath()
            linePath.move(to: CGPoint(x: lineX, y: 0))
            linePath.addLine(to: CGPoint(x: lineX, y: maxHeight))
            ctx.addPath(linePath)
            ctx.replacePathWithStrokedPath()
            ctx.clip()

            // 绘制垂直渐变
            let startPoint = CGPoint(x: lineX, y: 0)
            let endPoint = CGPoint(x: lineX, y: maxHeight)
            ctx.drawLinearGradient(gradient, start: startPoint, end: endPoint, options: [])

            ctx.restoreGState()
        }
    }

    // MARK: - 手势处理

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: self)
        updateProgress(at: location)

        switch gesture.state {
        case .began:
            isDragging = true
            sendActions(for: .touchDown)
        case .changed:
            sendActions(for: .valueChanged)
        case .ended, .cancelled:
            isDragging = false
            sendActions(for: .touchUpInside)
        default:
            break
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: self)
        updateProgress(at: location)
        sendActions(for: .valueChanged)
        sendActions(for: .touchUpInside)
    }

    private func updateProgress(at location: CGPoint) {
        // 根据实际绘制的音量条计算进度
        let totalBarWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
        let availableWidth = bounds.width

        let actualBarCount: Int
        let startX: CGFloat

        if totalBarWidth > availableWidth {
            actualBarCount = max(10, Int((availableWidth + barSpacing) / (barWidth + barSpacing)))
            startX = 0
        } else {
            actualBarCount = barCount
            startX = (availableWidth - totalBarWidth) / 2
        }

        let actualTotalWidth = CGFloat(actualBarCount) * barWidth + CGFloat(actualBarCount - 1) * barSpacing
        let relativeX = location.x - startX
        let newProgress = Float(relativeX / actualTotalWidth)
        progress = max(0, min(1, newProgress))
    }

    // MARK: - 工具方法

    /// 生成随机音量条高度（模拟波形）
    private func generateRandomHeights() {
        barHeights = (0..<barCount).map { i in
            // 使用正弦波 + 随机噪声生成自然的波形
            let sine = sin(Double(i) * 0.5) * 0.3 + 0.5
            let noise = Double.random(in: 0.3...0.7)
            return CGFloat(sine * noise)
        }
    }

    /// 设置自定义波形数据（可选，用于真实音频波形）
    func setWaveform(_ heights: [CGFloat]) {
        guard !heights.isEmpty else { return }
        barHeights = heights.map { max(0.2, min(1.0, $0)) }
        barCount = heights.count
        setNeedsDisplay()
    }

    /// 从音频文件提取波形数据
    /// - Parameters:
    ///   - audioURL: 音频文件 URL
    ///   - targetBarCount: 目标音量条数量（默认 20）
    /// - Note: 调用前需先设置 audioDuration 以触发宽度更新
    func loadWaveform(from audioURL: URL, targetBarCount: Int = 20) {
        Task.detached(priority: .userInitiated) {
            guard let samples = await self.extractAudioSamples(from: audioURL, targetCount: targetBarCount) else {
                return
            }
            await MainActor.run {
                self.setWaveform(samples)
            }
        }
    }

    /// 提取音频采样数据
    private func extractAudioSamples(from url: URL, targetCount: Int) async -> [CGFloat]? {
        let asset = AVURLAsset(url: url)

        // 获取音频轨道
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
            return nil
        }

        // 创建 AssetReader
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(output)

        guard reader.startReading() else { return nil }

        var samples: [CGFloat] = []
        var allSamples: [Int16] = []

        // 读取所有采样数据
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

            let length = CMBlockBufferGetDataLength(blockBuffer)
            var data = Data(count: length)

            _ = data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
            }

            let int16Samples = data.withUnsafeBytes {
                Array($0.bindMemory(to: Int16.self))
            }
            allSamples.append(contentsOf: int16Samples)
        }

        guard !allSamples.isEmpty else { return nil }

        // 降采样到目标数量
        let samplesPerBar = max(1, allSamples.count / targetCount)

        for i in 0..<targetCount {
            let startIndex = i * samplesPerBar
            let endIndex = min(startIndex + samplesPerBar, allSamples.count)

            guard startIndex < allSamples.count else { break }

            // 计算该区间的 RMS（均方根）
            let slice = allSamples[startIndex..<endIndex]
            let sum = slice.reduce(0.0) { $0 + pow(Double($1), 2) }
            let rms = sqrt(sum / Double(slice.count))

            // 归一化到 0.0 ~ 1.0
            let normalized = CGFloat(rms / 32768.0) // Int16 最大值
            samples.append(max(0.2, min(1.0, normalized * 2.0))) // 放大 2 倍增强视觉效果
        }

        return samples
    }
}
