import UIKit
import MapKit

@MainActor
protocol LocationMessageCellDelegate: AnyObject {
    func cellDidTapLocation(_ cell: LocationMessageCell, message: ChatMessage)
}

/// 位置消息 Cell，继承 ChatBubbleCell 获得时间分隔行、头像和收/发方向布局。
/// 显示地图缩略图和地址信息。
@MainActor
final class LocationMessageCell: ChatBubbleCell {

    nonisolated static let reuseID = "LocationMessageCell"

    weak var delegate: LocationMessageCellDelegate?
    private(set) var message: ChatMessage?

    // MARK: - 子视图

    private let mapView = MKMapView()
    private let addressLabel = UILabel()
    private let pinImageView = UIImageView()

    // MARK: - 初始化

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLocationUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - UI 搭建

    private func setupLocationUI() {
        // 地图视图
        mapView.isUserInteractionEnabled = false  // 禁用地图交互，点击整个 cell 打开地图
        mapView.layer.cornerRadius = 8
        mapView.clipsToBounds = true
        mapView.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(mapView)

        // 地址标签
        addressLabel.font = .systemFont(ofSize: 14)
        addressLabel.textColor = .label
        addressLabel.numberOfLines = 2
        addressLabel.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.9)
        addressLabel.layer.cornerRadius = 4
        addressLabel.clipsToBounds = true
        addressLabel.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(addressLabel)

        // 定位图标
        pinImageView.image = UIImage(systemName: "mappin.circle.fill")
        pinImageView.tintColor = .systemRed
        pinImageView.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(pinImageView)

        // 添加点击手势
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(locationTapped))
        bubble.addGestureRecognizer(tapGesture)

        NSLayoutConstraint.activate([
            // 地图视图
            mapView.topAnchor.constraint(equalTo: bubble.topAnchor),
            mapView.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
            mapView.widthAnchor.constraint(equalToConstant: 200),
            mapView.heightAnchor.constraint(equalToConstant: 150),

            // 定位图标（地图中心）
            pinImageView.centerXAnchor.constraint(equalTo: mapView.centerXAnchor),
            pinImageView.centerYAnchor.constraint(equalTo: mapView.centerYAnchor),
            pinImageView.widthAnchor.constraint(equalToConstant: 30),
            pinImageView.heightAnchor.constraint(equalToConstant: 30),

            // 地址标签（地图底部）
            addressLabel.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 8),
            addressLabel.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -8),
            addressLabel.topAnchor.constraint(equalTo: mapView.bottomAnchor, constant: 8),
            addressLabel.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -8),
        ])
    }

    // MARK: - 配置

    func configure(with message: ChatMessage, latitude: Double, longitude: Double, address: String?) {
        self.message = message

        // 设置地图中心和缩放级别
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 500, longitudinalMeters: 500)
        mapView.setRegion(region, animated: false)

        // 设置地址文本
        if let address = address, !address.isEmpty {
            addressLabel.text = "  \(address)  "
            addressLabel.isHidden = false
        } else {
            addressLabel.text = "  位置  "
            addressLabel.isHidden = false
        }
    }

    // MARK: - 事件处理

    @objc private func locationTapped() {
        guard let msg = message else { return }
        delegate?.cellDidTapLocation(self, message: msg)
    }
}

// MARK: - MessageCellConfigurable

extension LocationMessageCell: MessageCellConfigurable {

    func configure(with message: ChatMessage, deps: MessageCellDependencies) {
        // 先调基类方法更新时间分隔行、头像和收/发方向
        configureCommon(message: message, showTimeHeader: deps.showTimeHeader)

        // 设置 delegate
        delegate = deps.locationDelegate

        // 获取位置信息
        if case .location(let latitude, let longitude, let address) = message.kind {
            configure(with: message, latitude: latitude, longitude: longitude, address: address)
        }
    }
}
