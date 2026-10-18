#if canImport(UIKit)
import UIKit

/// Optional private hierarchy access. Every failure leaves dismissal to UIKit.
/// These selectors and class suffixes can change between operating-system releases.
@MainActor
enum KeyboardHostLookup {
    struct Host {
        let window: UIWindow
        let view: UIView
    }

    static func find(in scene: UIWindowScene?) -> Host? {
        guard UIDevice.current.userInterfaceIdiom == .phone, let scene else { return nil }
        let delegateSelector = NSSelectorFromString("keyboardSceneDelegate")
        let windowSelector = NSSelectorFromString("keyboardWindow")
        guard scene.responds(to: delegateSelector),
              let delegate = scene.perform(delegateSelector)?.takeUnretainedValue() as? NSObject,
              delegate.responds(to: windowSelector),
              let window = delegate.perform(windowSelector)?.takeUnretainedValue() as? UIWindow,
              !window.isHidden, window.alpha > 0 else { return nil }
        for container in window.subviews where matches(container, suffixes: ["InputSetContainerView", "TrackingWindowView"]) {
            for view in container.subviews where matches(view, suffixes: ["InputSetHostView", "KeyboardItemContainerView"]) {
                guard !container.isHidden, container.alpha > 0, !view.isHidden, view.alpha > 0,
                      view.window === window, view.bounds.height > 0 else { continue }
                return Host(window: window, view: view)
            }
        }
        return nil
    }

    private static func matches(_ view: UIView, suffixes: [String]) -> Bool {
        let name = NSStringFromClass(type(of: view))
        return name.hasPrefix("UI") && suffixes.contains(where: name.hasSuffix)
    }
}
#endif