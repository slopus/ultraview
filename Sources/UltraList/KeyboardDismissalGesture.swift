/// One input stream's keyboard displacement. Scroll velocity belongs to its
/// scroller and is never changed by this decision.
struct KeyboardDismissalGesture: Sendable {
    static let movementThreshold = 3.0
    static let reservedBottomHeight = 44.0
    static let velocitySampleLimit = 6
    static let velocityWindow = 0.1
    static let velocityDivisor = 5.0
    static let dismissalVelocity = 100.0

    struct Geometry: Sendable, Equatable {
        var screenHeight: Double
        var keyboardTop: Double
        var accessoryHeight: Double
        var keyboardHeight: Double { max(0, screenHeight - keyboardTop) }
    }
    struct Release: Sendable, Equatable {
        var offset: Double
        var targetOffset: Double
        var dismisses: Bool
    }
    struct Tracking: Sendable, Equatable {
        var boundary: Double
        var offset: Double
    }
    private struct Sample: Sendable {
        var time: Double
        var y: Double
    }
    private var geometry: Geometry?
    private var startY = 0.0
    private var samples: [Sample] = []
    private var committedBoundary: Double?
    private(set) var isTracking = false
    private(set) var offset = 0.0
    private(set) var dismissedInTouchSequence = false

    mutating func beginTouchSequence() { dismissedInTouchSequence = false }

    mutating func cancelTracking() {
        let dismissed = dismissedInTouchSequence
        self = .init()
        dismissedInTouchSequence = dismissed
    }

    mutating func begin(y: Double, time: Double, geometry: Geometry, hasFirstResponder: Bool) -> Bool {
        self = .init()
        guard hasFirstResponder, geometry.keyboardHeight > 0,
              y <= geometry.screenHeight - Self.reservedBottomHeight,
              y < geometry.keyboardTop - geometry.accessoryHeight else { return false }
        self.geometry = geometry; startY = y
        samples = [.init(time: time, y: y)]
        return true
    }

    @discardableResult mutating func move(y: Double, time: Double) -> Tracking? {
        guard let geometry else { return nil }
        sample(y: y, time: time)
        guard committedBoundary != nil || abs(y - startY) >= Self.movementThreshold else { return nil }
        isTracking = true
        let boundary = y + geometry.accessoryHeight
        return .init(boundary: boundary, offset: max(0, boundary - geometry.keyboardTop))
    }

    /// Window geometry can change while the accessory remains captured.
    mutating func updateGeometry(screenHeight: Double, keyboardTop: Double) {
        guard var geometry else { return }
        geometry.screenHeight = screenHeight; geometry.keyboardTop = keyboardTop
        self.geometry = geometry
    }

    mutating func commit(_ tracking: Tracking) {
        guard geometry != nil else { return }
        committedBoundary = tracking.boundary
        offset = tracking.offset
    }

    mutating func end(y: Double, time: Double, cancelled: Bool = false) -> Release? {
        guard let geometry else { return nil }
        if !cancelled { sample(y: y, time: time) }
        self.geometry = nil
        isTracking = false
        let passesEdge = committedBoundary.map { $0 >= geometry.screenHeight - geometry.accessoryHeight } ?? false
        let velocity = cancelled ? 0 : estimatedVelocity(at: time)
        let dismisses = y + geometry.accessoryHeight > geometry.keyboardTop
            && (passesEdge || velocity > Self.dismissalVelocity)
        dismissedInTouchSequence = dismisses
        return .init(offset: offset, targetOffset: dismisses ? geometry.keyboardHeight : 0, dismisses: dismisses)
    }

    func estimatedVelocity(at time: Double) -> Double {
        // Callback times and whole pairs are retained, including equal timestamps.
        let slopes = zip(samples, samples.dropFirst()).compactMap { first, second -> Double? in
            guard second.time >= time - Self.velocityWindow else { return nil }
            return (second.y - first.y) / (second.time - first.time)
        }
        guard !slopes.isEmpty else { return 0 }
        return slopes.reduce(0, +) / Double(slopes.count) / Self.velocityDivisor
    }

    private mutating func sample(y: Double, time: Double) {
        samples.append(.init(time: time, y: y))
        if samples.count > Self.velocitySampleLimit { samples.removeFirst(samples.count - Self.velocitySampleLimit) }
    }
}

/// The first touch owns a gesture; additional fingers cannot reset or end it.
struct KeyboardPrimaryTouch: Sendable {
    private var identity: ObjectIdentifier?
    var isActive: Bool { identity != nil }
    mutating func begin(_ identity: ObjectIdentifier) -> Bool {
        guard self.identity == nil else { return false }
        self.identity = identity
        return true
    }
    func matches(_ identity: ObjectIdentifier) -> Bool { self.identity == identity }
    mutating func end(_ identity: ObjectIdentifier) -> Bool {
        guard matches(identity) else { return false }
        self.identity = nil
        return true
    }
}