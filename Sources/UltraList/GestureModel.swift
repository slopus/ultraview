import Foundation

public struct ScrollVector: Sendable, Equatable, Codable {
    public var x: Double
    public var y: Double
    public init(x: Double = 0, y: Double = 0) { self.x = x; self.y = y }
    public var magnitudeSquared: Double { x * x + y * y }
    public static let zero = ScrollVector()
}

/// Gesture history belongs to the input stream, independently of axis rebuilds.
public struct ReleaseDecision: Sendable {
    public static let minimumDecelerationSpeed = 250.0
    public private(set) var latest = ScrollVector.zero
    public private(set) var previous = ScrollVector.zero
    public private(set) var streakCount = 0
    public private(set) var multiplier: Double = 1
    private var startMultiplier: Double = 1
    private var lastRelease: Double?
    private var lastSign: Bool?
    public init() {}
    public mutating func touchDown(at time: Double) {
        previous = .zero
        if let lastRelease, time - lastRelease > 1 { resetStreak() }
        startMultiplier = multiplier
    }
    public mutating func beginGesture() { latest = .zero; previous = .zero; lastSign = nil }
    public mutating func sample(velocity: ScrollVector, translation: ScrollVector) {
        previous = latest
        latest = ScrollVector(x: -velocity.x * 0.001, y: -velocity.y * 0.001)
        if latest.y != 0 {
            let sign = latest.y > 0
            if lastSign.map({ $0 != sign }) == true || latest.magnitudeSquared < 0.0169 { resetStreak() }
            lastSign = sign
        }
        if streakCount >= 3 {
            let distance = Double(sqrt(Float(translation.magnitudeSquared)))
            multiplier = min(16, startMultiplier + (1 + Double(streakCount - 3) / 2) * min(distance / 240, 0.9))
        }
    }
    public struct Release: Sendable {
        public var decelerates: Bool
        public var velocity: ScrollVector
        public var multiplier: Double
    }
    public mutating func release(recognizerVelocity: ScrollVector, at time: Double) -> Release {
        if recognizerVelocity == .zero { latest = .zero }
        let magnitude = latest.magnitudeSquared
        let threshold = Self.minimumDecelerationSpeed * 0.001
        guard magnitude >= threshold * threshold else {
            latest = .zero; previous = .zero; resetStreak()
            return Release(decelerates: false, velocity: .zero, multiplier: 1)
        }
        if magnitude < 0.36 { resetStreak() } else { streakCount += 1; lastRelease = time }
        if previous != .zero {
            latest = ScrollVector(x: previous.x * 0.75 + latest.x * 0.25, y: previous.y * 0.75 + latest.y * 0.25)
        }
        return Release(decelerates: true, velocity: latest, multiplier: multiplier)
    }
    public mutating func resetStreak() { streakCount = 0; multiplier = 1 }
}

/// Touch-centroid oracle. Production uses the platform recognizer.
public struct PanModel: Sendable {
    public private(set) var recognized = false
    public private(set) var translation = ScrollVector.zero
    public private(set) var velocity = ScrollVector.zero
    private var start = ScrollVector.zero
    private var reference = ScrollVector.zero
    private var hysteresis = ScrollVector.zero
    private var time: Double = 0
    private var sampleVelocity = ScrollVector.zero
    private var sampleDuration: Double = 0
    public init() {}
    public mutating func begin(at point: ScrollVector, time: Double) {
        self = PanModel(); start = point; reference = point; self.time = time
    }
    public mutating func move(to point: ScrollVector, time: Double) {
        let dt = time - self.time
        if dt > 0 {
            let next = ScrollVector(x: (point.x - reference.x) / dt, y: (point.y - reference.y) / dt)
            let weight = sampleDuration > pow(2, -23) ? 0.8 : 0
            velocity = ScrollVector(x: next.x * 0.2 + sampleVelocity.x * weight, y: next.y * 0.2 + sampleVelocity.y * weight)
            sampleVelocity = next; sampleDuration = dt; reference = point; self.time = time
        }
        let dx = point.x - start.x, dy = point.y - start.y
        if !recognized, dx * dx + dy * dy > 100 {
            recognized = true
            hysteresis = ScrollVector(x: min(10, max(-10, dx)), y: min(10, max(-10, dy)))
        }
        if recognized { translation = ScrollVector(x: dx - hysteresis.x, y: dy - hysteresis.y) }
    }
}