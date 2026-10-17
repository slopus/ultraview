import Foundation
import UltraLayout
#if canImport(UIKit)
import UIKit
#endif

/// What `onScroll` reports.
public struct ScrollEvent: Sendable, Equatable {
    public var contentOffset: CGPoint
    public var contentSize: CGSize
    /// The size of the scroll view itself.
    public var layoutMeasurement: CGSize
    public var contentInset: Insets
}

public typealias ScrollHandler = @MainActor @Sendable (ScrollEvent) -> Void

struct ScrollConfiguration: Sendable {
    var horizontal = false
    var contentInset = Insets.zero
    var showsVerticalScrollIndicator = true
    var showsHorizontalScrollIndicator = true
    var pagingEnabled = false
    var bounces = true
    var scrollEnabled = true
    var keyboardDismissMode: KeyboardDismissMode = .none
    var rangeTuning = RangeTuning.default
    /// The offset last reported by the view.
    var contentOffset = CGPoint.zero
    var onScroll: ScrollHandler?
}

/// A scrolling container, the counterpart of a `ScrollView`: a real
/// `UIScrollView` whose content is laid out by Yoga with no limit along the
/// scroll axis.
///
/// Children go into a content container styled by `contentContainerStyle`.
/// Only children near the viewport get views and bitmaps: those within
/// `rangeTuning.preloadScreens` viewport lengths are mounted, and those
/// within `rangeTuning.displayScreens` are drawn, off the main thread and
/// ahead of scrolling. Children further away give up their bitmaps and
/// views, so a long feed costs little until it is scrolled.
public final class UltraScrollNode: UltraNode, @unchecked Sendable {
    // @unchecked Sendable: as `UltraNode`; the scroll configuration lives in
    // the locked state, and `pendingContentOffset` is main-thread only.

    let contentNode: ScrollContentNode

    #if canImport(UIKit)
    /// A `scrollTo` made before the view existed.
    @MainActor var pendingContentOffset: (offset: CGPoint, animated: Bool)?
    #endif

    public init(
        style: Style = Style(),
        contentContainerStyle: Style = Style(),
        horizontal: Bool = false,
        children: [UltraNode] = []
    ) {
        contentNode = ScrollContentNode(style: contentContainerStyle)
        super.init(style: style)
        var configuration = ScrollConfiguration()
        configuration.horizontal = horizontal
        state.withLock { $0.scroll = configuration }
        contentNode.state.withLock { $0.isHorizontalContent = horizontal }
        setChildNodes([contentNode])
        if !children.isEmpty {
            contentNode.setChildren(children)
        }
    }

    // MARK: Children go into the content container

    public override var children: [UltraNode] {
        contentNode.children
    }

    public override func addChild(_ child: UltraNode) {
        contentNode.addChild(child)
    }

    public override func insertChild(_ child: UltraNode, at index: Int) {
        contentNode.insertChild(child, at: index)
    }

    public override func removeChild(_ child: UltraNode) {
        contentNode.removeChild(child)
    }

    public override func setChildren(_ children: [UltraNode]) {
        contentNode.setChildren(children)
    }

    // MARK: Configuration

    /// The style of the container the children are laid out in. Its
    /// `flexGrow` lets short content fill the scroll view.
    public var contentContainerStyle: Style {
        get { contentNode.style }
        set { contentNode.style = newValue }
    }

    /// Scrolls sideways and lays the children out in a row.
    public var horizontal: Bool {
        get { configuration.horizontal }
        set {
            updateConfiguration { $0.horizontal = newValue }
            contentNode.state.withLock { $0.isHorizontalContent = newValue }
            contentNode.setNeedsSync()
        }
    }

    public var contentInset: Insets {
        get { configuration.contentInset }
        set { updateConfiguration { $0.contentInset = newValue } }
    }

    public var showsVerticalScrollIndicator: Bool {
        get { configuration.showsVerticalScrollIndicator }
        set { updateConfiguration { $0.showsVerticalScrollIndicator = newValue } }
    }

    public var showsHorizontalScrollIndicator: Bool {
        get { configuration.showsHorizontalScrollIndicator }
        set { updateConfiguration { $0.showsHorizontalScrollIndicator = newValue } }
    }

    /// Stops on multiples of the scroll view's size.
    public var pagingEnabled: Bool {
        get { configuration.pagingEnabled }
        set { updateConfiguration { $0.pagingEnabled = newValue } }
    }

    public var bounces: Bool {
        get { configuration.bounces }
        set { updateConfiguration { $0.bounces = newValue } }
    }

    public var scrollEnabled: Bool {
        get { configuration.scrollEnabled }
        set { updateConfiguration { $0.scrollEnabled = newValue } }
    }

    public var keyboardDismissMode: KeyboardDismissMode {
        get { configuration.keyboardDismissMode }
        set { updateConfiguration { $0.keyboardDismissMode = newValue } }
    }

