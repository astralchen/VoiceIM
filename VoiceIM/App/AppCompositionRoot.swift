import UIKit

@MainActor
enum AppCompositionRoot {
    static func makeRootViewController() -> UIViewController {
        let dependencies = AppDependencies.shared
        let conversationListViewModel = dependencies.makeConversationListViewModel()
        let conversationListVC = ConversationListViewController(
            viewModel: conversationListViewModel,
            dependencies: dependencies
        )
        let conversationNav = UINavigationController(rootViewController: conversationListVC)
        conversationNav.tabBarItem = UITabBarItem(title: "会话", image: UIImage(systemName: "message"), tag: 0)

        let contactsVC = ContactsViewController(dependencies: dependencies)
        let contactsNav = UINavigationController(rootViewController: contactsVC)
        contactsNav.tabBarItem = UITabBarItem(title: "通讯录", image: UIImage(systemName: "person.2"), tag: 1)

        let tabBarController = UITabBarController()
        tabBarController.viewControllers = [conversationNav, contactsNav]
        return tabBarController
    }
}
