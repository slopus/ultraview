import Foundation

public enum ListCurve: Sendable, Equatable {
    case linear, easeInOut, easeIn, spring, uiKitScroll, smoothDeceleration
    case bezier(Double, Double, Double, Double)
    case dampedSpring(damping: Double)
    case keyboardSpring

    /// Bounds for the whole curve, including a spring's possible overshoot.
    public var progressBounds: ClosedRange<Double> {
        switch self {
        case .bezier(_, let first, _, let second): min(0, first, second)...max(1, first, second)
        case .spring, .dampedSpring, .keyboardSpring: 0...2
        default: 0...1
        }
    }

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
        case .keyboardSpring:
            return Self.spring(time: x * duration, stiffness: 555.027, damping: 47.118)
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

/// Uniformly spaced progress values for the viewport's additive correction.
/// Row size and content animations keep the transition's ordinary curve.
public struct ViewportCurve: Sendable, Equatable {
    public let progress: [Double]
    public init(progress: [Double]) {
        precondition(progress.count >= 2 && progress.first == 0 && progress.last == 1 && progress.allSatisfy(\.isFinite))
        self.progress = progress
    }
    public func value(at phase: Double) -> Double {
        let index = min(1, max(0, phase)) * Double(progress.count - 1)
        let lower = min(progress.count - 2, Int(index)), fraction = index - Double(lower)
        return progress[lower] + (progress[lower + 1] - progress[lower]) * fraction
    }
    var progressBounds: ClosedRange<Double> { progress.min()!...progress.max()! }
}

public struct ListTransition: Sendable, Equatable {
    internal var inheritsDefault = false
    public var duration: Double
    public var curve: ListCurve
    /// Used by an inset-only pass. Other passes use `curve` for every property.
    public var viewportCurve: ViewportCurve?
    public var durationFactor: Double
    public var isImmediate: Bool { duration <= 0 }
    public init(duration: Double, curve: ListCurve = .easeInOut, durationFactor: Double = 1, viewportCurve: ViewportCurve? = nil) {
        self.duration = duration; self.curve = curve; self.durationFactor = durationFactor; self.viewportCurve = viewportCurve
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
    public static func keyboard(_ duration: Double) -> Self { .init(duration: duration, curve: .keyboardSpring) }
    public static func uiKitScroll(_ duration: Double = 0.3) -> Self { .init(duration: duration, curve: .uiKitScroll) }
    public static func smoothDeceleration(_ duration: Double = 1.15) -> Self { .init(duration: duration, curve: .smoothDeceleration) }
    public func scaled(by factor: Double) -> Self {
        .init(duration: duration * factor, curve: curve, durationFactor: durationFactor * factor, viewportCurve: viewportCurve)
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
    var viewportCurve: ViewportCurve? = nil
    public var deadline: Double { startTime + max(0, transition.duration) }
    public var valueBounds: ClosedRange<Double> {
        let bounds = viewportCurve?.progressBounds ?? transition.curve.progressBounds
        let first = from + (to - from) * bounds.lowerBound
        let last = from + (to - from) * bounds.upperBound
        return min(first, last)...max(first, last)
    }
    public func adding(to bounds: ClosedRange<Double>) -> ClosedRange<Double> {
        (bounds.lowerBound + valueBounds.lowerBound)...(bounds.upperBound + valueBounds.upperBound)
    }
    public func value(at time: Double) -> Double {
        if transition.isImmediate || time >= deadline { return to }
        let phase = (time - startTime) / transition.duration
        let progress = viewportCurve?.value(at: phase)
            ?? transition.curve.value(at: phase, duration: transition.duration / transition.durationFactor)
        return from + (to - from) * progress
    }
    func residual(multipliedBy coefficient: Double) -> Self {
        .init(generation: generation, from: (from - to) * coefficient, to: 0,
              startTime: startTime, transition: transition, viewportCurve: viewportCurve)
    }
}

/// Each property is replaced independently; completion always compares generations.
public struct ListAnimationModel: Sendable {
    enum PositionSource: Sendable, Hashable {
        case height(String), layout
    }
    public struct Key: Sendable, Hashable {
        public var owner: AnimationOwner
        public var property: AnimatedProperty
        var positionSource: PositionSource?
        public init(_ owner: AnimationOwner, _ property: AnimatedProperty) { self.owner = owner; self.property = property }
        init(_ owner: AnimationOwner, source: PositionSource) {
            self.owner = owner; property = .positionY; positionSource = source
        }
        var animationKey: String {
            switch positionSource {
            case .height(let identity): "ultraview.list.sizePosition.\(identity)"
            case .layout: "ultraview.list.sizeLayout"
            case nil: "ultraview.list.\(property.rawValue)"
            }
        }
    }
    public private(set) var tracks: [Key: AnimationTrack] = [:]
    private var stored: [Key: Double] = [:]
    public private(set) var generation: UInt64 = 0
    public init() {}
    public func value(_ owner: AnimationOwner, _ property: AnimatedProperty, at time: Double) -> Double {
        baseValue(owner, property, at: time) + (property == .positionY ? positionLayerValue(owner, at: time) : 0)
    }
    func baseValue(_ owner: AnimationOwner, _ property: AnimatedProperty, at time: Double) -> Double {
        let key = Key(owner, property)
        return tracks[key]?.value(at: time) ?? stored[key] ?? (property == .opacity ? 1 : 0)
    }
    func positionLayerValue(_ owner: AnimationOwner, at time: Double) -> Double {
        tracks.reduce(0) { value, entry in
            value + (entry.key.owner == owner && entry.key.positionSource != nil ? entry.value.value(at: time) : 0)
        }
    }
    @discardableResult
    mutating func setPositionLayer(_ owner: AnimationOwner, source: PositionSource, track template: AnimationTrack) -> AnimationTrack {
        let key = Key(owner, source: source)
        if let current = tracks[key], current.from == template.from, current.to == template.to,
           current.startTime == template.startTime, current.transition == template.transition,
           current.viewportCurve == template.viewportCurve { return current }
        generation += 1
        var track = template; track.generation = generation
        tracks[key] = track
        return track
    }
    mutating func removePositionLayers(_ owner: AnimationOwner, except sources: Set<PositionSource>) -> [Key] {
        let keys = tracks.keys.filter { $0.owner == owner && $0.positionSource.map { !sources.contains($0) } == true }
        for key in keys { tracks.removeValue(forKey: key) }
        return keys
    }
    @discardableResult
    public mutating func replace(_ owner: AnimationOwner, _ property: AnimatedProperty, from: Double, to: Double, at time: Double, transition: ListTransition) -> AnimationTrack? {
        generation += 1
        let key = Key(owner, property); stored[key] = to
        guard !transition.isImmediate else { tracks.removeValue(forKey: key); return nil }
        let track = AnimationTrack(generation: generation, from: from, to: to, startTime: time, transition: transition,
                                   viewportCurve: owner == .viewport && property == .viewportOffset ? transition.viewportCurve : nil)
        tracks[key] = track; return track
    }
    /// A settled no-op keeps the old track's phase and generation intact, unless `restarts` asks for a track on this
    /// timing anyway. An immediate change to a key still in flight keeps what remains of its motion on top of the new
    /// value, so keys that moved together keep moving together: an additive delta rides on the new settled value as it
    /// is, and an absolute track moves with its destination unless that would take it below zero. Opacity lands at once.
    @discardableResult
    public mutating func transition(_ owner: AnimationOwner, _ property: AnimatedProperty, old: Double, new: Double, resume: Double? = nil, at time: Double, transition: ListTransition, restarts: Bool = false) -> AnimationTrack? {
        let key = Key(owner, property)
        guard restarts || abs(new - old) > 1e-6 else { return tracks[key] }
        if transition.isImmediate, property != .opacity, let track = tracks[key], time < track.deadline {
            if property.additive { return track }
            let from = track.from + new - track.to
            if min(from, new) >= 0 {
                generation += 1; stored[key] = new
                let moved = AnimationTrack(generation: generation, from: from, to: new, startTime: track.startTime,
                                           transition: track.transition, viewportCurve: track.viewportCurve)
                tracks[key] = moved; return moved
            }
        }
        let current = resume ?? baseValue(owner, property, at: time)
        return replace(owner, property, from: property.additive ? old + current - new : (stored[Key(owner, property)] == nil ? old : current), to: property.additive ? 0 : new, at: time, transition: transition)
    }
    /// Once a pass has started a track (one newer than generation `pass`), restarts every older track still in flight
    /// on the pass's timing `(time, transition)`, from its current value toward the same destination, so all motion
    /// shares one progress. `resume` may supply the current value. Returns the restarted tracks.
    @discardableResult
    public mutating func retime(since pass: UInt64, at time: Double, transition: ListTransition, resume: (Key) -> Double? = { _ in nil }, including include: (Key) -> Bool = { _ in true }) -> [(Key, AnimationTrack)] {
        guard !transition.isImmediate, tracks.values.contains(where: { $0.generation > pass }) else { return [] }
        var restarted: [(Key, AnimationTrack)] = []
        for (key, track) in tracks.sorted(by: { $0.value.generation < $1.value.generation })
        where key.positionSource == nil && track.generation <= pass && time < track.deadline && include(key) {
            let current = resume(key) ?? track.value(at: time)
            if let next = replace(key.owner, key.property, from: current, to: track.to, at: time, transition: transition) { restarted.append((key, next)) }
        }
        return restarted
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