import Foundation

public enum ListCurve: Sendable, Equatable {
    case linear, easeInOut, easeIn, spring, uiKitScroll, smoothDeceleration
    case bezier(Double, Double, Double, Double)
    case dampedSpring(damping: Double)

    public func value(at phase: Double, duration: Double = 0.3) -> Double {
        let x = min(1, max(0, phase))
        switch self {
        case .linear: return x
        case .easeInOut: return Self.solve(x, 0.42, 0, 0.58, 1)
        case .easeIn: return Self.solve(x, 0.42, 0, 1, 1)
        case .uiKitScroll: return Self.solve(x, 0.3643, 0, 0.6357, 1)
        case .bezier(let a, let b, let c, let d): return Self.solve(x, a, b, c, d)
        case .smoothDeceleration:
            let t = x * (2 * Double.pi / 0.6) * 1.6
            return 1 - (1 + t) * exp(-t)
        case .spring:
            if duration == 0.5 || abs(duration - 0.3832) <= 1e-4 {
                return Self.spring(time: x * duration, stiffness: 555.027, damping: 47.118)
            }
            return Self.solve(x, 0.380, 0.700, 0.125, 1)
        case .dampedSpring(let damping):
            return Self.spring(time: x * duration, stiffness: 180, damping: max(0.1, damping))
        }
    }
    /// Closed form of a mass-one oscillator, initially at rest and one unit from its target.
    public static func spring(time: Double, stiffness: Double, damping: Double) -> Double {
        let alpha = damping / 2, omegaSquared = stiffness - alpha * alpha
        if abs(omegaSquared) < 1e-6 { return 1 - (1 + alpha * time) * exp(-alpha * time) }
        if omegaSquared > 0 {
            let omega = sqrt(omegaSquared)
            return 1 - exp(-alpha * time) * (cos(omega * time) + alpha / omega * sin(omega * time))
        }
        let beta = sqrt(-omegaSquared), first = -alpha + beta, second = -alpha - beta
        return 1 - (second * exp(first * time) - first * exp(second * time)) / (second - first)
    }
    private static func solve(_ x: Double, _ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
        func cubic(_ t: Double, _ p: Double, _ q: Double) -> Double {
            3 * (1 - t) * (1 - t) * t * p + 3 * (1 - t) * t * t * q + t * t * t
        }
        var t = x, converged = false
        for _ in 0..<8 {
            let error = cubic(t, a, c) - x
            if abs(error) < 1e-12 { converged = true; break }
            let slope = 3 * (1 - t) * (1 - t) * a + 6 * (1 - t) * t * (c - a) + 3 * t * t * (1 - c)
            if slope == 0 { break }
            let next = t - error / slope
            if !next.isFinite || next < 0 || next > 1 { break }
            t = next
        }
        if !converged {
            var low = 0.0, high = 1.0
            for _ in 0..<60 { t = (low + high) / 2; if cubic(t, a, c) < x { low = t } else { high = t } }
        }
        return cubic(t, b, d)
    }
}

public struct ListTransition: Sendable, Equatable {
    internal var inheritsDefault = false
    public var duration: Double
    public var curve: ListCurve
    public var durationFactor: Double
    public var isImmediate: Bool { duration <= 0 }
    public init(duration: Double, curve: ListCurve = .easeInOut, durationFactor: Double = 1) {
        self.duration = duration; self.curve = curve; self.durationFactor = durationFactor
    }
    public static let immediate = ListTransition(duration: 0)
    public static let none = immediate
    public static let `default`: ListTransition = {
        var value = ListTransition.immediate; value.inheritsDefault = true; return value
    }()
    public static func easeInOut(_ duration: Double) -> Self { .init(duration: duration) }
    public static func spring(_ duration: Double) -> Self { .init(duration: duration, curve: .spring) }
    public static func spring(_ duration: Double, damping: Double) -> Self {
        .init(duration: duration, curve: .dampedSpring(damping: damping))
    }
    public static func uiKitScroll(_ duration: Double = 0.3) -> Self { .init(duration: duration, curve: .uiKitScroll) }
    public static func smoothDeceleration(_ duration: Double = 1.15) -> Self { .init(duration: duration, curve: .smoothDeceleration) }
    public func scaled(by factor: Double) -> Self {
        .init(duration: duration * factor, curve: curve, durationFactor: durationFactor * factor)
    }
}

