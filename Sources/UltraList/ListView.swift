#if canImport(UIKit)
import UIKit

/// Placeholder for the list view. It will scroll by itself, with its own pan
/// handling, deceleration, rubber-banding and indicators, and position item
/// nodes directly instead of hosting them in a `UIScrollView`.
@MainActor
open class ListView: UIView {
    public private(set) var geometry = ListGeometry(itemExtents: [])

    public func setGeometry(_ geometry: ListGeometry) {
        self.geometry = geometry
        setNeedsLayout()
    }
}
#endif
