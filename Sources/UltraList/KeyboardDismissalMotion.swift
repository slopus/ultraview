import Foundation

/// An update is delivered before the keyboard write in the same layout pass.
public struct KeyboardDismissalUpdate: Sendable {
    public enum Phase: Sendable, Equatable { case tracking, returning, dismissing }
    /// Signed keyboard overlap with the client's coordinate view.
    public var height: Double
    public var transition: ListTransition
    public var phase: Phase
    public var isInteractive: Bool = false
}

/// Converts one physical displacement into a viewport correction. The clamp is
/// applied to every sample, so a shorter app view stops at its resting edge at
/// the exact point where the keyboard passes it.
struct KeyboardDismissalMotion: Sendable {
    static let dismissalDuration = 0.3832
    static let returnDuration = 0.25
    static let returnCurve = ListCurve.bezier(0.380, 0.700, 0.125, 1)

    static func releaseTransition(dismisses: Bool) -> ListTransition {
        dismisses ? .keyboard(dismissalDuration) : .init(duration: returnDuration, curve: returnCurve)
    }

    var beginHeight: Double
    var endHeight: Double
    var restingHeight: Double

    func height(at progress: Double) -> Double {
        max(restingHeight, beginHeight + (endHeight - beginHeight) * progress)
    }

    func transition(duration: Double, progress: [Double]) -> ListTransition {
        var transition = ListTransition.keyboard(duration)
        let begin = height(at: 0), distance = height(at: 1) - begin
        if abs(distance) > 1e-6 {
            transition.viewportCurve = ViewportCurve(progress: progress.map { (height(at: $0) - begin) / distance })
        }
        return transition
    }

    static func progress(duration: Double) -> [Double] {
        let final = ListCurve.keyboardSpring.value(at: 1, duration: duration)
        let count = 1920
        return (0...count).map { step in
            if step == 0 { return 0 }
            if step == count { return 1 }
            return ListCurve.keyboardSpring.value(at: Double(step) / Double(count), duration: duration) / final
        }
    }
}