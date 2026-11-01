#if canImport(UIKit)
import UIKit
import UltraCore

/// Content retained by one list together with its measured height.
@MainActor
public protocol ListPreparedContent: AnyObject, Sendable {
    var hasLiveHost: Bool { get }
    /// The list will show the row soon, though it was prepared without
    /// `ListPreparationHint.showsSoon`: content not drawn yet starts drawing.
    /// Returns what finishes once it is drawn, or `nil` when nothing draws.
    func drawAhead() -> Task<Void, Never>?
}
public extension ListPreparedContent {
    var hasLiveHost: Bool { false }
    func drawAhead() -> Task<Void, Never>? { nil }
}

/// Content whose measured size can survive the host that drew it.
@MainActor
protocol DisplayPreparedContent: ListPreparedContent {
    var isDisplayPrepared: Bool { get }
    /// Draws with the pass queued at once, for a list that waits for the
    /// pipeline (`NodeHostView.waitForPipeline(until:)`) and then calls
    /// `applyDrawn()`.
    func drawNow()
    /// Shows what was drawn for an in-place preparation now, in full,
    /// rather than on later main-queue turns.
    func applyDrawn()
}
extension DisplayPreparedContent {
    func drawNow() {}
    func applyDrawn() {}
}

/// What the list tells a row's `prepare` about the preparation, through
/// task-local values.
public enum ListPreparationHint {
    /// Whether the list will show the row as soon as this preparation is
    /// ready: an insert, a row a scroll brings near the screen, a row a pass
    /// needs. A row can draw its content ahead then, so it first appears
    /// drawn, in the transaction that places it.
    @TaskLocal public static var showsSoon = false
}

public struct ListPreparation: Sendable {
    public var height: Double
    public var content: (any ListPreparedContent)?
    /// Whether the row has this height at every width, as `ListRow.hasFixedHeight`
    /// says, learned while preparing: a node row's root with a height in points.
    public var hasFixedHeight: Bool
    public init(height: Double, content: (any ListPreparedContent)? = nil, hasFixedHeight: Bool = false) {
        self.height = height; self.content = content; self.hasFixedHeight = hasFixedHeight
    }
}

/// What a list's width change did (`UltraListView.lastResize`).
public struct ListResizeReport: Sendable, Equatable {
    /// The new width of the rows.
    public var width: Double
    /// Main-thread milliseconds from the change to its applied pass,
    /// waiting included.
    public var milliseconds: Double
    /// Of those, milliseconds spent waiting for rows off the main thread.
    public var waitedMilliseconds: Double
    /// Of `milliseconds`, the main thread's own CPU time. Far below the wall
    /// time, outside the wait, the thread was waiting for a CPU.
    public var cpuMilliseconds: Double
    /// Of those, milliseconds spent showing what was drawn, and in the pass
    /// that lays the rows out at the new width.
    public var applyingMilliseconds: Double
    public var passMilliseconds: Double
    /// Rows measured at the new width while the list waited.
    public var preparedRows: Int
    /// Rows not measured or drawn in time, shown with their old content
    /// until they are.
    public var lateRows: Int
    /// Rows on screen that can't prepare in place, shown with their old
    /// content and height until measured.
    public var keptRows: Int
    /// Loaded rows with a fixed height, which kept their places without a
    /// new measurement.
    public var fixedRows: Int
    /// Whether the rows followed an animation of the change.
    public var animated: Bool
}

/// A row's preparation at a new width that runs off the main thread while
/// the list waits for it on the main thread, when the list's width changes
/// (see `ListRow.prepareInPlace`).
@MainActor
public final class ListInPlacePreparation {
    private let waitForHeight: @Sendable (DispatchTime) -> Bool
    private let complete: @MainActor () -> ListPreparation?
    /// `wait` blocks until the row's height is known or the deadline passes,
    /// and returns whether it is known. It is called on the main thread, so
    /// the work it waits for must not need the main thread. `finish` runs
    /// on the main thread once `wait` returned `true` and returns the
    /// preparation, with its content drawing or drawn at that height.
    public init(wait: @escaping @Sendable (DispatchTime) -> Bool, finish: @escaping @MainActor () -> ListPreparation?) {
        waitForHeight = wait; complete = finish
    }
    func wait(until deadline: DispatchTime) -> Bool { waitForHeight(deadline) }
    func finish() -> ListPreparation? { complete() }
}

/// Stable identity and content equality are separate: changed content reuses its row view.
@MainActor
public protocol ListRow {
    var identity: String { get }
    var revision: UInt64 { get }
    var pinsToBottomEdge: Bool { get }
    var attachments: [String: any ListAttachment] { get }
    var measuresAsynchronously: Bool { get }
    var measurementEnvironment: UInt64 { get }
    func makeView() -> ListRowView
    func apply(to view: ListRowView, transition: ListTransition)
    func isEqual(to other: any ListRow) -> Bool
    func measure(width: Double, environment: RenderEnvironment) async -> Double?
    func prepare(width: Double, environment: RenderEnvironment) async -> ListPreparation?
    /// Whether the row's height is the same at every width. When the list's
    /// width changes, such a row keeps its place and height, with no new
    /// measurement to wait for; only its content is drawn again at the new
    /// width. A preparation can also report it (`ListPreparation.hasFixedHeight`),
    /// as a node row whose root has a height in points does.
    var hasFixedHeight: Bool { get }
    /// Starts preparing the row at `width` for a list whose width changed,
    /// which waits for it on the main thread (with a time limit) so the row
    /// shows at the new width in the same frame as the change. The work must
    /// run off the main thread and must not need it. `nil`, the default,
    /// leaves the row showing its old content until `prepare` finishes.
    /// `NodeRow` implements it; a row that wraps one can return the node
    /// row's.
    func prepareInPlace(width: Double, environment: RenderEnvironment) -> ListInPlacePreparation?
    var leadingSwipeActions: [ListSwipeAction] { get }
    var trailingSwipeActions: [ListSwipeAction] { get }
}
public extension ListRow {
    var revision: UInt64 { 0 }
    var pinsToBottomEdge: Bool { false }
    var attachments: [String: any ListAttachment] { [:] }
    var measuresAsynchronously: Bool { false }
    var measurementEnvironment: UInt64 { 0 }
    func apply(to view: ListRowView, transition: ListTransition) {}
    func isEqual(to other: any ListRow) -> Bool { identity == other.identity && revision == other.revision }
    func measure(width: Double, environment: RenderEnvironment) async -> Double? { nil }
    func prepare(width: Double, environment: RenderEnvironment) async -> ListPreparation? {
        await measure(width: width, environment: environment).map { ListPreparation(height: $0) }
    }
    var hasFixedHeight: Bool { false }
    func prepareInPlace(width: Double, environment: RenderEnvironment) -> ListInPlacePreparation? { nil }
    var leadingSwipeActions: [ListSwipeAction] { [] }
    var trailingSwipeActions: [ListSwipeAction] { [] }
}

