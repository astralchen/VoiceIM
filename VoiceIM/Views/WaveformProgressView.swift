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

    // MARK: - 绘制

    override func draw(_ rect: CGRect) {
        super.draw(rect)

        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
        let startX = (rect.width - totalWidth) / 2
        let maxHeight = rect.height

        // 绘制音量条
        for i in 0..<barCount {
            let x = startX + CGFloat(i) * (barWidth + barSpacing)
            let normalizedHeight = barHeights[i]
            let barHeight = maxHeight * normalizedHeight
            let y = (maxHeight - barHeight) / 2

            let barRect = CGRect(x: x, y: y, width: barWidth, height: barHeight)

            // 判断当前音量条是否在已播放区域
            let barProgress = CGFloat(i) / CGFloat(barCount - 1)
            let color = barProgress < CGFloat(progress) ? playedColor : unplayedColor

            ctx.setFillColor(color.cgColor)
            ctx.fill(barRect)
        }

        // 绘制进度指示线
        if progress > 0 {
            let lineX = startX + totalWidth * CGFloat(progress)
            ctx.setStrokeColor(progressLineColor.cgColor)
            ctx.setLineWidth(progressLineWidth)
            ctx.move(to: CGPoint(x: lineX, y: 0))
            ctx.addLine(to: CGPoint(x: lineX, y: maxHeight))
            ctx.strokePath()
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
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
        let startX = (bounds.width - totalWidth) / 2
        let relativeX = location.x - startX
        let newProgress = Float(relativeX / totalWidth)
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
        guard let asset = try? AVURLAsset(url: url) else { return nil }

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
