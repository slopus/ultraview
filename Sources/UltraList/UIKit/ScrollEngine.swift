#if canImport(UIKit)
import UIKit
import QuartzCore

@MainActor
protocol ScrollEngine: AnyObject {
    var host: UIView { get }
    var offset: Double { get }
    var activeFlight: ScrollFlight? { get }
    func coveredOffsets(horizon: Double) -> ClosedRange<Double>?
    var dragging: Bool { get }
    var decelerating: Bool { get }
    var tracking: Bool { get }
    var onScroll: ((Double) -> Void)? { get set }
    var onFlightChanged: ((ScrollFlight?) -> Void)? { get set }
    var willBeginDragging: (() -> Void)? { get set }
    var didEndDragging: (() -> Void)? { get set }
    var didEndScrolling: (() -> Void)? { get set }
    var didTouchDown: (() -> Void)? { get set }
    var shouldStopOnRelease: ((Double) -> Bool)? { get set }
    var onInput: ((GestureRecording.Event) -> Void)? { get set }
    func receive(_ event: GestureRecording.Event)
    func attachInput(to view: UIView)
    func setOffset(_ value: Double)
    func shift(by delta: Double)
    func setEdges(_ edges: ScrollEdges)
    func halt()
    func sync()
    func reanchorDrag()
    func teardown()
    func beginMomentum(velocity: Double)
    func containerOrigin(height: Double, top: Bool, bottom: Bool) -> Double
}

@MainActor
final class SamplingTarget: NSObject {
    weak var engine: PhysicsEngine?
    @objc func tick(_ link: CADisplayLink) { engine?.tick(link) }
}

@MainActor
final class InputPan: UIPanGestureRecognizer {
    var touchDown: ((Double) -> Bool)?
    var touchUp: (() -> Void)?
    private(set) var indirect = true
    var forced = false
    private var activeTouches = Set<ObjectIdentifier>()
    override func reset() { super.reset(); indirect = true; forced = false; activeTouches.removeAll() }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        let first = activeTouches.isEmpty
        for touch in touches { activeTouches.insert(ObjectIdentifier(touch)) }
        guard first else { return }
        indirect = false
        if touchDown?(event.timestamp) == true, state == .possible { forced = true; state = .began }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        for touch in touches { activeTouches.remove(ObjectIdentifier(touch)) }
        if activeTouches.isEmpty { touchUp?() }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event); touchUp?()
    }
    func forceBegin() { forced = true; state = .began }
}

@MainActor
final class PhysicsEngine: NSObject, ScrollEngine, UIGestureRecognizerDelegate {
    let host = UIView()
    let pan = InputPan()
    let mode: ScrollEngineMode
    var core = ScrollCore()
    var flightState: FlightState?
    private var coveragePrediction: ScrollFlight?
    var offset: Double { core.offset }
    var activeFlight: ScrollFlight? { flightState?.flight }
    var dragging: Bool { core.isDragging }
    var decelerating: Bool { core.isDecelerating }
    var tracking: Bool { pan.state == .began || pan.state == .changed }
    var onScroll: ((Double) -> Void)?
    var onFlightChanged: ((ScrollFlight?) -> Void)?
    var willBeginDragging: (() -> Void)?
    var didEndDragging: (() -> Void)?
    var didEndScrolling: (() -> Void)?
    var didTouchDown: (() -> Void)?
    var shouldStopOnRelease: ((Double) -> Bool)?
    var onInput: ((GestureRecording.Event) -> Void)?
    weak var keyboardPanRecognizer: UIPanGestureRecognizer?
    private var link: CADisplayLink?
    private let target = SamplingTarget()
    private var baseline = CGPoint.zero
    private var sawDrag = false
    private var settleScheduled = false
    private var edges = ScrollEdges()
    private let flightKey = "ultraview.scroll.flight"
    private var now: Double { host.layer.convertTime(CACurrentMediaTime(), from: nil) }
    private var maxFPS: Float { Float(host.window?.windowScene?.screen.maximumFramesPerSecond ?? 60) }
    func coveredOffsets(horizon: Double) -> ClosedRange<Double>? {
        let flight = flightState?.flight ?? (core.isDecelerating ? coveragePrediction : nil)
        return flight?.coveredOffsets(at: now, horizon: horizon)
    }

