#if canImport(UIKit)
import UIKit

/// Receives the status bar's scroll-to-top tap for a scroll host whose engine
/// may have no system scroll view of its own. UIKit offers the tap to this
/// empty scroll view, which hands it to its host and never moves itself.
@MainActor
final class ScrollToTopProxy: UIScrollView, UIScrollViewDelegate {
    weak var owner: UltraScrollView?

    init(owner: UltraScrollView) {
        self.owner = owner
        super.init(frame: .zero)
        delegate = self
        contentInsetAdjustmentBehavior = .never
        // Far from its own top, so UIKit always has something to offer it.
        contentSize = .init(width: 1, height: 10_000_000)
        contentOffset.y = 5_000_000
        showsVerticalScrollIndicator = false; showsHorizontalScrollIndicator = false
        isAccessibilityElement = false; accessibilityElementsHidden = true
        scrollsToTop = false
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // UIKit skips scroll views that don't take touches, so this one takes
    // them but is never under one.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        owner?.statusBarTapped()
        return false
    }
}

/// Decides which scroll host in a window answers the status bar. UIKit
/// expects at most one scroll view there to accept the tap, so of the hosts
/// that allow it, are shown and sit inside no other host, the largest one
/// does.
@MainActor
enum ScrollToTopClaims {
    private static let hosts = NSHashTable<UltraScrollView>.weakObjects()

    static func register(_ host: UltraScrollView) { hosts.add(host) }

    static func update(in window: UIWindow?) {
        guard let window else { return }
        let present = hosts.allObjects.filter { $0.window === window }
        var winner: UltraScrollView?
        for host in present where eligible(host) {
            if let current = winner, area(current) >= area(host) { continue }
            winner = host
        }
        for host in present { host.claimScrollToTop(host === winner) }
    }

    private static func eligible(_ host: UltraScrollView) -> Bool {
        guard host.scrollsToTop, !host.isHidden, host.alpha > 0.01, host.bounds.width > 0, host.bounds.height > 0 else { return false }
        var ancestor = host.superview
        while let view = ancestor {
            if view is UltraScrollView || view.isHidden { return false }
            ancestor = view.superview
        }
        return true
    }

    private static func area(_ host: UltraScrollView) -> Double { Double(host.bounds.width * host.bounds.height) }
}
#endif
