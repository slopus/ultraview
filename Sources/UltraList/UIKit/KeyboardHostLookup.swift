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

    /// The host's frame in `window`. The host's window belongs to the
    /// keyboard's own scene. Converting straight between windows of two
    /// scenes returns a null rectangle on iOS 27, and converting through the
    /// screen's coordinate space takes UIKit's slow invalid-conversion path,
    /// so this offsets by both windows' screen frames.
    static func frame(of host: Host, in window: UIWindow) -> CGRect {
        transfer(host.view.convert(host.view.bounds, to: host.window), from: host.window, to: window)
    }

    /// `rect` in `source`'s coordinates, in `window`'s. Both windows are
    /// untransformed and on one screen.
    static func transfer(_ rect: CGRect, from source: UIWindow, to window: UIWindow) -> CGRect {
        guard source !== window else { return rect }
        return rect.offsetBy(dx: source.frame.minX - window.frame.minX, dy: source.frame.minY - window.frame.minY)
    }

    private static func matches(_ view: UIView, suffixes: [String]) -> Bool {
        let name = NSStringFromClass(type(of: view))
        return name.hasPrefix("UI") && suffixes.contains(where: name.hasSuffix)
    }
}
#endif