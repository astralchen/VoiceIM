import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        window = UIWindow(windowScene: windowScene)

        // 使用依赖注入创建 ViewController
        let chatVC = VoiceChatViewController(
            player: VoicePlaybackManager.shared
        )

        window?.rootViewController = UINavigationController(
            rootViewController: chatVC
        )
        window?.makeKeyAndVisible()
    }
}
