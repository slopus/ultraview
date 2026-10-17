import Foundation

public enum ScrollEngineMode: String, Sendable, CaseIterable { case uiKit, stepped, keyframe }

/// Shared state for platform drivers and deterministic replay. It owns no clock or view.
public struct ScrollCore: Sendable {
    public private(set) var axis: ScrollAxis
    public private(set) var decision = ReleaseDecision()
    public var viewport: Double
    public var scale: Double = 1
    public var coefficient: Double = 0.55
    public var offset: Double { axis.offset }
    public var isDecelerating: Bool { axis.phase == .decelerating }
    public var isDragging: Bool { axis.phase == .dragging }
    public init(offset: Double = 0, viewport: Double = 800) {
        self.viewport = viewport; axis = .init(offset: offset, range: viewport)
    }
    public mutating func setEdges(_ edges: ScrollEdges) { axis.edges = edges }
    public mutating func shift(by delta: Double) { axis.shift(by: delta) }
    public mutating func touchDown(at time: Double) { decision.touchDown(at: time) }
    public mutating func beginDrag() {
        rebuild(); axis.beginDrag(); decision.beginGesture()
    }
    public mutating func drag(translation: ScrollVector, velocity: ScrollVector) {
        decision.sample(velocity: velocity, translation: translation)
        axis.drag(translation: translation.y); axis.multiplier = decision.multiplier
    }
    @discardableResult
    public mutating func endDrag(velocity: ScrollVector, at time: Double) -> Bool {
        let outcome = decision.release(recognizerVelocity: velocity, at: time)
        if outcome.decelerates || !axis.edges.contains(offset) {
            axis.release(velocity: outcome.velocity.y, multiplier: outcome.multiplier)
            return true
        }
        rebuild(); return false
    }
    public mutating func step(seconds: Double) -> Bool {
        let result = axis.step(milliseconds: seconds * 1000)
        if result.endedDeceleration { decision.resetStreak() }
        return result.settled
    }
    public mutating func reseed(offset: Double, velocity: Double) { axis.reseed(offset: offset, velocity: velocity) }
    public mutating func reanchorDrag() { axis.reanchorDrag() }
    public mutating func noteDecelerationEnded() { decision.resetStreak(); axis.multiplier = 1 }
    public mutating func halt() { rebuild() }
    public mutating func setOffset(_ value: Double) { axis.shift(by: value - offset); rebuild() }
    @discardableResult
    public mutating func resumeBounce() -> Bool {
        guard !axis.edges.contains(offset) else { return false }
        rebuild(); axis.release(velocity: 0); return true
    }
    public static func containerOrigin(height: Double, topLoaded: Bool, bottomLoaded: Bool) -> Double {
        topLoaded ? 0 : bottomLoaded ? -height : -height / 2
    }
    private mutating func rebuild() {
        axis = .init(offset: offset, edges: axis.edges, range: viewport, scale: scale, coefficient: coefficient)
    }
}

public struct ScrollFlight: Sendable, Equatable {
    public var trajectory: ScrollTrajectory
    public var beginTime: Double
    public var coordinateShift: Double
    public var settledOffset: Double { trajectory.finalOffset + coordinateShift }
    public func offset(at time: Double) -> Double { trajectory.sample(at: time - beginTime).offset + coordinateShift }
}

/// Time is supplied at each operation; offset reads never advance the motion.
public struct FlightState: Sendable {
    public private(set) var flight: ScrollFlight
    public private(set) var generation: UInt64 = 0
    public private(set) var rebakePending = false
    private var bakedEdges: ScrollEdges
    private var lastTick: Double?
    public init(core: ScrollCore, time: Double) {
        flight = .init(trajectory: .init(baking: core.axis), beginTime: time, coordinateShift: 0)
        bakedEdges = core.axis.edges
    }
    public func isComplete(at time: Double) -> Bool { time - flight.beginTime >= flight.trajectory.duration }
    public mutating func beginTick(at time: Double, core: inout ScrollCore) {
        lastTick = time
        core.reseed(offset: flight.offset(at: time), velocity: flight.trajectory.sample(at: time - flight.beginTime).velocity)
        if let reset = flight.trajectory.multiplierResetTime, time - flight.beginTime >= reset { core.noteDecelerationEnded() }
    }
    public mutating func shift(by delta: Double, edges: ScrollEdges) {
        flight.coordinateShift += delta
        edgesChanged(to: edges)
    }
    public mutating func edgesChanged(to edges: ScrollEdges) {
        let extent = flight.trajectory.extent(after: (lastTick ?? flight.beginTime) - flight.beginTime)
        func reaches(_ edges: ScrollEdges, shift: Double) -> Bool {
            (edges.minimum.map { extent.lowerBound + shift <= $0 + 0.5 } ?? false)
            || (edges.maximum.map { extent.upperBound + shift >= $0 - 0.5 } ?? false)
        }
        rebakePending = rebakePending || reaches(bakedEdges, shift: 0) || reaches(edges, shift: flight.coordinateShift)
    }
    @discardableResult
    public mutating func rebake(at time: Double, core: ScrollCore) -> Bool {
        guard rebakePending else { return false }
        let joined = flight.trajectory.splicing(beginTime: flight.beginTime, now: time, future: .init(baking: core.axis), shift: flight.coordinateShift)
        flight = .init(trajectory: joined.trajectory, beginTime: joined.beginTime, coordinateShift: 0)
        bakedEdges = core.axis.edges; rebakePending = false; generation += 1
        return true
    }
    public func braked(stoppingAt time: Double) -> ScrollFlight {
        .init(trajectory: flight.trajectory.truncated(at: time - flight.beginTime), beginTime: flight.beginTime, coordinateShift: flight.coordinateShift)
    }
    public static func brakeStopTime(now: Double, lastFrame: Double?, nextFrame: Double?, maximumFPS: Double = 60) -> Double {
        guard let lastFrame, let nextFrame else { return now + 2 / max(maximumFPS, 60) }
        return max(now, nextFrame) + max(nextFrame - lastFrame, 1 / 120)
    }
}