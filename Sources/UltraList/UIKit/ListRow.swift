#if canImport(UIKit)
import UIKit
import UltraCore

/// Content retained by one list together with its measured height.
@MainActor
public protocol ListPreparedContent: AnyObject, Sendable {
    var hasLiveHost: Bool { get }
}
public extension ListPreparedContent { var hasLiveHost: Bool { false } }

public struct ListPreparation: Sendable {
    public var height: Double
    public var content: (any ListPreparedContent)?
    public init(height: Double, content: (any ListPreparedContent)? = nil) {
        self.height = height; self.content = content
    }
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
}

@MainActor
open class ListRowView: UIView {
    public var onContentDidChange: ((Bool) -> Void)?
    public var onDisplayReady: (() -> Void)?
    var readinessObserver: (() -> Void)?
    /// Call after an asynchronous row's visible content becomes ready.
    public func reportDisplayReady() { readinessObserver?(); onDisplayReady?() }
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
    public var forward: Bool?
    public var resolve: (Double, ListRowView?) -> Double
    public init(index: Int, forward: Bool? = nil, resolve: @escaping (Double, ListRowView?) -> Double) {
        self.index = index; self.forward = forward; self.resolve = resolve
    }
    public init(index: Int, pointOffset: Double = 0, forward: Bool? = nil) {
        self.init(index: index, forward: forward, resolve: { _, _ in pointOffset })
    }
}

@MainActor
final class PassthroughView: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        subviews.contains { !$0.isHidden && $0.isUserInteractionEnabled && $0.alpha > 0.01 && $0.hitTest(convert(point, to: $0), with: event) != nil }
    }
}
#endif