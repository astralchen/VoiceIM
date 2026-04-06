import UIKit

/// 通讯录页：从联系人列表直接进入聊天
@MainActor
final class ContactsViewController: UIViewController {
    private enum Section {
        case main
    }

    private let collectionView: UICollectionView
    private let contacts: [Contact]
    private let dependencies: AppDependencies
    private var dataSource: UICollectionViewDiffableDataSource<Section, Contact>!

    init(
        contacts: [Contact] = Contact.mockContacts,
        dependencies: AppDependencies
    ) {
        let layoutConfig = UICollectionLayoutListConfiguration(appearance: .plain)
        self.collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: layoutConfig)
        )
        self.contacts = contacts
        self.dependencies = dependencies
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "通讯录"
        view.backgroundColor = .systemBackground
        setupCollectionView()
        configureDataSource()
        applySnapshot()
    }

    private func setupCollectionView() {
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
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Contact> {
            cell, _, contact in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = contact.displayName
            content.secondaryText = contact.id
            content.textProperties.font = .systemFont(ofSize: 16, weight: .semibold)
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }

        dataSource = UICollectionViewDiffableDataSource<Section, Contact>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(
                using: registration,
                for: indexPath,
                item: item
            )
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Contact>()
        snapshot.appendSections([.main])
        snapshot.appendItems(contacts, toSection: .main)
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}

extension ContactsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard indexPath.item < contacts.count else { return }
        let contact = contacts[indexPath.item]
        let chatViewModel = dependencies.makeChatViewModel(contact: contact)
        let chatVC = VoiceChatViewController(viewModel: chatViewModel)
        chatVC.hidesBottomBarWhenPushed = true
        navigationController?.pushViewController(chatVC, animated: true)
    }
}
