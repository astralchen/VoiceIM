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

    /// 音量条数量（基于实际显示宽度计算）
    private var barCount: Int {
        // 使用实际渲染宽度，确保波形填满容器
        let width = bounds.width

        // 布局前 bounds.width = 0，回退到基于 intrinsicContentSize 的估算
        guard width > 0 else {
            let estimatedWidth = intrinsicContentSize.width
            let barUnit = barWidth + barSpacing
            return max(5, Int((estimatedWidth + barSpacing) / barUnit))
        }

        let barUnit = barWidth + barSpacing
        return max(5, Int((width + barSpacing) / barUnit))
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

    /// 音频时长（秒），用于计算视图宽度和音量条数量
    var audioDuration: TimeInterval = 0 {
        didSet {
            audioDuration = max(0, audioDuration)  // 确保非负
            generateRandomHeights()  // 重新生成波形数据以匹配新的 barCount
            invalidateIntrinsicContentSize()
            setNeedsDisplay()  // 重新绘制以更新音量条数量
        }
    }

    /// 最小宽度（1-2秒短语音）
    var minimumWidth: CGFloat = 80 {
        didSet {
            minimumWidth = max(60, minimumWidth)
            if minimumWidth > maximumWidth {
                maximumWidth = minimumWidth
            }
            invalidateIntrinsicContentSize()
        }
    }

    /// 最大宽度（60秒长语音）
    var maximumWidth: CGFloat = 220 {
        didSet {
            maximumWidth = max(minimumWidth, maximumWidth)
            invalidateIntrinsicContentSize()
        }
    }

    /// 线性增长的分界点（秒），超过此时长后使用对数增长
    var linearThreshold: TimeInterval = 10 {
        didSet {
            linearThreshold = max(1, linearThreshold)
            invalidateIntrinsicContentSize()
        }
    }

    /// 线性增长速率（pt/秒），仅在 duration ≤ linearThreshold 时生效
    var linearGrowthRate: CGFloat = 12 {
        didSet {
            linearGrowthRate = max(1, linearGrowthRate)
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

    // MARK: - 布局监听

    private var lastLayoutWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()

        // 当实际宽度变化时，重新生成波形数据
        // 使用阈值避免频繁重绘
        let currentWidth = bounds.width
        guard abs(currentWidth - lastLayoutWidth) > 5 else { return }

        lastLayoutWidth = currentWidth
        let newBarCount = barCount

        // 仅当条数变化时才重新生成波形数据
        if barHeights.count != newBarCount {
            generateRandomHeights()
            setNeedsDisplay()
        }
    }

    // MARK: - 固有尺寸

    override var intrinsicContentSize: CGSize {
        // 分段增长策略：模仿微信/Telegram 的语音消息宽度设计
        //
        // 阶段1（≤ linearThreshold 秒）：线性增长
        //   公式：minimumWidth + linearGrowthRate × duration
        //   示例（linearThreshold=10, linearGrowthRate=12, minimumWidth=80）：
        //     1秒  = 80 + 12×1  = 92pt
        //     2秒  = 80 + 12×2  = 104pt
        //     5秒  = 80 + 12×5  = 140pt
        //     10秒 = 80 + 12×10 = 200pt
        //
        // 阶段2（> linearThreshold 秒）：对数增长（增速放缓）
        //   公式：widthAtThreshold + 30 × log₂(duration / linearThreshold)
        //   示例（从10秒的200pt开始）：
        //     15秒 = 200 + 30×log₂(15/10) = 200 + 30×0.58 = 217pt
        //     30秒 = 200 + 30×log₂(30/10) = 200 + 30×1.58 = 247pt（受 maximumWidth=220 限制）
        //     60秒 = 200 + 30×log₂(60/10) = 200 + 30×2.58 = 277pt（受 maximumWidth=220 限制）

        let calculatedWidth: CGFloat

        if audioDuration <= linearThreshold {
            // 阶段1：线性增长
            calculatedWidth = minimumWidth + linearGrowthRate * CGFloat(audioDuration)
        } else {
            // 阶段2：对数增长
            let widthAtThreshold = minimumWidth + linearGrowthRate * CGFloat(linearThreshold)
            let ratio = CGFloat(audioDuration) / CGFloat(linearThreshold)
            let extraGrowth = 30 * log2(ratio)
            calculatedWidth = widthAtThreshold + extraGrowth
        }

        let clampedWidth = max(minimumWidth, min(maximumWidth, calculatedWidth))
        return CGSize(width: clampedWidth, height: UIView.noIntrinsicMetric)
    }

    // MARK: - 绘制

    override func draw(_ rect: CGRect) {
        super.draw(rect)

        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        let availableWidth = rect.width
        let maxHeight = rect.height

        // 使用根据时长计算的音量条数量，保持固定视觉密度
        let actualBarCount = barCount
        let totalBarWidth = CGFloat(actualBarCount) * barWidth + CGFloat(actualBarCount - 1) * barSpacing

        // 如果计算的总宽度超过可用宽度，按比例缩小间距
        let actualBarSpacing: CGFloat
        if totalBarWidth > availableWidth {
            // 重新计算间距以适应容器宽度
            let totalBarsWidth = CGFloat(actualBarCount) * barWidth
            let availableSpacing = availableWidth - totalBarsWidth
            actualBarSpacing = max(1, availableSpacing / CGFloat(actualBarCount - 1))
        } else {
            actualBarSpacing = barSpacing
        }

        let startX: CGFloat = 0

        // 绘制音量条
        for i in 0..<actualBarCount {
            let x = startX + CGFloat(i) * (barWidth + actualBarSpacing)

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
            let actualTotalWidth = CGFloat(actualBarCount) * barWidth + CGFloat(actualBarCount - 1) * actualBarSpacing
            let lineX = startX + actualTotalWidth * CGFloat(progress)

            // 创建渐变色（中间深，两端淡）
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let colors = [
                progressLineColor.withAlphaComponent(0.3).cgColor,
                progressLineColor.cgColor,
                progressLineColor.withAlphaComponent(0.3).cgColor
            ] as CFArray

            let locations: [CGFloat] = [0.0, 0.5, 1.0]

            guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) else {
                return
            }

            // 绘制渐变线
            ctx.saveGState()
            ctx.setLineWidth(progressLineWidth)
            ctx.setLineCap(.round)

            // 裁剪区域为线条路径
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
        // 使用根据时长计算的音量条数量
        let availableWidth = bounds.width
        let actualBarCount = barCount
        let totalBarWidth = CGFloat(actualBarCount) * barWidth + CGFloat(actualBarCount - 1) * barSpacing

        // 计算实际间距
        let actualBarSpacing: CGFloat
        if totalBarWidth > availableWidth {
            let totalBarsWidth = CGFloat(actualBarCount) * barWidth
            let availableSpacing = availableWidth - totalBarsWidth
            actualBarSpacing = max(1, availableSpacing / CGFloat(actualBarCount - 1))
        } else {
            actualBarSpacing = barSpacing
        }

        let startX: CGFloat = 0
        let actualTotalWidth = CGFloat(actualBarCount) * barWidth + CGFloat(actualBarCount - 1) * actualBarSpacing
        let relativeX = location.x - startX
        let newProgress = Float(relativeX / actualTotalWidth)
        progress = max(0, min(1, newProgress))
    }

    // MARK: - 工具方法

    /// 生成随机音量条高度（模拟波形）
    private func generateRandomHeights() {
        let count = barCount

        // 如果条数变化不大，保持现有波形（避免闪烁）
        if !barHeights.isEmpty && abs(barHeights.count - count) < 3 {
            return
        }

        barHeights = (0..<count).map { i in
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
        setNeedsDisplay()
    }

    /// 从音频文件提取波形数据
    /// - Parameters:
    ///   - audioURL: 音频文件 URL
    ///   - targetBarCount: 目标音量条数量（默认 nil，自动根据实际宽度计算）
    /// - Note: 调用前需先设置 audioDuration 以触发宽度更新
    func loadWaveform(from audioURL: URL, targetBarCount: Int? = nil) {
        Task.detached(priority: .userInitiated) {
            // 如果未指定 targetBarCount，使用当前的 barCount
            let count = await MainActor.run {
                targetBarCount ?? self.barCount
            }

            guard let samples = await self.extractAudioSamples(from: audioURL, targetCount: count) else {
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