public enum AnimationOwner: Sendable, Hashable {
    case viewport, row(String), attachment(UInt64), exit(UInt64), carry(UInt64), block(UInt64)
}
public enum AnimatedProperty: String, Sendable, CaseIterable {
    case viewportOffset, positionX, positionY, width, height, opacity
    public var additive: Bool { self == .viewportOffset || self == .positionX || self == .positionY }
    public var keyPath: String {
        switch self {
        case .viewportOffset: "bounds.origin.y"
        case .positionX: "position.x"
        case .positionY: "position.y"
        case .width: "bounds.size.width"
        case .height: "bounds.size.height"
        case .opacity: "opacity"
        }
    }
}
public struct AnimationTrack: Sendable, Equatable {
    public var generation: UInt64
    public var from: Double
    public var to: Double
    public var startTime: Double
    public var transition: ListTransition
    public var deadline: Double { startTime + max(0, transition.duration) }
    public func value(at time: Double) -> Double {
        if transition.isImmediate || time >= deadline { return to }
        let progress = transition.curve.value(at: (time - startTime) / transition.duration, duration: transition.duration / transition.durationFactor)
        return from + (to - from) * progress
    }
}

/// Each property is replaced independently; completion always compares generations.
public struct ListAnimationModel: Sendable {
    public struct Key: Sendable, Hashable {
        public var owner: AnimationOwner
        public var property: AnimatedProperty
        public init(_ owner: AnimationOwner, _ property: AnimatedProperty) { self.owner = owner; self.property = property }
    }
    public private(set) var tracks: [Key: AnimationTrack] = [:]
    private var stored: [Key: Double] = [:]
    private var generation: UInt64 = 0
    public init() {}
    public func value(_ owner: AnimationOwner, _ property: AnimatedProperty, at time: Double) -> Double {
        let key = Key(owner, property)
        return tracks[key]?.value(at: time) ?? stored[key] ?? (property == .opacity ? 1 : 0)
    }
    @discardableResult
    public mutating func replace(_ owner: AnimationOwner, _ property: AnimatedProperty, from: Double, to: Double, at time: Double, transition: ListTransition) -> AnimationTrack? {
        generation += 1
        let key = Key(owner, property); stored[key] = to
        guard !transition.isImmediate else { tracks.removeValue(forKey: key); return nil }
        let track = AnimationTrack(generation: generation, from: from, to: to, startTime: time, transition: transition)
        tracks[key] = track; return track
    }
    /// A settled no-op keeps the old track's phase and generation intact.
    @discardableResult
    public mutating func transition(_ owner: AnimationOwner, _ property: AnimatedProperty, old: Double, new: Double, resume: Double? = nil, at time: Double, transition: ListTransition) -> AnimationTrack? {
        guard abs(new - old) > 1e-6 else { return tracks[Key(owner, property)] }
        let current = resume ?? value(owner, property, at: time)
        return replace(owner, property, from: property.additive ? old + current - new : (stored[Key(owner, property)] == nil ? old : current), to: property.additive ? 0 : new, at: time, transition: transition)
    }
    @discardableResult
    public mutating func finish(_ key: Key, generation: UInt64) -> Bool {
        guard tracks[key]?.generation == generation else { return false }
        tracks.removeValue(forKey: key); return true
    }
    public mutating func remove(_ owner: AnimationOwner) {
        tracks = tracks.filter { $0.key.owner != owner }; stored = stored.filter { $0.key.owner != owner }
    }
    public func completed(at time: Double) -> [(Key, UInt64)] {
        tracks.compactMap { time >= $0.value.deadline ? ($0.key, $0.value.generation) : nil }
    }
    public func contains(_ owner: AnimationOwner) -> Bool { stored.keys.contains { $0.owner == owner } }
    public func hasTracks(_ owner: AnimationOwner) -> Bool { tracks.keys.contains { $0.owner == owner } }
}