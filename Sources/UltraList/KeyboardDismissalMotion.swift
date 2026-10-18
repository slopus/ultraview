import Foundation

/// An update is delivered inside the same transaction that moves the keyboard.
public struct KeyboardDismissalUpdate: Sendable {
    public enum Phase: Sendable, Equatable { case tracking, returning, dismissing }
    /// Keyboard overlap with the client's coordinate view, clamped to its resting inset.
    public var height: Double
    public var transition: ListTransition
    public var phase: Phase
}

/// Converts one physical displacement into a viewport correction. The clamp is
/// applied to every sample, so a shorter app view stops at its resting edge at
/// the exact point where the keyboard passes it.
struct KeyboardDismissalMotion: Sendable {
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