    init(mode: ScrollEngineMode) {
        self.mode = mode
        super.init()
        target.engine = self
        host.clipsToBounds = false
        pan.addTarget(self, action: #selector(panned))
        pan.delegate = self; pan.delaysTouchesEnded = false
        pan.allowedScrollTypesMask = .continuous
        host.addGestureRecognizer(pan)
        pan.touchDown = { [weak self] time in
            guard let self else { return false }
            sawDrag = false
            onInput?(.init(time: time, phase: .touchDown))
            core.touchDown(at: time)
            didTouchDown?()
            let moving = flightState != nil || core.isDecelerating
            if moving { catchMotion(braking: true) }
            return moving && gestureRecognizerShouldBegin(pan)
        }
        pan.touchUp = { [weak self] in
            guard let self, !sawDrag, core.resumeBounce() else { return }
            startMotion()
        }
    }
    func containerOrigin(height: Double, top: Bool, bottom: Bool) -> Double {
        ScrollCore.containerOrigin(height: height, topLoaded: top, bottomLoaded: bottom)
    }
    func attachInput(to view: UIView) { view.addGestureRecognizer(pan) }
    private func writeBase(_ value: Double) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        host.bounds.origin.y = value
        CATransaction.commit()
    }
    func setOffset(_ value: Double) {
        let dragging = pan.state == .began || pan.state == .changed
        catchMotion(braking: false); core.setOffset(value)
        if dragging { baseline = pan.translation(in: host); core.beginDrag() }
        writeBase(value)
    }
    func halt() { catchMotion(braking: false); core.halt(); writeBase(offset) }
    func sync() { flightState?.beginTick(at: now, core: &core) }
    func shift(by delta: Double) {
        core.shift(by: delta)
        coveragePrediction?.coordinateShift += delta
        if flightState != nil {
            flightState?.shift(by: delta, edges: edges)
            writeBase(host.bounds.origin.y + delta)
            onFlightChanged?(activeFlight)
        } else { writeBase(offset) }
    }
    func setEdges(_ edges: ScrollEdges) {
        guard self.edges != edges else { return }
        let discoversEdge = self.edges.minimum == nil && edges.minimum != nil || self.edges.maximum == nil && edges.maximum != nil
        self.edges = edges; core.setEdges(edges); flightState?.edgesChanged(to: edges)
        if discoversEdge, var state = flightState, state.rebakePending {
            let time = now
            state.beginTick(at: time, core: &core)
            if state.rebake(at: time, core: core) {
                flightState = state; writeBase(state.flight.settledOffset)
                emit(state.flight); onFlightChanged?(state.flight)
            }
        }
        if coveragePrediction != nil {
            coveragePrediction = .init(trajectory: .init(baking: core.axis), beginTime: now, coordinateShift: 0)
        }
        // An edge arriving under resting content starts its own return.
        if flightState == nil, !core.isDragging, !core.isDecelerating, !edges.contains(offset), !settleScheduled {
            settleScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; settleScheduled = false
                if flightState == nil, !core.isDragging, !core.isDecelerating, core.resumeBounce() { startMotion() }
            }
        }
    }
    func reanchorDrag() { core.reanchorDrag() }
    func teardown() { halt(); link?.invalidate(); link = nil }
    func beginMomentum(velocity: Double) {
        halt(); core.viewport = host.bounds.height; core.scale = max(1, host.traitCollection.displayScale)
        core.reseed(offset: offset, velocity: velocity / 1000); startMotion()
    }

    private func catchMotion(braking: Bool) {
        let predicted = coveragePrediction != nil
        coveragePrediction = nil
        if let state = flightState {
            let time = now
            let stop = FlightState.brakeStopTime(now: time, lastFrame: link.flatMap { $0.timestamp > 0 ? host.layer.convertTime($0.timestamp, from: nil) : nil }, nextFrame: link.flatMap { $0.timestamp > 0 ? host.layer.convertTime($0.targetTimestamp, from: nil) : nil }, maximumFPS: Double(maxFPS))
            let brake = braking ? state.braked(stoppingAt: stop) : nil
            let value = brake?.settledOffset ?? state.flight.offset(at: time)
            flightState = nil
            core.setOffset(value); writeBase(value)
            if let brake, brake.trajectory.duration > 1e-6 { emit(brake) }
            else { host.layer.removeAnimation(forKey: flightKey) }
            onFlightChanged?(nil)
        } else {
            core.halt()
            host.layer.removeAnimation(forKey: flightKey)
            if predicted { onFlightChanged?(nil) }
        }
        link?.invalidate(); link = nil
    }
    private func startLink() {
        guard link == nil else { return }
        let link = CADisplayLink(target: target, selector: #selector(SamplingTarget.tick(_:)))
        let fps = max(60, maxFPS)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
        link.add(to: .main, forMode: .common); self.link = link
    }
    private func startMotion() {
        guard core.isDecelerating else { return }
        if mode == .keyframe {
            let saved = core
            let settled = core.step(seconds: 0.5 / Double(max(60, maxFPS)))
            if settled {
                core.halt(); writeBase(offset); onFlightChanged?(nil); onScroll?(offset); didEndScrolling?(); return
            }
            core = saved
            let state = FlightState(core: core, time: now)
            flightState = state; writeBase(state.flight.settledOffset)
            emit(state.flight); onFlightChanged?(state.flight)
        } else {
            coveragePrediction = .init(trajectory: .init(baking: core.axis), beginTime: now, coordinateShift: 0)
            onFlightChanged?(coveragePrediction)
        }
        startLink()
    }
    private func emit(_ flight: ScrollFlight) {
        let animation = CAKeyframeAnimation(keyPath: "bounds.origin.y")
        animation.isAdditive = true; animation.calculationMode = .linear
        animation.values = flight.trajectory.additiveValues
        animation.keyTimes = flight.trajectory.keyTimes.map { NSNumber(value: $0) }
        animation.duration = flight.trajectory.duration; animation.beginTime = flight.beginTime
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: maxFPS, preferred: maxFPS)
        host.layer.add(animation, forKey: flightKey)
    }
    func tick(_ link: CADisplayLink) {
        core.viewport = host.bounds.height
        if var state = flightState {
            let time = now
            if state.isComplete(at: time), !state.rebakePending {
                let rest = state.flight.settledOffset
                flightState = nil; core.setOffset(rest); writeBase(rest)
                host.layer.removeAnimation(forKey: flightKey)
                onFlightChanged?(nil); onScroll?(rest)
                self.link?.invalidate(); self.link = nil; didEndScrolling?(); return
            }
            state.beginTick(at: time, core: &core); flightState = state
            onScroll?(offset)
            if var current = flightState, current.rebake(at: time, core: core) {
                flightState = current; writeBase(current.flight.settledOffset)
                emit(current.flight); onFlightChanged?(current.flight)
            }
        } else if core.isDecelerating {
            let settled = core.step(seconds: max(1 / 120, link.targetTimestamp - link.timestamp))
            writeBase(offset); onScroll?(offset)
            if settled { coveragePrediction = nil; core.halt(); self.link?.invalidate(); self.link = nil; didEndScrolling?() }
        } else { self.link?.invalidate(); self.link = nil }
    }
    @objc private func panned() {
        let phase: GestureRecording.Event.Phase?
        switch pan.state {
        case .began: phase = .began
        case .changed: phase = .changed
        case .ended: phase = .ended
        case .cancelled: phase = .cancelled
        default: phase = nil
        }
        if let phase {
            let translation = pan.translation(in: host), velocity = pan.velocity(in: host)
            onInput?(.init(time: CACurrentMediaTime(), phase: phase, translation: .init(x: translation.x, y: translation.y), velocity: .init(x: velocity.x, y: velocity.y)))
        }
        switch pan.state {
        case .began:
            if pan.indirect { core.touchDown(at: CACurrentMediaTime()); catchMotion(braking: true) }
            core.viewport = host.bounds.height; core.scale = max(1, host.traitCollection.displayScale)
            core.coefficient = pan.indirect ? 0.715 : 0.55
            baseline = pan.forced ? pan.translation(in: host) : .zero
            sawDrag = true; core.beginDrag(); willBeginDragging?()
            if !pan.forced { dragSample() }
        case .changed: dragSample()
        case .ended, .cancelled:
            let velocity = pan.velocity(in: host)
            let suppressed = pan.state == .cancelled || shouldStopOnRelease?(velocity.y) == true
            let moving = core.endDrag(velocity: suppressed ? .zero : .init(x: velocity.x, y: velocity.y), at: CACurrentMediaTime())
            if moving { startMotion() }
            didEndDragging?()
        default: break
        }
    }
    func receive(_ event: GestureRecording.Event) {
        switch event.phase {
        case .touchDown:
            core.touchDown(at: event.time); catchMotion(braking: true); didTouchDown?()
        case .began:
            catchMotion(braking: false)
            core.viewport = host.bounds.height; core.scale = max(1, host.traitCollection.displayScale)
            core.touchDown(at: event.time); core.beginDrag(); willBeginDragging?()
            core.drag(translation: event.translation, velocity: event.velocity)
            writeBase(offset); onScroll?(offset)
        case .changed:
            guard core.isDragging else { return }
            core.drag(translation: event.translation, velocity: event.velocity)
            writeBase(offset); onScroll?(offset)
        case .ended, .cancelled:
            guard core.isDragging else { return }
            let suppressed = event.phase == .cancelled || shouldStopOnRelease?(event.velocity.y) == true
            if core.endDrag(velocity: suppressed ? .zero : event.velocity, at: event.time) { startMotion() }
            didEndDragging?()
        }
    }
    private func dragSample() {
        let translation = pan.translation(in: host), velocity = pan.velocity(in: host)
        let delta = ScrollVector(x: translation.x - baseline.x, y: translation.y - baseline.y)
        if pan.forced && delta == .zero && velocity == .zero { return }
        core.drag(translation: delta, velocity: .init(x: velocity.x, y: velocity.y))
        writeBase(offset); onScroll?(offset)
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if host.gestureRecognizers?.contains(where: { $0 !== pan && ($0 as? UIPanGestureRecognizer)?.minimumNumberOfTouches == 2 }) == true { return pan.numberOfTouches < 2 }
        if let control = host.hitTest(pan.location(in: host), with: nil) as? UIControl, control.isTracking { return false }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { other === keyboardPanRecognizer }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive event: UIEvent) -> Bool {
        if pan.indirect, pan.state == .possible, flightState != nil || core.isDecelerating {
            core.touchDown(at: event.timestamp); didTouchDown?(); catchMotion(braking: true)
            if gestureRecognizerShouldBegin(pan) { pan.forceBegin() }
        }
        return true
    }
}

