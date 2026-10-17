#if canImport(UIKit)
import UIKit
import UltraCore

/// A list that scrolls left and right. It shows an ordinary `UltraListView`
/// whose vertical axis runs along the screen's x axis: transposed left to
/// right, or turned a quarter clockwise right to left. The list keeps its own
/// windowing, diffing, transitions and engines.
///
/// Give `list` rows wrapped in `HorizontalRow`. The list's geometry is in its
/// own space: its top and bottom insets are the leading and trailing ones, and
/// its left and right insets are the top and bottom. `screenFrame(_:)` maps
/// the list's frames to this view.
@MainActor
public final class HorizontalListView: UIView, UIGestureRecognizerDelegate {
    public let list: UltraListView
    /// Recognizes a vertical motion, so that the list's pan fails for it.
    private let crossGate = AxisGate(claims: .vertical)
    /// Recognizes a horizontal motion, so that enclosing pans fail for it.
    private let mainGate = AxisGate(claims: .horizontal)
    private var rightToLeft: Bool { effectiveUserInterfaceLayoutDirection == .rightToLeft }

    public init(engineMode: ScrollEngineMode = .keyframe) {
        list = UltraListView(engineMode: engineMode)
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(list)
        crossGate.guarded = list; mainGate.guarded = list
        crossGate.delegate = self; mainGate.delegate = self
        addGestureRecognizer(crossGate); addGestureRecognizer(mainGate)
        listPan?.require(toFail: crossGate)
        crossGate.onClaim = { [weak self] in self?.cancelListPan() }
        list.horizontalAccessibilityScroll = { [weak self] direction in self?.mapped(direction) }
    }
    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private var listPan: UIPanGestureRecognizer? {
        (list.engine as? PhysicsEngine)?.pan ?? (list.engine as? PlatformEngine)?.scroll.panGestureRecognizer
    }

    /// A list pan that began in the gate's deciding event still waits on the
    /// gate, and while it waits it fails the enclosing pans. Cancelling it
    /// before UIKit resolves the event leaves the vertical drag to them.
    private func cancelListPan() {
        guard let pan = listPan, pan.isEnabled else { return }
        pan.isEnabled = false; pan.isEnabled = true
    }

    /// Hit testing precedes every recognizer's view of a touch, so motion is
    /// recorded here before a catching touch stops it.
    public override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let event, event.type == .touches {
            let moving = AxisGate.Motion(time: event.timestamp, list: AxisGate.isMoving(list), ancestor: AxisGate.ancestorIsMoving(of: self))
            crossGate.motion = moving; mainGate.motion = moving
        }
        return super.hitTest(point, with: event)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        // A quarter turn clockwise, or a transpose; both exact.
        list.transform = rightToLeft ? .init(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0) : .init(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        list.bounds = .init(x: 0, y: 0, width: size.height, height: size.width)
        list.center = .init(x: bounds.midX, y: bounds.midY)
    }
    /// A frame from `list` (`settledFrame`, `presentedFrame`) in this view's coordinates.
    public func screenFrame(_ listFrame: CGRect) -> CGRect {
        let rect = HorizontalListGeometry.screenRect(x: listFrame.minX, y: listFrame.minY, width: listFrame.width, height: listFrame.height, length: bounds.width, rightToLeft: rightToLeft)
        return .init(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    /// VoiceOver's horizontal scrolls page the list; vertical ones belong to an enclosing scroller.
    private func mapped(_ direction: UIAccessibilityScrollDirection) -> UIAccessibilityScrollDirection? {
        switch direction {
        case .right: rightToLeft ? .up : .down
        case .left: rightToLeft ? .down : .up
        case .next: .down
        case .previous: .up
        default: nil
        }
    }

    /// A gate stays out of a touch that catches moving content, so the
    /// catching pan isn't left waiting for it.
    public func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        (recognizer as? AxisGate)?.landsOnMotion(at: touch.timestamp) != true
    }
    public func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    public func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        // Enclosing scrollers wait until the motion is known not to be horizontal.
        guard recognizer === mainGate, other is UIPanGestureRecognizer, !(other is UIScreenEdgePanGestureRecognizer),
              let view = other.view, view !== list.contentView, !view.isDescendant(of: self) else { return false }
        return isDescendant(of: view)
    }
}

