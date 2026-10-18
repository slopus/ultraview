#if canImport(UIKit)
import UIKit

/// A vertical scroll host with a render-server momentum driver by default.
@MainActor
open class UltraScrollView: UIView {
    let engine: any ScrollEngine
    public var contentView: UIView { engine.host }
    public var currentScrollOffset: Double { engine.offset }
    public var isScrollFlightActive: Bool { engine.activeFlight != nil }
    public var isDragging: Bool { engine.dragging }
    public var isDecelerating: Bool { engine.decelerating }
    public var isTracking: Bool { engine.tracking }
    private var keyboardInput: UIScrollView?
    /// Uses the system's keyboard interaction while the selected engine owns list motion.
    public var keyboardDismissMode: UIScrollView.KeyboardDismissMode = .none {
        didSet { configureKeyboardInput() }
    }
    public let engineMode: ScrollEngineMode
    public var onScroll: ((Double) -> Void)?
    public var willBeginDragging: (() -> Void)?
    public var didEndDragging: (() -> Void)?
    public var didEndScrolling: (() -> Void)?
    public var shouldStopScrolling: ((Double) -> Bool)?
    public var onScrollInput: ((GestureRecording.Event) -> Void)? {
        get { engine.onInput }
        set { engine.onInput = newValue }
    }
    /// Whether a tap on the status bar scrolls to the top. Of the hosts in a
    /// window that allow it, only the largest one not inside another host
    /// answers; a horizontal list never does.
    public var scrollsToTop = true {
        didSet { if scrollsToTop != oldValue { ScrollToTopClaims.update(in: window) } }
    }
    /// Asked before a status bar tap scrolls to the top; `false` ignores the tap.
    public var shouldScrollToTop: (() -> Bool)?
    /// Called once a scroll to the top rests on the top edge, after any
    /// measurement it waited for, unless a touch, a drag or another scroll
    /// to the top interrupted it.
    public var didScrollToTop: (() -> Void)?
    private lazy var scrollToTopProxy = ScrollToTopProxy(owner: self)
    private weak var claimedWindow: UIWindow?
    private var claimedSize = CGSize.zero
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
        insertSubview(scrollToTopProxy, at: 0)
        ScrollToTopClaims.register(self)
    }
    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    open override func layoutSubviews() {
        super.layoutSubviews()
        engine.host.frame = bounds
        keyboardInput?.frame = bounds
        scrollToTopProxy.frame = bounds
        if bounds.size != claimedSize { claimedSize = bounds.size; ScrollToTopClaims.update(in: window) }
        updateEdges()
    }
    private func configureKeyboardInput() {
        if let platform = engine as? PlatformEngine {
            platform.scroll.keyboardDismissMode = keyboardDismissMode
            return
        }
        guard let physics = engine as? PhysicsEngine else { return }
        if keyboardDismissMode == .none {
            if let input = keyboardInput { input.panGestureRecognizer.view?.removeGestureRecognizer(input.panGestureRecognizer) }
            keyboardInput?.removeFromSuperview(); keyboardInput = nil
            physics.keyboardPanRecognizer = nil
            return
        }
        if keyboardInput == nil {
            // An empty system scroll view brokers the public interactive keyboard API.
            // Its content offset never controls the list or its render-server flight.
            let input = UIScrollView(frame: bounds)
            input.contentInsetAdjustmentBehavior = .never
            input.contentSize = .init(width: 1, height: 10_000_000)
            input.contentOffset.y = 5_000_000
            input.bounces = false; input.scrollsToTop = false
            input.showsVerticalScrollIndicator = false; input.showsHorizontalScrollIndicator = false
            input.isAccessibilityElement = false; input.accessibilityElementsHidden = true
            insertSubview(input, at: 0)
            addGestureRecognizer(input.panGestureRecognizer)
            physics.keyboardPanRecognizer = input.panGestureRecognizer
            keyboardInput = input
        }
        keyboardInput?.keyboardDismissMode = keyboardDismissMode
    }
    open override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { engine.teardown() }
        else { engine.activate() }
        let previous = claimedWindow
        claimedWindow = window
        if window == nil { claimScrollToTop(false) }
        if previous !== window { ScrollToTopClaims.update(in: previous) }
        ScrollToTopClaims.update(in: window)
    }
    open override var isHidden: Bool {
        didSet { if isHidden != oldValue { ScrollToTopClaims.update(in: window) } }
    }
    func claimScrollToTop(_ claims: Bool) {
        if scrollToTopProxy.scrollsToTop != claims { scrollToTopProxy.scrollsToTop = claims }
    }
    func statusBarTapped() {
        guard shouldScrollToTop?() ?? true else { return }
        scrollToTop(animated: true)
    }
    /// Scrolls to the top edge. This view has no rows to animate along and
    /// moves at once; a list animates.
    open func scrollToTop(animated: Bool = true) {
        engine.halt(); engine.setOffset(-contentInsets.top); handleScroll(engine.offset)
        didScrollToTop?()
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
    /// Feeds a recorded or shared gesture without synthesizing private UIKit touches.
    /// The platform engine uses the stepped driver for externally supplied input.
    public func receiveScrollInput(_ event: GestureRecording.Event) { engine.receive(event) }
    /// Moves the input recognizers to a common ancestor for a shared gesture surface.
    public func attachScrollInput(to view: UIView) {
        engine.attachInput(to: view)
        if let keyboardInput { view.addGestureRecognizer(keyboardInput.panGestureRecognizer) }
    }
}
#endif