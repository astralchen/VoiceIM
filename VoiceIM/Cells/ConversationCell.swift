import UIKit

/// 会话列表 Cell（微信风格布局）
final class ConversationCell: UITableViewCell {

    static let reuseIdentifier = "ConversationCell"

    private let avatarView = AvatarView()
    private let nameLabel = UILabel()
    private let previewLabel = UILabel()
    private let timeLabel = UILabel()
    private let badgeBackground = UIView()
    private let badgeLabel = UILabel()
    private let rightColumn = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .default
        backgroundColor = .clear
        contentView.backgroundColor = .systemBackground
        setupViews()
        setupConstraints()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.layer.cornerRadius = 28
        avatarView.layer.masksToBounds = true

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        nameLabel.textColor = .label
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.font = .systemFont(ofSize: 14)
        previewLabel.textColor = .secondaryLabel
        previewLabel.numberOfLines = 1
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = .systemFont(ofSize: 12)
        timeLabel.textColor = .secondaryLabel
        timeLabel.textAlignment = .right
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        badgeBackground.translatesAutoresizingMaskIntoConstraints = false
        badgeBackground.backgroundColor = .systemRed
        badgeBackground.layer.cornerRadius = 9
        badgeBackground.layer.masksToBounds = true
        badgeBackground.isHidden = true

        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        badgeLabel.textColor = .white
        badgeLabel.textAlignment = .center

        rightColumn.translatesAutoresizingMaskIntoConstraints = false
        rightColumn.axis = .vertical
        rightColumn.alignment = .trailing
        rightColumn.spacing = 4
        rightColumn.addArrangedSubview(timeLabel)
        rightColumn.addArrangedSubview(badgeBackground)

        contentView.addSubview(avatarView)
        contentView.addSubview(nameLabel)
        contentView.addSubview(previewLabel)
        contentView.addSubview(rightColumn)
        badgeBackground.addSubview(badgeLabel)
    }

    private func setupConstraints() {
        NSLayoutConstraint.activate([
            avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            avatarView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 56),
            avatarView.heightAnchor.constraint(equalToConstant: 56),

            rightColumn.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            rightColumn.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 11),

            nameLabel.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 12),
            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 11),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: rightColumn.leadingAnchor, constant: -8),

            previewLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            previewLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3),
            previewLabel.trailingAnchor.constraint(lessThanOrEqualTo: rightColumn.leadingAnchor, constant: -8),
            previewLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -11),

            badgeBackground.heightAnchor.constraint(equalToConstant: 18),
            badgeBackground.widthAnchor.constraint(greaterThanOrEqualTo: badgeBackground.heightAnchor),
            badgeBackground.widthAnchor.constraint(greaterThanOrEqualToConstant: 18),

            badgeLabel.leadingAnchor.constraint(equalTo: badgeBackground.leadingAnchor, constant: 6),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeBackground.trailingAnchor, constant: -6),
            badgeLabel.topAnchor.constraint(equalTo: badgeBackground.topAnchor),
            badgeLabel.bottomAnchor.constraint(equalTo: badgeBackground.bottomAnchor),
        ])
    }

    func configure(with summary: ConversationSummary) {
        let sender = Sender(id: summary.contact.id, displayName: summary.contact.displayName)
        avatarView.configure(with: sender)

        nameLabel.text = summary.contact.displayName

        let preview = summary.lastMessagePreview
        previewLabel.text = preview.isEmpty ? "暂无消息" : preview

        timeLabel.text = Self.formatConversationTime(summary.lastMessageTime)

        if summary.unreadCount > 0 {
            badgeBackground.isHidden = false
            badgeLabel.text = summary.unreadCount > 99 ? "99+" : "\(summary.unreadCount)"
        } else {
            badgeBackground.isHidden = true
            badgeLabel.text = nil
        }

        // 置顶会话轻微高亮，便于在列表中快速区分
        if summary.isPinned {
            contentView.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.12)
        } else {
            contentView.backgroundColor = .systemBackground
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        nameLabel.text = nil
        previewLabel.text = nil
        timeLabel.text = nil
        badgeLabel.text = nil
        badgeBackground.isHidden = true
        contentView.backgroundColor = .systemBackground
    }

    // MARK: - 时间（微信风格）

    private static func formatConversationTime(_ date: Date?) -> String {
        guard let date else { return "" }

        let cal = Calendar.current
        let now = Date()

        if cal.isDateInToday(date) {
            return timeHM.string(from: date)
        }
        if cal.isDateInYesterday(date) {
            return "昨天"
        }
        if cal.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
            return weekdayShort.string(from: date)
        }
        if cal.isDate(date, equalTo: now, toGranularity: .year) {
            return monthDay.string(from: date)
        }
        return fullDate.string(from: date)
    }

    private static let zhCN = Locale(identifier: "zh_CN")

    private static let timeHM: DateFormatter = {
        let f = DateFormatter()
        f.locale = zhCN
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let weekdayShort: DateFormatter = {
        let f = DateFormatter()
        f.locale = zhCN
        f.dateFormat = "EEE"
        return f
    }()

    private static let monthDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = zhCN
        f.dateFormat = "M月d日"
        return f
    }()

    private static let fullDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = zhCN
        f.dateFormat = "yyyy年M月d日"
        return f
    }()
}
