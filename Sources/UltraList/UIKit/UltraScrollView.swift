#if canImport(UIKit)
import UIKit

/// A vertical scroll host with a render-server momentum driver by default.
@MainActor
open class UltraScrollView: UIView {
    let engine: any ScrollEngine
    public var contentView: UIView { engine.host }
    public var currentScrollOffset: Double { engine.offset }
    public var isScrollFlightActive: Bool { engine.activeFlight != nil }
    public let engineMode: ScrollEngineMode
    public var onScroll: ((Double) -> Void)?
    public var willBeginDragging: (() -> Void)?
    public var didEndDragging: (() -> Void)?
    public var didEndScrolling: (() -> Void)?
    public var shouldStopScrolling: ((Double) -> Bool)?
    public var contentHeight: Double = 0 { didSet { updateEdges() } }
    public var contentInsets = ListInsets() { didSet { updateEdges() } }
    public init(engineMode: ScrollEngineMode = .keyframe) {
        self.engineMode = engineMode
        engine = engineMode == .uiKit ? PlatformEngine() : PhysicsEngine(mode: engineMode)
        super.init(frame: .zero)
        clipsToBounds = true; addSubview(engine.host)
        engine.onScroll = { [weak self] value in self?.handleScroll(value) }
        engine.willBeginDragging = { [weak self] in self?.handleDragBegin() }
        engine.didEndDragging = { [weak self] in self?.didEndDragging?() }
        engine.didEndScrolling = { [weak self] in self?.didEndScrolling?() }
        engine.shouldStopOnRelease = { [weak self] value in self?.shouldStopScrolling?(value) ?? false }
    }
    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    open override func layoutSubviews() {
        super.layoutSubviews()
        engine.host.frame = bounds
        updateEdges()
    }
    open override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { engine.teardown() }
    }
    open func handleScroll(_ offset: Double) { onScroll?(offset) }
    open func handleDragBegin() { willBeginDragging?() }
    open func updateEdges() {
        engine.setEdges(.init(minimum: -contentInsets.top, maximum: max(-contentInsets.top, contentHeight + contentInsets.bottom - bounds.height)))
    }
    public func setScrollOffset(_ offset: Double) { engine.setOffset(offset) }
    public func haltScrolling() { engine.halt() }
    /// Content-signed points per second; useful when a host transfers momentum from another gesture.
    public func beginMomentum(velocity: Double) { engine.beginMomentum(velocity: velocity) }
}
#endif