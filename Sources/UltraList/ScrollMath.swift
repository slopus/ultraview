import Foundation

/// A finite scroll boundary is loaded; an absent boundary can be paged into.
public struct ScrollEdges: Sendable, Equatable, Codable {
    public var minimum: Double?
    public var maximum: Double?
    public init(minimum: Double? = nil, maximum: Double? = nil) {
        self.minimum = minimum
        self.maximum = maximum
    }
    public func clamped(_ value: Double) -> Double {
        let low = minimum ?? -Double.greatestFiniteMagnitude
        return min(max(value, low), max(low, maximum ?? Double.greatestFiniteMagnitude))
    }
    public func contains(_ value: Double) -> Bool { clamped(value) == value }
}

public enum ScrollMath {
    public static func pixelRound(_ value: Double, scale: Double) -> Double {
        guard scale > Double.ulpOfOne else { return value }
        if scale == 1 { return value.rounded(.toNearestOrEven) }
        let base = floor(value)
        return base + ((value - base) * scale).rounded(.toNearestOrEven) / scale
    }
    public static func rubberBand(_ value: Double, edges: ScrollEdges, range: Double, coefficient: Double = 0.55) -> Double {
        guard range > Double.ulpOfOne, coefficient > 0 else { return value }
        let edge = edges.clamped(value)
        let distance = abs(value - edge)
        let band = range * (1 - 1 / (1 + coefficient * distance / range))
        return edge + (value < edge ? -band : band)
    }
    public static func inverseRubberBand(_ value: Double, edges: ScrollEdges, range: Double, coefficient: Double = 0.55) -> Double {
        guard range > Double.ulpOfOne, coefficient > 0 else { return value }
        let edge = edges.clamped(value)
        let band = min(abs(value - edge), range * (1 - 1e-6))
        let distance = range * band / (coefficient * (range - band))
        return edge + (value < edge ? -distance : distance)
    }
    /// Velocity is measured in points per millisecond.
    public static func projectedOffset(_ offset: Double, velocity: Double, rate: Double = 0.998, multiplier: Double = 1) -> Double {
        guard abs(velocity) > 0.01, rate > 0, rate < 1 else { return offset }
        return offset + (velocity < 0 ? -1 : 1) * (abs(velocity) - 0.01) / abs(log(rate)) * multiplier
    }
}

/// One independently owned axis. Offsets retain precision; only returned writes are rounded.
public struct ScrollAxis: Sendable {
    public enum Phase: Sendable { case idle, dragging, decelerating }
    public var edges: ScrollEdges
    public var range: Double
    public var rate: Double
    public var scale: Double
    public var coefficient: Double
    public var multiplier: Double = 1
    public private(set) var offset: Double
    public private(set) var velocity: Double = 0
    public private(set) var phase: Phase = .idle
    private var anchor: Double
    private var proposed: Double
    private var expandedDragRange: Double?
    private var dragRange: Double { max(range, expandedDragRange ?? range) }
    public init(offset: Double = 0, edges: ScrollEdges = .init(), range: Double = 800, rate: Double = 0.998, scale: Double = 1, coefficient: Double = 0.55) {
        precondition(rate > 0 && rate < 1)
        self.offset = offset; self.edges = edges; self.range = range
        self.rate = rate; self.scale = scale; self.coefficient = coefficient
        anchor = offset; proposed = offset
    }
    public mutating func beginDrag() {
        resetDragRange(); anchor = offset; proposed = offset; velocity = 0; phase = .dragging
        reanchorDrag()
    }
    public mutating func drag(translation: Double) {
        proposed = anchor - translation
        offset = ScrollMath.rubberBand(proposed, edges: edges, range: dragRange, coefficient: coefficient)
    }
    public mutating func release(velocity: Double, multiplier: Double = 1) {
        resetDragRange()
        self.velocity = velocity.isFinite ? velocity : 0
        self.multiplier = multiplier; phase = .decelerating
    }
    public mutating func reseed(offset: Double, velocity: Double) {
        self.offset = offset; release(velocity: velocity, multiplier: multiplier)
    }
    public mutating func shift(by delta: Double) { offset += delta; anchor += delta; proposed += delta }
    public mutating func reanchorDrag() {
        guard phase == .dragging else { return }
        let distance = abs(offset - edges.clamped(offset))
        if distance > dragRange * (1 - 1e-6) {
            // A changed edge can put the held content beyond the old band.
            // This gesture needs enough range to represent that same offset.
            expandedDragRange = max(dragRange, distance * 2)
        }
        let replacement = ScrollMath.inverseRubberBand(offset, edges: edges, range: dragRange, coefficient: coefficient)
        anchor += replacement - proposed; proposed = replacement
    }
    mutating func resetDragRange() { expandedDragRange = nil }
    public struct Step: Sendable {
        public var written: Double
        public var settled: Bool
        public var endedDeceleration: Bool
    }
    @discardableResult
    public mutating func step(milliseconds dt: Double) -> Step {
        let wasRunning = phase == .decelerating && (abs(velocity) >= 0.01 || !edges.contains(offset))
        var enteredSpring = false
        if dt > 0, phase == .decelerating {
            if edges.contains(offset) {
                let decay = pow(rate, dt)
                let travel = velocity * rate * (1 - decay) / (1 - rate) * multiplier
                let destination = offset + travel
                if edges.contains(destination) { offset = destination; velocity *= decay }
                else {
                    let boundary = edges.clamped(destination)
                    let coastTime = travel == 0 ? 0 : max(0, min(dt, dt * (boundary - offset) / travel))
                    offset += velocity * rate * (1 - pow(rate, coastTime)) / (1 - rate) * multiplier
                    velocity *= pow(rate, coastTime)
                    spring(milliseconds: dt - coastTime); enteredSpring = true
                }
            } else { spring(milliseconds: dt); enteredSpring = true }
        }
        let settled = abs(velocity) < 0.01 && (edges.contains(offset) || abs(offset - edges.clamped(offset)) <= 0.5)
        if settled { offset = edges.clamped(offset); phase = .idle }
        let ended = wasRunning && (settled || enteredSpring)
        if ended { multiplier = 1 }
        return Step(written: ScrollMath.pixelRound(offset, scale: scale), settled: settled, endedDeceleration: ended)
    }
    private mutating func spring(milliseconds dt: Double) {
        let boundary = edges.clamped(offset), stiffness = pow(0.99, dt), decay = pow(rate, dt)
        offset = boundary + stiffness * (offset - boundary) + velocity * rate * stiffness * (1 - decay) / (1 - rate)
        velocity *= decay * stiffness
    }
}