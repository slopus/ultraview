#if canImport(UIKit)
import UIKit

@MainActor
enum KeyboardDismissalAnimation {
    /// An undocumented, optional refresh hint; systems may ignore it.
    static let frameRateHint = (key: "highFrameRateReason", value: 1_048_619)

    static func make(dismisses: Bool, from offset: Double, to target: Double,
                     durationScale: Double, maximumFramesPerSecond: Int) -> CABasicAnimation {
        let animation: CABasicAnimation
        if dismisses {
            let spring = CASpringAnimation(keyPath: "bounds.origin.y")
            spring.mass = 1; spring.stiffness = 555.027; spring.damping = 47.118
            spring.initialVelocity = 0; spring.allowsOverdamping = false
            spring.timingFunction = CAMediaTimingFunction(name: .linear)
            spring.preferredFrameRateRange = .init(minimum: 80, maximum: 120, preferred: 120)
            spring.setValue(frameRateHint.value, forKey: frameRateHint.key)
            animation = spring
        } else {
            animation = CABasicAnimation(keyPath: "bounds.origin.y")
            animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.380, 0.700, 0.125, 1)
        }
        if maximumFramesPerSecond > 61 {
            let maximum = Float(maximumFramesPerSecond)
            animation.preferredFrameRateRange = .init(minimum: 30, maximum: maximum, preferred: maximum)
        }
        animation.duration = dismisses ? KeyboardDismissalMotion.dismissalDuration : KeyboardDismissalMotion.returnDuration
        animation.speed = Float(1 / max(0.001, durationScale))
        animation.isAdditive = true
        animation.fromValue = target - offset; animation.toValue = 0
        animation.fillMode = .forwards; animation.isRemovedOnCompletion = true
        return animation
    }
}
#endif