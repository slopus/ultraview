#if canImport(UIKit)
import UIKit
import UltraView

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
    private var perfRun: PerfRun?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        // `-perfRun YES` measures a scripted run; `-monitorStalls YES` prints
        // every main-thread stall while you use the app.
        if PerfRun.isRequested || UserDefaults.standard.bool(forKey: "monitorStalls") {
            MainThreadMonitor.shared.onStall = { stall in print("STALL \(stall)") }
            MainThreadMonitor.shared.start(phase: "launch")
        }
        let tabs = UITabBarController()
        tabs.viewControllers = DemoScreen.allCases.map { $0.makeController() }
        tabs.selectedIndex = DemoScreen.allCases.firstIndex(of: DemoScreen.initial) ?? 0
        let window = UIWindow(windowScene: scene)
        window.rootViewController = tabs
        window.makeKeyAndVisible()
        self.window = window

        // Every tab's host fills the same safe area. Once the first one is
        // laid out, the others are prepared at its size, off the main
        // thread, so no tab switch waits for layout or drawing.
        DispatchQueue.main.async {
            guard let shown = tabs.selectedViewController as? NodeScreenController else { return }
            shown.view.layoutIfNeeded()
            let size = shown.host.bounds.size
            for case let controller as NodeScreenController in tabs.viewControllers ?? [] where controller !== shown {
                controller.prepareContent(size: size)
            }
        }

        if PerfRun.isRequested {
            let run = PerfRun(tabs: tabs, window: window)
            perfRun = run
            Task { await run.run() }
        }
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        perfRun?.didEnterForeground()
    }
}
#endif