@MainActor
private final class TouchObserver: UIGestureRecognizer {
    var down: (() -> Void)?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { down?(); state = .failed }
}

@MainActor
final class PlatformEngine: NSObject, ScrollEngine, UIScrollViewDelegate {
    let scroll: UIScrollView
    var host: UIView { scroll }
    var offset: Double { scroll.contentOffset.y }
    var activeFlight: ScrollFlight? { nil }
    var tracking: Bool { scroll.panGestureRecognizer.state == .began || scroll.panGestureRecognizer.state == .changed }
    var dragging: Bool { scroll.isDragging }
    var decelerating: Bool { nativeDecelerating || scroll.isDecelerating || replay?.decelerating == true || coveragePrediction != nil }
    var onScroll: ((Double) -> Void)?
    var onFlightChanged: ((ScrollFlight?) -> Void)?
    var willBeginDragging: (() -> Void)?
    var didEndDragging: (() -> Void)?
    var didEndScrolling: (() -> Void)?
    var didTouchDown: (() -> Void)?
    var shouldStopOnRelease: ((Double) -> Bool)?
    var onInput: ((GestureRecording.Event) -> Void)?
    private var writing = false
    private var edges: ScrollEdges?
    private var replay: PhysicsEngine?
    private var coveragePrediction: ScrollFlight?
    private var nativeDecelerating = false
    func coveredOffsets(horizon: Double) -> ClosedRange<Double>? {
        if let coverage = replay?.coveredOffsets(horizon: horizon) { return coverage }
        return coveragePrediction?.coveredOffsets(at: scroll.layer.convertTime(CACurrentMediaTime(), from: nil), horizon: horizon)
    }
    private let touchObserver = TouchObserver()
    override convenience init() { self.init(scroll: UIScrollView()) }
    init(scroll: UIScrollView) {
        self.scroll = scroll
        super.init(); scroll.delegate = self
        scroll.contentInsetAdjustmentBehavior = .never; scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = false; scroll.showsHorizontalScrollIndicator = false
        scroll.clipsToBounds = false; scroll.scrollsToTop = false
        touchObserver.cancelsTouchesInView = false
        touchObserver.down = { [weak self] in
            self?.didTouchDown?(); self?.onInput?(.init(time: CACurrentMediaTime(), phase: .touchDown))
        }
        scroll.addGestureRecognizer(touchObserver)
        scroll.panGestureRecognizer.addTarget(self, action: #selector(panned))
    }
    func setOffset(_ value: Double) { coveragePrediction = nil; writing = true; scroll.setContentOffset(.init(x: 0, y: value), animated: false); writing = false }
    func shift(by delta: Double) {
        guard abs(delta) > 1e-9 else { return }
        // Reparking changes coordinates, not the gesture's velocity. Calling
        // setContentOffset here cancels the scroll view's native deceleration.
        writing = true
        var bounds = scroll.bounds; bounds.origin.y += delta; scroll.bounds = bounds
        writing = false
        coveragePrediction?.coordinateShift += delta
        replay?.shift(by: delta)
    }
    func setEdges(_ edges: ScrollEdges) {
        guard self.edges != edges else { return }
        self.edges = edges
        replay?.setEdges(edges)
        writing = true
        let low = edges.minimum ?? 0, high = max(low, edges.maximum ?? 10_000_000 - scroll.bounds.height)
        let height = max(scroll.bounds.height, high + scroll.bounds.height)
        let inset = UIEdgeInsets(top: -low, left: 0, bottom: high - (height - scroll.bounds.height), right: 0)
        let size = CGSize(width: scroll.bounds.width, height: height)
        if scroll.contentInset != inset { scroll.contentInset = inset }
        if scroll.contentSize != size { scroll.contentSize = size }
        writing = false
    }
    func halt() { nativeDecelerating = false; replay?.teardown(); replay = nil; setOffset(offset) }
    func sync() {}
    func reanchorDrag() {}
    func teardown() { halt() }
    func beginMomentum(velocity: Double) {
        let time = scroll.layer.convertTime(CACurrentMediaTime(), from: nil)
        coveragePrediction = .init(trajectory: .init(samples: [
            .init(time: 0, offset: offset, velocity: velocity),
            .init(time: 0.35, offset: offset + velocity * 0.35, velocity: 0),
        ]), beginTime: time, coordinateShift: 0)
        onFlightChanged?(coveragePrediction)
        scroll.setContentOffset(.init(x: 0, y: offset + velocity * 0.35), animated: true)
    }
    func attachInput(to view: UIView) {
        view.addGestureRecognizer(scroll.panGestureRecognizer)
        view.addGestureRecognizer(touchObserver)
    }
    @objc private func panned() {
        let pan = scroll.panGestureRecognizer
        let phase: GestureRecording.Event.Phase
        switch pan.state {
        case .began: phase = .began
        case .changed: phase = .changed
        case .ended: phase = .ended
        case .cancelled: phase = .cancelled
        default: return
        }
        let translation = pan.translation(in: scroll), velocity = pan.velocity(in: scroll)
        onInput?(.init(time: CACurrentMediaTime(), phase: phase, translation: .init(x: translation.x, y: translation.y), velocity: .init(x: velocity.x, y: velocity.y)))
    }
    func receive(_ event: GestureRecording.Event) {
        // UIKit has no public API for synthesizing touches into its recognizer.
        // External streams use the measured stepped driver; real touches retain
        // UIScrollView's own deceleration and bounce.
        if replay == nil {
            let driver = PhysicsEngine(mode: .stepped)
            driver.host.frame = scroll.bounds; driver.setOffset(offset)
            driver.setEdges(edges ?? .init())
            driver.onScroll = { [weak self] offset in
                guard let self else { return }
                writing = true; scroll.bounds.origin.y = offset; writing = false
                onScroll?(offset)
            }
            driver.willBeginDragging = { [weak self] in self?.willBeginDragging?() }
            driver.didEndDragging = { [weak self] in self?.didEndDragging?() }
            driver.didEndScrolling = { [weak self] in self?.didEndScrolling?() }
            driver.onFlightChanged = { [weak self] flight in self?.onFlightChanged?(flight) }
            replay = driver
        }
        replay?.receive(event)
    }
    func containerOrigin(height: Double, top: Bool, bottom: Bool) -> Double { top ? 0 : bottom ? 10_000_000 - height : 5_000_000 - height / 2 }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { if !writing { onScroll?(offset) } }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { nativeDecelerating = false; coveragePrediction = nil; willBeginDragging?() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate: Bool) {
        nativeDecelerating = willDecelerate
        if !willDecelerate { coveragePrediction = nil }
        didEndDragging?()
        if !willDecelerate { didEndScrolling?() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { nativeDecelerating = false; coveragePrediction = nil; didEndScrolling?() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { coveragePrediction = nil; didEndScrolling?() }
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        if shouldStopOnRelease?(velocity.y * 1000) == true {
            coveragePrediction = nil; targetContentOffset.pointee = scrollView.contentOffset
        } else if abs(velocity.y) > 0.001 {
            var axis = ScrollAxis(offset: offset, edges: edges ?? .init(), range: scroll.bounds.height)
            axis.release(velocity: velocity.y)
            coveragePrediction = .init(trajectory: .init(baking: axis), beginTime: scroll.layer.convertTime(CACurrentMediaTime(), from: nil), coordinateShift: 0)
            let originalOffset = offset
            onFlightChanged?(coveragePrediction)
            targetContentOffset.pointee.y += offset - originalOffset
        }
    }
}
#endif