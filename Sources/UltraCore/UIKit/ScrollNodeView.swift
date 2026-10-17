#if canImport(UIKit)
import UIKit
import UltraLayout

/// The `UIScrollView` behind an `UltraScrollNode`. It reports its offset to
/// the pipeline, which moves the preload and display ranges, and calls
/// `onScroll`.
final class ScrollNodeView: UIScrollView, UIScrollViewDelegate {
    weak var node: UltraScrollNode?
    var props: ViewProps?
    private var reportedOffset: CGPoint?

    /// The fraction of a viewport the content may move before the pipeline
    /// recomputes ranges. Ranges extend whole viewports ahead, so this is
    /// well inside them.
    static let reportStep: CGFloat = 0.25

    init(node: UltraScrollNode) {
        self.node = node
        super.init(frame: .zero)
        delegate = self
        contentInsetAdjustmentBehavior = .never
        delaysContentTouches = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(_ scroll: ScrollViewProps) {
        if contentSize != scroll.contentSize {
            contentSize = scroll.contentSize
        }
        let inset = UIEdgeInsets(
            top: scroll.contentInset.top,
            left: scroll.contentInset.left,
            bottom: scroll.contentInset.bottom,
            right: scroll.contentInset.right
        )
        if contentInset != inset {
            contentInset = inset
        }
        showsVerticalScrollIndicator = scroll.showsVerticalScrollIndicator
        showsHorizontalScrollIndicator = scroll.showsHorizontalScrollIndicator
        isPagingEnabled = scroll.pagingEnabled
        bounces = scroll.bounces
        alwaysBounceVertical = scroll.bounces && !scroll.horizontal
        alwaysBounceHorizontal = scroll.bounces && scroll.horizontal
        isScrollEnabled = scroll.scrollEnabled
        keyboardDismissMode = switch scroll.keyboardDismissMode {
        case .none: .none
        case .onDrag: .onDrag
        case .interactive: .interactive
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        NodeHitTesting.point(point, isInside: self, props: props)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        NodeHitTesting.hitTest(point, in: self, props: props) { super.hitTest(point, with: event) }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard let node else { return }
        reportOffsetIfNeeded(force: false)
        node.onScroll?(node.scrollEvent(for: self))
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        reportOffsetIfNeeded(force: true)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            reportOffsetIfNeeded(force: true)
        }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        reportOffsetIfNeeded(force: true)
    }

    private func reportOffsetIfNeeded(force: Bool) {
        let offset = contentOffset
        let horizontal = props?.scroll?.horizontal ?? false
        if !force, let reported = reportedOffset {
            let moved = horizontal ? abs(offset.x - reported.x) : abs(offset.y - reported.y)
            let length = horizontal ? bounds.width : bounds.height
            guard moved >= length * Self.reportStep else { return }
        }
        guard offset != reportedOffset else { return }
        reportedOffset = offset
        node?.reportContentOffset(offset)
    }
}
#endif
