import UIKit
import Combine

final class ConversationListViewController: UIViewController {
    private enum Section {
        case main
    }

    private let collectionView: UICollectionView
    private let viewModel: ConversationListViewModel
    private let dependencies: AppDependencies
    private var cancellables = Set<AnyCancellable>()
    private var dataSource: UICollectionViewDiffableDataSource<Section, ConversationSummary>!

    init(
        viewModel: ConversationListViewModel,
        dependencies: AppDependencies
    ) {
        let layoutConfig = UICollectionLayoutListConfiguration(appearance: .plain)
        self.collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: layoutConfig)
        )
        self.viewModel = viewModel
        self.dependencies = dependencies
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "VoiceIM"
        view.backgroundColor = .systemBackground
        setupCollectionView()
        configureDataSource()
        bindViewModel()
        viewModel.loadConversations()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.loadConversations()
    }

    private func setupCollectionView() {
        var listConfig = UICollectionLayoutListConfiguration(appearance: .plain)
        listConfig.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            self?.makeTrailingSwipeActions(for: indexPath)
        }
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout.list(using: listConfig)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .systemBackground
        collectionView.delegate = self
        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, ConversationSummary> {
            cell, _, summary in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = summary.contact.displayName
            content.secondaryText = summary.lastMessagePreview.isEmpty ? "暂无消息" : summary.lastMessagePreview
            content.textProperties.font = .systemFont(ofSize: 16, weight: .semibold)
            content.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = content

            var accessories: [UICellAccessory] = [.disclosureIndicator()]
            if summary.unreadCount > 0 {
                let unreadText = summary.unreadCount > 99 ? "99+" : "\(summary.unreadCount)"
                accessories.insert(
                    .label(text: unreadText, options: .init(isHidden: false)),
                    at: 0
                )
            }
            cell.accessories = accessories

            var background = UIBackgroundConfiguration.listPlainCell()
            background.backgroundColor = summary.isPinned
                ? UIColor.systemYellow.withAlphaComponent(0.12)
                : .systemBackground
            cell.backgroundConfiguration = background
        }

        dataSource = UICollectionViewDiffableDataSource<Section, ConversationSummary>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(
                using: registration,
                for: indexPath,
                item: item
            )
        }
    }

    private func bindViewModel() {
        viewModel.$conversations
            .receive(on: DispatchQueue.main)
            .sink { [weak self] conversations in
                var snapshot = NSDiffableDataSourceSnapshot<Section, ConversationSummary>()
                snapshot.appendSections([.main])
                snapshot.appendItems(conversations, toSection: .main)
                self?.dataSource.apply(snapshot, animatingDifferences: true)
            }
            .store(in: &cancellables)
    }
}

extension ConversationListViewController: UICollectionViewDelegate {
    private func makeTrailingSwipeActions(for indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.item < viewModel.conversations.count else { return nil }
        let summary = viewModel.conversations[indexPath.item]
        let contactID = summary.contact.id

        let deleteAction = UIContextualAction(style: .destructive, title: "删除") {
            [weak self] _, _, completion in
            self?.viewModel.deleteConversation(contactID: contactID)
            completion(true)
        }

        let pinTitle = summary.isPinned ? "取消置顶" : "置顶"
        let pinAction = UIContextualAction(style: .normal, title: pinTitle) {
            [weak self] _, _, completion in
            self?.viewModel.setConversationPinned(contactID: contactID, pinned: !summary.isPinned)
            completion(true)
        }
        pinAction.backgroundColor = .systemOrange

        let hideAction = UIContextualAction(style: .normal, title: "不显示") {
            [weak self] _, _, completion in
            self?.viewModel.setConversationHidden(contactID: contactID, hidden: true)
            completion(true)
        }
        hideAction.backgroundColor = .systemGray

        let readAction = UIContextualAction(style: .normal, title: "标记已读") {
            [weak self] _, _, completion in
            self?.viewModel.markConversationAsRead(contactID: contactID)
            completion(true)
        }
        readAction.backgroundColor = .systemBlue

        let config = UISwipeActionsConfiguration(actions: [deleteAction, readAction, pinAction, hideAction])
        config.performsFirstActionWithFullSwipe = true
        return config
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard indexPath.item < viewModel.conversations.count else { return }
        let contact = viewModel.conversations[indexPath.item].contact
        let chatViewModel = dependencies.makeChatViewModel(contact: contact)
        let chatVC = VoiceChatViewController(viewModel: chatViewModel)
        chatVC.hidesBottomBarWhenPushed = true
        navigationController?.pushViewController(chatVC, animated: true)
    }
}