    /// How far ahead of the viewport children are mounted and drawn.
    public var rangeTuning: RangeTuning {
        get { configuration.rangeTuning }
        set { updateConfiguration { $0.rangeTuning = newValue } }
    }

    /// Called on the main thread on every scroll.
    public var onScroll: ScrollHandler? {
        get { configuration.onScroll }
        set { state.withLock { $0.scroll?.onScroll = newValue } }
    }

    private var configuration: ScrollConfiguration {
        state.withLock { $0.scroll ?? ScrollConfiguration() }
    }

    private func updateConfiguration(_ body: (inout ScrollConfiguration) -> Void) {
        state.withLock { state in
            var configuration = state.scroll ?? ScrollConfiguration()
            body(&configuration)
            state.scroll = configuration
        }
        setNeedsSync()
    }

    /// Tells the pipeline where the viewport is, so it can move the ranges.
    /// The view calls it as it scrolls.
    func reportContentOffset(_ offset: CGPoint) {
        let changed = state.withLock { state -> Bool in
            guard state.scroll?.contentOffset != offset else { return false }
            state.scroll?.contentOffset = offset
            return true
        }
        if changed {
            setNeedsSync()
        }
    }

    // MARK: Pipeline (layout queue)

    override func effectiveLayoutStyle(_ state: NodeState) -> LayoutStyle {
        var layout = state.style.layout
        // Yoga measures the children of a scrolling node without a limit
        // along its main axis.
        layout.overflow = .scroll
        layout.flexDirection = state.scroll?.horizontal == true ? .row : .column
        return layout
    }

    override func syncContent(previous: NodeState?, current: NodeState, pass: Pass) {
        shadow.contentOffset = current.scroll?.contentOffset ?? .zero
        pass.needsRangeUpdate(self)
    }

    override func contributeProps(_ props: inout ViewProps, state: NodeState, pass: Pass) {
        let configuration = state.scroll ?? ScrollConfiguration()
        let content = contentNode.shadow.frame
        props.clipsToBounds = true
        props.scroll = ScrollViewProps(
            contentSize: CGSize(width: max(0, content.maxX), height: max(0, content.maxY)),
            contentInset: configuration.contentInset,
            horizontal: configuration.horizontal,
            showsVerticalScrollIndicator: configuration.showsVerticalScrollIndicator,
            showsHorizontalScrollIndicator: configuration.showsHorizontalScrollIndicator,
            pagingEnabled: configuration.pagingEnabled,
            bounces: configuration.bounces,
            scrollEnabled: configuration.scrollEnabled,
            keyboardDismissMode: configuration.keyboardDismissMode
        )
    }

    // MARK: Scrolling (main thread)

    #if canImport(UIKit)
    @MainActor override func makeView() -> UIView {
        ScrollNodeView(node: self)
    }

    @MainActor override func didApply(_ entry: CommitEntry) {
        if let pending = pendingContentOffset, let view = mountedView as? UIScrollView, entry.props?.scroll != nil {
            pendingContentOffset = nil
            view.setContentOffset(pending.offset, animated: pending.animated)
        }
    }

    /// Scrolls so the content's point (`x`, `y`) is at the top-left of the
    /// scroll view. Before the view exists, the offset is kept for it.
    @MainActor public func scrollTo(x: CGFloat = 0, y: CGFloat = 0, animated: Bool = true) {
        let offset = CGPoint(x: x, y: y)
        if let view = mountedView as? UIScrollView {
            view.setContentOffset(offset, animated: animated)
        } else {
            pendingContentOffset = (offset, animated)
            reportContentOffset(offset)
        }
    }

    /// Scrolls to the bottom, or to the right end when horizontal.
    @MainActor public func scrollToEnd(animated: Bool = true) {
        guard let view = mountedView as? UIScrollView else { return }
        let inset = view.adjustedContentInset
        let offset = horizontal
            ? CGPoint(x: max(-inset.left, view.contentSize.width + inset.right - view.bounds.width), y: view.contentOffset.y)
            : CGPoint(x: view.contentOffset.x, y: max(-inset.top, view.contentSize.height + inset.bottom - view.bounds.height))
        view.setContentOffset(offset, animated: animated)
    }

    @MainActor func scrollEvent(for view: UIScrollView) -> ScrollEvent {
        ScrollEvent(
            contentOffset: view.contentOffset,
            contentSize: view.contentSize,
            layoutMeasurement: view.bounds.size,
            contentInset: Insets(
                top: view.contentInset.top,
                left: view.contentInset.left,
                bottom: view.contentInset.bottom,
                right: view.contentInset.right
            )
        )
    }
    #endif
}

/// The container inside a scroll node that holds its children.
final class ScrollContentNode: UltraNode, @unchecked Sendable {
    // @unchecked Sendable: as `UltraNode`.

    override func effectiveLayoutStyle(_ state: NodeState) -> LayoutStyle {
        var layout = state.style.layout
        if state.isHorizontalContent {
            layout.flexDirection = .row
        }
        return layout
    }
}
