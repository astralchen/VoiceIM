import UIKit
@preconcurrency import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

/// 相册选择器管理器，提供 async/await 风格的 API
@MainActor
final class PhotoPickerManager: NSObject, PhotoPickerService {

    // MARK: - 单例

    static let shared = PhotoPickerManager()

    private override init() {
        super.init()
    }

    // MARK: - Continuation

    private var pickerContinuation: CheckedContinuation<NSItemProvider?, Error>?

    // MARK: - 错误类型

    enum PickerError: Error {
        case cancelled
        case fileNotFound
        case unsupportedType
    }

    // MARK: - 公开 API

    /// 选择图片或视频（返回本地临时文件 URL）
    /// - Parameters:
    ///   - viewController: 展示选择器的 ViewController
    ///   - allowsMultiple: 是否允许多选（默认单选）
    /// - Returns: 选择的资源，用户取消时返回 nil
    func pickMedia(from viewController: UIViewController, allowsMultiple: Bool = false) async throws -> PhotoPickerResult? {
        guard let itemProvider = try await presentPicker(
            from: viewController,
            filter: .any(of: [.images, .videos]),
            selectionLimit: allowsMultiple ? 0 : 1
        ) else {
            return nil
        }

        return try await loadMedia(from: itemProvider)
    }

    /// 仅选择图片
    func pickImage(from viewController: UIViewController) async throws -> URL? {
        guard let itemProvider = try await presentPicker(
            from: viewController,
            filter: .images,
            selectionLimit: 1
        ) else {
            return nil
        }

        return try await loadImage(from: itemProvider)
    }

    /// 仅选择视频
    func pickVideo(from viewController: UIViewController) async throws -> (url: URL, duration: TimeInterval)? {
        guard let itemProvider = try await presentPicker(
            from: viewController,
            filter: .videos,
            selectionLimit: 1
        ) else {
            return nil
        }

        return try await loadVideo(from: itemProvider)
    }

    // MARK: - 内部实现

    /// 展示相册选择器并等待用户选择
    private func presentPicker(
        from viewController: UIViewController,
        filter: PHPickerFilter,
        selectionLimit: Int
    ) async throws -> NSItemProvider? {
        var config = PHPickerConfiguration()
        config.selectionLimit = selectionLimit
        config.filter = filter

        // iOS 15+ 支持设置首选资源表示模式
        if #available(iOS 15, *) {
            config.preferredAssetRepresentationMode = .compatible  // 兼容模式，自动转换为兼容格式
        }

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self

        // iOS 16+ 支持设置 sheet 尺寸
        if #available(iOS 16.0, *) {
            if let sheet = picker.sheetPresentationController {
                sheet.detents = [.medium(), .large()]  // 默认中等尺寸，用户可拖动到大尺寸
                sheet.prefersGrabberVisible = true     // 显示顶部拖动条
                sheet.preferredCornerRadius = 16       // 圆角半径
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.pickerContinuation = continuation
            viewController.present(picker, animated: true)
        }
    }

    /// 加载图片或视频（自动判断类型）
    private func loadMedia(from itemProvider: NSItemProvider) async throws -> PhotoPickerResult {
        if itemProvider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            let url = try await loadImage(from: itemProvider)
            return .image(url)
        } else if itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            let (url, duration) = try await loadVideo(from: itemProvider)
            return .video(url, duration: duration)
        } else {
            throw PickerError.unsupportedType
        }
    }

    /// 加载图片文件
    private func loadImage(from itemProvider: NSItemProvider) async throws -> URL {
        try await loadFileRepresentation(
            from: itemProvider,
            typeIdentifier: UTType.image.identifier
        )
    }

    /// 加载视频文件并获取时长
    private func loadVideo(from itemProvider: NSItemProvider) async throws -> (url: URL, duration: TimeInterval) {
        let url = try await loadFileRepresentation(
            from: itemProvider,
            typeIdentifier: UTType.movie.identifier
        )

        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration).seconds

        return (url, duration)
    }

    /// 异步加载文件表示并复制到临时目录
    private func loadFileRepresentation(
        from itemProvider: NSItemProvider,
        typeIdentifier: String
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            itemProvider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let url = url else {
                    continuation.resume(throwing: PickerError.fileNotFound)
                    return
                }

                // 复制到临时目录（原文件在回调结束后会被系统删除）
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(url.pathExtension)

                do {
                    try FileManager.default.copyItem(at: url, to: tempURL)
                    continuation.resume(returning: tempURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - PHPickerViewControllerDelegate

extension PhotoPickerManager: PHPickerViewControllerDelegate {

    nonisolated func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        let itemProvider = results.first?.itemProvider

        Task { @MainActor in
            picker.dismiss(animated: true)
            picker.delegate = nil  // 清理 delegate 引用

            guard let continuation = self.pickerContinuation else { return }
            self.pickerContinuation = nil

            continuation.resume(returning: itemProvider)
        }
    }
}
