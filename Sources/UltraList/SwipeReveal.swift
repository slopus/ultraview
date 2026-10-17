import Foundation

/// The axis a gesture moves along.
public enum GestureAxis: Sendable, Equatable { case horizontal, vertical }

/// Decides once per gesture which axis owns it: the dominant one at the first
/// movement past `slop` from the touch-down point. A tie goes to the vertical
/// axis, the list's own. Later movement never changes a decision.
public struct AxisLock: Sendable, Equatable {
    public static let defaultSlop = 10.0
    public let slop: Double
    public private(set) var axis: GestureAxis?
    public init(slop: Double = AxisLock.defaultSlop) { self.slop = slop }
    /// The axis for a translation from touch-down, or nil while it stays within the slop.
    public static func decide(dx: Double, dy: Double, slop: Double = defaultSlop) -> GestureAxis? {
        guard dx * dx + dy * dy > slop * slop else { return nil }
        return abs(dx) > abs(dy) ? .horizontal : .vertical
    }
    @discardableResult
    public mutating func update(dx: Double, dy: Double) -> GestureAxis? {
        if axis == nil { axis = Self.decide(dx: dx, dy: dy, slop: slop) }
        return axis
    }
    /// Decides with whatever has moved, for a recognizer that must answer now.
    public mutating func force(dx: Double, dy: Double) -> GestureAxis {
        if let axis { return axis }
        let forced: GestureAxis = abs(dx) > abs(dy) ? .horizontal : .vertical
        axis = forced
        return forced
    }
}

/// Where a revealed row comes to rest when the finger lifts.
public enum SwipeOutcome: Int, Sendable, Comparable {
    case closed, open, fullSwipe
    public static func < (a: SwipeOutcome, b: SwipeOutcome) -> Bool { a.rawValue < b.rawValue }
}

/// The geometry of one side's action buttons. Distances are measured from the
/// row edge the buttons are attached to; the first action is the edge-most one.
public struct SwipeRevealLayout: Sendable, Equatable {
    public var widths: [Double]
    public var rowWidth: Double
    public var allowsFullSwipe: Bool
    public static let rubberBandCoefficient = 0.55
    public static let fullSwipeMargin = 48.0
    public static let fullSwipeFraction = 0.55
    public init(widths: [Double], rowWidth: Double, allowsFullSwipe: Bool) {
        self.widths = widths; self.rowWidth = rowWidth; self.allowsFullSwipe = allowsFullSwipe
    }
    public var openWidth: Double { widths.reduce(0, +) }
    /// Past this reveal a release performs the edge-most action. Nil when the
    /// row can't be swiped that far.
    public var fullSwipeThreshold: Double? {
        guard allowsFullSwipe, !widths.isEmpty else { return nil }
        let threshold = max(openWidth + Self.fullSwipeMargin, rowWidth * Self.fullSwipeFraction)
        return threshold < rowWidth ? threshold : nil
    }
    /// Where the content follows the finger 1:1; beyond it the motion rubber-bands.
    public var trackingLimit: Double { fullSwipeThreshold == nil ? openWidth : rowWidth }
    /// The shown reveal for a finger-driven one.
    public func displayed(_ proposed: Double) -> Double {
        guard !widths.isEmpty else { return 0 }
        let value = max(0, proposed)
        return ScrollMath.rubberBand(value, edges: .init(minimum: 0, maximum: trackingLimit), range: max(rowWidth, 1), coefficient: Self.rubberBandCoefficient)
    }
    /// Inverse of `displayed`, for catching a row in motion.
    public func proposed(_ displayed: Double) -> Double {
        guard !widths.isEmpty else { return 0 }
        return ScrollMath.inverseRubberBand(max(0, displayed), edges: .init(minimum: 0, maximum: trackingLimit), range: max(rowWidth, 1), coefficient: Self.rubberBandCoefficient)
    }
    public func isExpanded(_ reveal: Double) -> Bool { fullSwipeThreshold.map { reveal >= $0 } ?? false }
    /// Each button's span of distances from the edge. Every span is linear in
    /// `reveal`, so one spring on the reveal moves all of them consistently.
    /// Expanded, the edge-most button covers the whole revealed area.
    public func spans(reveal: Double, expanded: Bool) -> [ClosedRange<Double>] {
        let total = openWidth
        guard total > 0 else { return [] }
        var result: [ClosedRange<Double>] = []
        var cumulative = 0.0
        for width in widths {
            let outer = reveal * cumulative / total
            cumulative += width
            result.append(outer...(reveal * cumulative / total))
        }
        if expanded { result[0] = 0...reveal }
        return result
    }
    /// The resting reveal for an outcome.
    public func target(_ outcome: SwipeOutcome) -> Double {
        switch outcome {
        case .closed: 0
        case .open: openWidth
        case .fullSwipe: rowWidth
        }
    }
}

public enum SwipeRelease {
    /// Seconds of release velocity added to the reveal before comparing with half the open width.
    public static let projection = 0.12
    /// Velocity is in points per second, positive while opening. Monotone in
    /// both `reveal` and `velocity`: more of either never gives a lower outcome.
    public static func decide(reveal: Double, velocity: Double, openWidth: Double, fullSwipeThreshold: Double?) -> SwipeOutcome {
        guard openWidth > 0 else { return .closed }
        if let fullSwipeThreshold, reveal >= fullSwipeThreshold { return .fullSwipe }
        return reveal + velocity * projection >= openWidth / 2 ? .open : .closed
    }
}

