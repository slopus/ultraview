/// One input stream's keyboard displacement. Scroll velocity belongs to its
/// scroller and is never changed by this decision.
struct KeyboardDismissalGesture: Sendable {
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
    private struct Sample: Sendable {
        var time: Double
        var y: Double
    }
    private var geometry: Geometry?
    private var startY = 0.0
    private var samples: [Sample] = []
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
              y < geometry.screenHeight - 44,
              y < geometry.keyboardTop - geometry.accessoryHeight else { return false }
        self.geometry = geometry; startY = y
        samples = [.init(time: time, y: y)]
        return true
    }

    @discardableResult mutating func move(y: Double, time: Double) -> Double? {
        guard let geometry else { return nil }
        sample(y: y, time: time)
        if !isTracking {
            guard abs(y - startY) >= 3 else { return nil }
            isTracking = true
        }
        offset = min(geometry.keyboardHeight, max(0, y + geometry.accessoryHeight - geometry.keyboardTop))
        return offset
    }

    mutating func end(y: Double, time: Double, cancelled: Bool = false) -> Release? {
        guard let geometry else { return nil }
        sample(y: y, time: time)
        self.geometry = nil
        guard isTracking else { return nil }
        isTracking = false
        let passesEdge = y + geometry.accessoryHeight >= geometry.screenHeight - geometry.accessoryHeight
        let dismisses = !cancelled && y > geometry.keyboardTop && (passesEdge || recentVelocity > 500)
        dismissedInTouchSequence = dismisses
        return .init(offset: offset, targetOffset: dismisses ? geometry.keyboardHeight : 0, dismisses: dismisses)
    }

    private var recentVelocity: Double {
        guard let first = samples.first, let last = samples.last, last.time > first.time else { return 0 }
        let cutoff = last.time - 0.1
        var time = first.time, y = first.y
        if first.time < cutoff, samples.count > 1 {
            let next = samples[1]
            if next.time > first.time {
                let fraction = (cutoff - first.time) / (next.time - first.time)
                time = cutoff; y += (next.y - first.y) * fraction
            }
        }
        return (last.y - y) / (last.time - time)
    }

    private mutating func sample(y: Double, time: Double) {
        guard samples.last.map({ time > $0.time }) ?? true else { return }
        samples.append(.init(time: time, y: y))
        while samples.count > 2, samples[1].time <= time - 0.1 { samples.removeFirst() }
        if samples.count > 64 { samples.removeFirst(samples.count - 64) }
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