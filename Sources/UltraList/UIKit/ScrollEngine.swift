#if canImport(UIKit)
import UIKit
import QuartzCore

@MainActor
protocol ScrollEngine: AnyObject {
    var host: UIView { get }
    var offset: Double { get }
    var activeFlight: ScrollFlight? { get }
    var dragging: Bool { get }
    var onScroll: ((Double) -> Void)? { get set }
    var onFlightChanged: ((ScrollFlight?) -> Void)? { get set }
    var willBeginDragging: (() -> Void)? { get set }
    var didEndDragging: (() -> Void)? { get set }
    var didEndScrolling: (() -> Void)? { get set }
    var didTouchDown: (() -> Void)? { get set }
    var shouldStopOnRelease: ((Double) -> Bool)? { get set }
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
    var offset: Double { core.offset }
    var activeFlight: ScrollFlight? { flightState?.flight }
    var dragging: Bool { core.isDragging }
    var onScroll: ((Double) -> Void)?
    var onFlightChanged: ((ScrollFlight?) -> Void)?
    var willBeginDragging: (() -> Void)?
    var didEndDragging: (() -> Void)?
    var didEndScrolling: (() -> Void)?
    var didTouchDown: (() -> Void)?
    var shouldStopOnRelease: ((Double) -> Bool)?
    private var link: CADisplayLink?
    private let target = SamplingTarget()
    private var baseline = CGPoint.zero
    private var sawDrag = false
    private var settleScheduled = false
    private var edges = ScrollEdges()
    private let flightKey = "ultraview.scroll.flight"
    private var now: Double { host.layer.convertTime(CACurrentMediaTime(), from: nil) }
    private var maxFPS: Float { Float(host.window?.windowScene?.screen.maximumFramesPerSecond ?? 60) }

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
        if flightState != nil {
            flightState?.shift(by: delta, edges: edges)
            writeBase(host.bounds.origin.y + delta)
            onFlightChanged?(activeFlight)
        } else { writeBase(offset) }
    }
    func setEdges(_ edges: ScrollEdges) {
        guard self.edges != edges else { return }
        self.edges = edges; core.setEdges(edges); flightState?.edgesChanged(to: edges)
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
            if settled { core.halt(); self.link?.invalidate(); self.link = nil; didEndScrolling?() }
        } else { self.link?.invalidate(); self.link = nil }
    }
    @objc private func panned() {
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
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { false }
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
    let scroll = UIScrollView()
    var host: UIView { scroll }
    var offset: Double { scroll.contentOffset.y }
    var activeFlight: ScrollFlight? { nil }
    var dragging: Bool { scroll.isDragging }
    var onScroll: ((Double) -> Void)?
    var onFlightChanged: ((ScrollFlight?) -> Void)?
    var willBeginDragging: (() -> Void)?
    var didEndDragging: (() -> Void)?
    var didEndScrolling: (() -> Void)?
    var didTouchDown: (() -> Void)?
    var shouldStopOnRelease: ((Double) -> Bool)?
    private var writing = false
    override init() {
        super.init(); scroll.delegate = self
        scroll.contentInsetAdjustmentBehavior = .never; scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = false; scroll.showsHorizontalScrollIndicator = false
        scroll.clipsToBounds = false; scroll.scrollsToTop = false
        let observer = TouchObserver(); observer.cancelsTouchesInView = false
        observer.down = { [weak self] in self?.didTouchDown?() }; scroll.addGestureRecognizer(observer)
    }
    func setOffset(_ value: Double) { writing = true; scroll.setContentOffset(.init(x: 0, y: value), animated: false); writing = false }
    func shift(by delta: Double) { setOffset(offset + delta) }
    func setEdges(_ edges: ScrollEdges) {
        writing = true
        let low = edges.minimum ?? 0, high = max(low, edges.maximum ?? 10_000_000 - scroll.bounds.height)
        let height = max(scroll.bounds.height, high + scroll.bounds.height)
        scroll.contentInset = .init(top: -low, left: 0, bottom: high - (height - scroll.bounds.height), right: 0)
        scroll.contentSize = .init(width: scroll.bounds.width, height: height)
        writing = false
    }
    func halt() { setOffset(offset) }
    func sync() {}
    func reanchorDrag() {}
    func teardown() { halt() }
    func beginMomentum(velocity: Double) {
        scroll.setContentOffset(.init(x: 0, y: offset + velocity * 0.35), animated: true)
    }
    func containerOrigin(height: Double, top: Bool, bottom: Bool) -> Double { top ? 0 : bottom ? 10_000_000 - height : 5_000_000 - height / 2 }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { if !writing { onScroll?(offset) } }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { willBeginDragging?() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate: Bool) { didEndDragging?(); if !willDecelerate { didEndScrolling?() } }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { didEndScrolling?() }
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        if shouldStopOnRelease?(velocity.y * 1000) == true { targetContentOffset.pointee = scrollView.contentOffset }
    }
}
#endif