/// A reveal moving toward rest on a `ListTransition`. Spring curves start with
/// the finger's velocity, limited so that a non-oscillating spring never passes
/// its target and so comes to rest exactly on it. Other curves start at rest.
public struct SwipeMotion: Sendable, Equatable {
    public struct Spring: Sendable, Equatable {
        public var stiffness: Double
        public var damping: Double
        /// Spring seconds per second of real time.
        public var speed: Double
        /// Spring seconds the motion runs for.
        public var duration: Double
    }
    public var from: Double
    public var to: Double
    public var transition: ListTransition
    /// Points per second of real time, after limiting; zero for curves that aren't springs.
    public private(set) var velocity: Double
    public init(from: Double, to: Double, velocity: Double, transition: ListTransition) {
        self.from = from; self.to = to; self.transition = transition
        self.velocity = 0
        guard let spring = Self.spring(for: transition), velocity.isFinite else { return }
        let displacement = from - to
        let alpha = spring.damping / 2, discriminant = alpha * alpha - spring.stiffness
        // The slowest decay rate in spring time: approaching faster than it overshoots.
        var limited = velocity / spring.speed
        if discriminant >= -1e-3 * spring.stiffness {
            let rate = alpha + max(0, discriminant).squareRoot()
            if displacement > 0 { limited = max(limited, -rate * displacement) }
            else if displacement < 0 { limited = min(limited, -rate * displacement) }
            else { limited = 0 }
        }
        self.velocity = limited * spring.speed
    }
    /// The spring Core Animation runs for a transition, matching the list's own compilation.
    public static func spring(for transition: ListTransition) -> Spring? {
        guard !transition.isImmediate else { return nil }
        let logical = transition.duration / transition.durationFactor
        switch transition.curve {
        case .dampedSpring(let damping):
            return Spring(stiffness: 180, damping: max(0.1, damping), speed: 1 / transition.durationFactor, duration: logical)
        case .keyboardSpring:
            return Spring(stiffness: 555.027, damping: 47.118, speed: 1 / transition.durationFactor, duration: logical)
        case .spring where logical == 0.5 || abs(logical - 0.3832) <= 1e-4:
            return Spring(stiffness: 555.027, damping: 47.118, speed: 1 / transition.durationFactor, duration: logical)
        case .smoothDeceleration:
            let omega = 2 * Double.pi / 0.6
            return Spring(stiffness: omega * omega, damping: 2 * omega, speed: 1.6 / transition.duration, duration: 1.6)
        default:
            return nil
        }
    }
    /// Real seconds until the motion ends.
    public var duration: Double {
        guard let spring = Self.spring(for: transition) else { return max(0, transition.duration) }
        return spring.duration / spring.speed
    }
    /// Core Animation's spring velocity: target distances per spring second.
    public var normalizedVelocity: Double {
        guard let spring = Self.spring(for: transition), from != to else { return 0 }
        return velocity / spring.speed / (to - from)
    }
    public func value(at time: Double) -> Double {
        guard time > 0 else { return from }
        guard time < duration else { return to }
        guard let spring = Self.spring(for: transition) else {
            return from + (to - from) * transition.curve.value(at: time / transition.duration, duration: transition.duration / transition.durationFactor)
        }
        let t = time * spring.speed, x0 = from - to, v0 = velocity / spring.speed
        let alpha = spring.damping / 2, omegaSquared = spring.stiffness - alpha * alpha
        let displacement: Double
        if abs(omegaSquared) < 1e-6 {
            displacement = (x0 + (v0 + alpha * x0) * t) * exp(-alpha * t)
        } else if omegaSquared > 0 {
            let omega = omegaSquared.squareRoot()
            displacement = exp(-alpha * t) * (x0 * cos(omega * t) + (v0 + alpha * x0) / omega * sin(omega * t))
        } else {
            let beta = (-omegaSquared).squareRoot(), fast = -alpha - beta, slow = -alpha + beta
            let slowWeight = (v0 - fast * x0) / (slow - fast)
            displacement = slowWeight * exp(slow * t) + (x0 - slowWeight) * exp(fast * t)
        }
        return to + displacement
    }
}

/// At most one row is revealed: starting another closes the current one.
public struct SwipeRegistry<Identity: Hashable & Sendable>: Sendable {
    public private(set) var active: Identity?
    public init() {}
    /// Makes `identity` the revealed row; returns the row that must close.
    public mutating func begin(_ identity: Identity) -> Identity? {
        let closing = active == identity ? nil : active
        active = identity
        return closing
    }
    public mutating func settle(_ identity: Identity, outcome: SwipeOutcome) {
        if active == identity, outcome == .closed { active = nil }
    }
    public mutating func remove(_ identity: Identity) { if active == identity { active = nil } }
}

/// Coordinates of a horizontal list. Its inner vertical list runs along screen
/// x: transposed left to right, or turned a quarter clockwise for right to left.
public enum HorizontalListGeometry {
    /// A rectangle in the inner list's space, as shown on screen. `length` is
    /// the screen width, the inner list's height.
    public static func screenRect(x: Double, y: Double, width: Double, height: Double, length: Double, rightToLeft: Bool) -> (x: Double, y: Double, width: Double, height: Double) {
        rightToLeft ? (length - y - height, x, height, width) : (y, x, height, width)
    }
}
