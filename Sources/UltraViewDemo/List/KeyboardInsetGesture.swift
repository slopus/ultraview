/// Tracks only the inset displaced by one interactive keyboard gesture.
/// Resolving the keyboard outcome does not own or stop the scroll motion.
struct KeyboardInsetGesture: Sendable {
    enum Resolution: Equatable, Sendable {
        case returned(inset: Double, height: Double, displacement: Double)
        case dismissed(height: Double)
    }
    private struct Gesture: Sendable {
        var inset: Double
        var height: Double
        var restingHeight: Double
        var latestInset: Double
        var pendingHeight: Double?
    }
    private var gesture: Gesture?
    private(set) var isTracking = false
    var awaitsOutcome: Bool { gesture != nil && !isTracking }
    func recognizesOutcome(height: Double) -> Bool { outcome(height: height) != nil }

    mutating func begin(inset: Double, height: Double, restingHeight: Double) {
        isTracking = true
        gesture = height > restingHeight + 0.5
            ? .init(inset: inset, height: height, restingHeight: restingHeight, latestInset: inset)
            : nil
    }
    @discardableResult mutating func track(inset: Double, height: Double) -> Bool {
        guard isTracking else { return false }
        if let pending = gesture?.pendingHeight, abs(height - pending) <= 0.5 { return false }
        gesture?.latestInset = inset
        return true
    }
    mutating func end(height: Double) -> Resolution? {
        isTracking = false
        guard let gesture else { return nil }
        return resolve(outcome(height: gesture.pendingHeight ?? height))
    }
    mutating func keyboardOutcome(height: Double) -> Resolution? {
        guard gesture != nil else { return nil }
        let result = outcome(height: height)
        if isTracking { gesture?.pendingHeight = height; return nil }
        return resolve(result)
    }
    private func outcome(height: Double) -> Resolution? {
        guard let gesture else { return nil }
        if abs(height - gesture.height) <= 0.5 {
            return .returned(inset: gesture.inset, height: gesture.height, displacement: gesture.inset - gesture.latestInset)
        }
        return height <= gesture.restingHeight + 0.5 ? .dismissed(height: gesture.restingHeight) : nil
    }
    private mutating func resolve(_ result: Resolution?) -> Resolution? {
        guard let result else { return nil }
        gesture = nil
        return result
    }
}