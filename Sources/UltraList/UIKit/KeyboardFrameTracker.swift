#if canImport(UIKit)
import UIKit

/// The keyboard's last announced frame, from its public notifications. One
/// observer serves every scroller. It starts with the first scroller, so a
/// keyboard shown before then is unknown until it next changes. A keyboard
/// announced as leaving the screen keeps its last frame until it has
/// hidden, so the system's interactive dismissal finishes with its input in
/// place.
@MainActor
final class KeyboardFrameTracker {
    static let shared = KeyboardFrameTracker()
    /// The announced end frame in screen coordinates, nil once hidden.
    private(set) var screenFrame: CGRect?
    private let scrollViews = NSHashTable<UltraScrollView>.weakObjects()
    private var observers: [any NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { notification in
            let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            let screen = (notification.object as? UIScreen)?.bounds
            MainActor.assumeIsolated {
                if let frame, let screen, !frame.intersects(screen) { return }
                KeyboardFrameTracker.shared.update(frame)
            }
        })
        observers.append(center.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { KeyboardFrameTracker.shared.update(nil) }
        })
    }

    /// `scrollView` hears every change until it is released or removed.
    func add(_ scrollView: UltraScrollView) { scrollViews.add(scrollView) }
    func remove(_ scrollView: UltraScrollView) { scrollViews.remove(scrollView) }

    private func update(_ frame: CGRect?) {
        screenFrame = frame
        for scrollView in scrollViews.allObjects { scrollView.keyboardFrameChanged() }
    }

    /// The docked keyboard's top edge in `window`'s coordinates.
    func dockedTop(in window: UIWindow) -> Double? {
        let frame = screenFrame.map { frame in
            window.windowScene.map { window.convert(frame, from: $0.screen.coordinateSpace) }
                ?? frame.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
        }
        let bounds = window.bounds
        return KeyboardInputPolicy.dockedTop(
            keyboard: frame.map { .init(minX: $0.minX, minY: $0.minY, maxX: $0.maxX, maxY: $0.maxY) },
            window: .init(minX: bounds.minX, minY: bounds.minY, maxX: bounds.maxX, maxY: bounds.maxY))
    }
}
#endif