/// Decides a gesture's axis once and recognizes when it is `claims`. It never
/// takes touches from views; other recognizers depend on it to fail.
@MainActor
final class AxisGate: UIGestureRecognizer {
    let claims: GestureAxis
    weak var guarded: UltraListView?
    struct Motion { var time: Double; var list: Bool; var ancestor: Bool }
    /// Motion when the touch was hit-tested, before any recognizer caught it.
    var motion: Motion?
    /// Runs when the gate decides on `claims`, before it recognizes.
    var onClaim: (() -> Void)?
    private var lock = AxisLock()
    private var start = CGPoint.zero
    init(claims: GestureAxis) {
        self.claims = claims
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
    }
    override func reset() { super.reset(); lock = AxisLock() }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let view, let touch = touches.first, event.allTouches?.count ?? 1 == 1, !landsOnMotion(at: event.timestamp) else { state = .failed; return }
        start = touch.location(in: view)
    }
    /// Touching moving content catches it, and that touch belongs to the
    /// moving scroller: the guarded list for the vertical gate, an enclosing
    /// one for the horizontal gate.
    func landsOnMotion(at time: Double) -> Bool {
        let recorded = motion.flatMap { abs($0.time - time) < 1e-6 ? $0 : nil }
        switch claims {
        case .vertical:
            guard let guarded else { return false }
            return recorded?.list ?? (Self.isMoving(guarded) || (guarded.engine as? PhysicsEngine)?.pan.forced == true)
        case .horizontal:
            guard let view else { return false }
            return recorded?.ancestor ?? Self.ancestorIsMoving(of: view)
        }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .possible, let view, let touch = touches.first else { return }
        let point = touch.location(in: view)
        guard let axis = lock.update(dx: point.x - start.x, dy: point.y - start.y) else { return }
        if axis == claims { onClaim?() }
        state = axis == claims ? .ended : .failed
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { if state == .possible { state = .failed } }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { if state == .possible { state = .failed } }
    // A gate only ever makes its dependents fail; it never excludes anyone by recognizing.
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    static func isMoving(_ list: UltraScrollView) -> Bool {
        if let platform = list.engine as? PlatformEngine { return platform.scroll.isDecelerating }
        guard let physics = list.engine as? PhysicsEngine else { return false }
        return physics.flightState != nil || physics.core.isDecelerating
    }
    static func ancestorIsMoving(of view: UIView) -> Bool {
        var current = view.superview
        while let candidate = current {
            if let scroller = candidate as? UltraScrollView, isMoving(scroller) { return true }
            if let scroll = candidate as? UIScrollView, scroll.isDecelerating { return true }
            current = candidate.superview
        }
        return false
    }
}

/// A row of a `HorizontalListView`: any list row, shown upright at `width`
/// points along the list and the list's full height across it.
@MainActor
public struct HorizontalRow: ListRow {
    public var base: any ListRow
    public var width: Double
    public init(_ base: any ListRow, width: Double) { self.base = base; self.width = width }
    public var identity: String { base.identity }
    public var revision: UInt64 { base.revision &* 0x100000001b3 ^ width.bitPattern }
    public var measuresAsynchronously: Bool { base.measuresAsynchronously }
    public var measurementEnvironment: UInt64 { base.measurementEnvironment }
    public func makeView() -> ListRowView { HorizontalRowView(content: base.makeView()) }
    public func apply(to view: ListRowView, transition: ListTransition) {
        guard let view = view as? HorizontalRowView else { return }
        view.length = width
        base.apply(to: view.content, transition: transition)
    }
    public func isEqual(to other: any ListRow) -> Bool {
        guard let other = other as? HorizontalRow else { return false }
        return width == other.width && base.isEqual(to: other.base)
    }
    /// The content is prepared at the row's width; the list's measurement is that width.
    public func prepare(width _: Double, environment: RenderEnvironment) async -> ListPreparation? {
        guard let prepared = await base.prepare(width: width, environment: environment) else { return nil }
        return ListPreparation(height: width, content: prepared.content)
    }
}

