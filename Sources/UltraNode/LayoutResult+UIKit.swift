#if canImport(UIKit)
import UIKit
import UltraLayout

extension LayoutResult {
    /// Applies this result to a view hierarchy that mirrors the node tree:
    /// `view` gets `frame`, and its subviews, in order, get `children`.
    /// The only work left for the main thread is assigning frames.
    @MainActor
    public func apply(to view: UIView) {
        view.frame = frame
        let subviews = view.subviews
        precondition(subviews.count == children.count, "view hierarchy does not match the layout tree")
        for (child, subview) in zip(children, subviews) {
            child.apply(to: subview)
        }
    }
}
#endif
