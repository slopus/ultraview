#if canImport(UIKit)
import UIKit

/// The demo's entry point. It lives in a library target because xtool builds
/// the app from the `UltraViewDemo` product; the XcodeGen app target compiles
/// this same directory.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let tabs = UITabBarController()
        tabs.viewControllers = DemoScreen.allCases.map { $0.makeController() }
        tabs.selectedIndex = DemoScreen.allCases.firstIndex(of: DemoScreen.initial) ?? 0
        let window = UIWindow(windowScene: scene)
        window.rootViewController = tabs
        window.makeKeyAndVisible()
        self.window = window
    }
}
#endif