@MainActor
open class ListRowView: UIView {
    public var onContentDidChange: ((Bool) -> Void)?
    public var onDisplayReady: (() -> Void)?
    var readinessObserver: (() -> Void)?
    var displayWaitObserver: (() -> Void)?
    /// Call after an asynchronous row's visible content becomes ready.
    public func reportDisplayReady() { readinessObserver?(); displayWaitObserver?(); onDisplayReady?() }
    open var isDisplayReady: Bool { true }
    public override init(frame: CGRect) { super.init(frame: frame); layer.anchorPoint = .zero }
    public convenience init() { self.init(frame: .zero) }
    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    /// Plain view rows implement their sizing here. Node rows use a ready measurement instead.
    open func update(width: Double, transition: ListTransition) -> Double { bounds.height }
    /// An asynchronous row receives its ready size before it enters the view hierarchy.
    open func applyMeasurement(width: Double, height: Double, environment: RenderEnvironment) {}
    open func applyPreparation(_ preparation: ListPreparation, width: Double, environment: RenderEnvironment) {
        applyMeasurement(width: width, height: preparation.height, environment: environment)
    }
    open func visibleRectUpdated(_ rect: CGRect?) {}
    open func attachedViewsUpdated(_ views: [UIView]) {}
    open var attachmentBandTrim: Double { 0 }
    /// Places the transformed bounding rectangle without asking UIKit to infer bounds from a frame.
    func place(in frame: CGRect) {
        bounds = .init(origin: .zero, size: frame.size)
        let offset = placementOffset(size: frame.size)
        layer.position = .init(x: frame.minX + offset.x, y: frame.minY + offset.y)
    }
    func placementOffset(size: CGSize) -> CGPoint {
        let relative = CGRect(x: -layer.anchorPoint.x * size.width, y: -layer.anchorPoint.y * size.height, width: size.width, height: size.height).applying(transform)
        return .init(x: -relative.minX, y: -relative.minY)
    }
}

@MainActor
public protocol ListAttachment {
    var edge: BoundaryEdge { get }
    var reservesSpace: Bool { get }
    var floating: Bool { get }
    var spansMemberInsets: Bool { get }
    var stackingGroup: String? { get }
    var yieldsTo: String? { get }
    var yieldGap: Double { get }
    func makeView() -> ListAttachmentView
    func apply(to view: ListAttachmentView, transition: ListTransition)
    func combines(with other: any ListAttachment) -> Bool
}
public extension ListAttachment {
    var reservesSpace: Bool { false }
    var floating: Bool { true }
    var spansMemberInsets: Bool { true }
    var stackingGroup: String? { nil }
    var yieldsTo: String? { nil }
    var yieldGap: Double { 0 }
    func apply(to view: ListAttachmentView, transition: ListTransition) {}
    func combines(with other: any ListAttachment) -> Bool { true }
}
@MainActor
open class ListAttachmentView: ListRowView {
    open func stickDistanceUpdated(_ distance: Double) {}
}

public enum ListAnchorMode: Sendable { case automatic, preserveVisibleContent }

@MainActor
public struct ListScrollTarget {
    public var index: Int
    /// A row to follow across later collection changes. Without an identity,
    /// a standalone target keeps its numeric index.
    /// An identity target's resolver must depend only on its height. It
    /// receives a nil view and may be evaluated more than once during
    /// preparation. The selected result is reused when that preparation applies.
    /// Collection changes can wait for that destination to draw. Keep separate
    /// scroll-distance changes out of that wait; accumulated relative distance
    /// uses the ordinary retry path instead.
    public var identity: String?
    public var forward: Bool?
    public var resolve: (Double, ListRowView?) -> Double
    enum Edge { case first, last }
    /// A target at the first or last row goes to the row there when it
    /// applies, which may not be the one there when it was asked for.
    var edge: Edge?
    public init(index: Int, identity: String? = nil, forward: Bool? = nil, resolve: @escaping (Double, ListRowView?) -> Double) {
        self.index = index; self.identity = identity; self.forward = forward; self.resolve = resolve
    }
    public init(index: Int, identity: String? = nil, pointOffset: Double = 0, forward: Bool? = nil) {
        self.init(index: index, identity: identity, forward: forward, resolve: { _, _ in pointOffset })
    }
}

@MainActor
final class PassthroughView: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        subviews.contains { !$0.isHidden && $0.isUserInteractionEnabled && $0.alpha > 0.01 && $0.hitTest(convert(point, to: $0), with: event) != nil }
    }
}
#endif