/// Holds a row's view turned back upright inside the turned list.
@MainActor
final class HorizontalRowView: ListRowView {
    override class var layerClass: AnyClass { MirroringLayer.self }
    let content: ListRowView
    private let turn = UIView()
    var length: Double = 0
    init(content: ListRowView) {
        self.content = content
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(turn); turn.addSubview(content)
        content.onContentDidChange = { [weak self] animated in self?.onContentDidChange?(animated) }
        content.readinessObserver = { [weak self] in self?.reportDisplayReady() }
    }
    override var isDisplayReady: Bool { content.isDisplayReady }
    override func update(width: Double, transition: ListTransition) -> Double {
        _ = content.update(width: length, transition: transition)
        setNeedsLayout()
        return length
    }
    override func applyPreparation(_ preparation: ListPreparation, width: Double, environment: RenderEnvironment) {
        content.applyPreparation(.init(height: width, content: preparation.content), width: preparation.height, environment: environment)
        setNeedsLayout()
    }
    override func visibleRectUpdated(_ rect: CGRect?) {
        layoutIfNeeded()
        content.visibleRectUpdated(rect.map { convert($0, to: content) })
    }
    override func attachedViewsUpdated(_ views: [UIView]) { content.attachedViewsUpdated(views) }
    override func layoutSubviews() {
        super.layoutSubviews()
        // This view lies across the list: its height runs along the screen's x axis.
        let along = bounds.height, across = bounds.width
        var owner = superview
        while let view = owner, !(view is HorizontalListView) { owner = view.superview }
        let rightToLeft = owner?.effectiveUserInterfaceLayoutDirection == .rightToLeft
        // Pinned at the corner where the content starts, so a size change moves no origin.
        turn.layer.anchorPoint = rightToLeft ? .init(x: 1, y: 0) : .zero
        turn.transform = rightToLeft ? .init(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0) : .init(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        turn.bounds = .init(x: 0, y: 0, width: along, height: across)
        turn.layer.position = .zero
        content.place(in: turn.bounds)
    }
    /// The list animates this view's size; the upright content follows on the same timing.
    func mirror(_ animation: CAAnimation, key: String) {
        guard let basic = animation.copy() as? CABasicAnimation else { return }
        basic.keyPath = key == AnimatedProperty.height.animationKey ? "bounds.size.width" : "bounds.size.height"
        basic.delegate = nil
        for layer in [turn.layer, content.layer] { layer.add(basic, forKey: key) }
    }
    func unmirror(_ key: String) { for layer in [turn.layer, content.layer] { layer.removeAnimation(forKey: key) } }
}

/// Reports the list's size animations to its view.
final class MirroringLayer: CALayer {
    override func add(_ animation: CAAnimation, forKey key: String?) {
        super.add(animation, forKey: key)
        guard let key, key == AnimatedProperty.height.animationKey || key == AnimatedProperty.width.animationKey else { return }
        // Layers of list rows are only touched on the main thread.
        nonisolated(unsafe) let animation = animation
        let view = delegate as? HorizontalRowView
        MainActor.assumeIsolated { view?.mirror(animation, key: key) }
    }
    override func removeAnimation(forKey key: String) {
        super.removeAnimation(forKey: key)
        guard key == AnimatedProperty.height.animationKey || key == AnimatedProperty.width.animationKey else { return }
        let view = delegate as? HorizontalRowView
        MainActor.assumeIsolated { view?.unmirror(key) }
    }
}

extension AnimatedProperty {
    var animationKey: String { "ultraview.list.\(rawValue)" }
}
#endif
