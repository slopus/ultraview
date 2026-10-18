import Testing
@testable import UltraList

struct KeyboardDismissalMotionTests {
    @Test func releasesInterpolateEndpointFramesWithTheSpecifiedSpringOrCubic() {
        let dismissing = KeyboardDismissalMotion.releaseTransition(dismisses: true)
        #expect(dismissing.duration == 0.3832)
        #expect(dismissing.curve == .keyboardSpring)
        #expect(dismissing.viewportCurve == nil)
        let returning = KeyboardDismissalMotion.releaseTransition(dismisses: false)
        #expect(returning.duration == 0.25)
        #expect(returning.curve == .bezier(0.380, 0.700, 0.125, 1))
        #expect(returning.viewportCurve == nil)
        let motion = KeyboardDismissalMotion(beginHeight: 250, endHeight: -80, restingHeight: 20)
        let progress = dismissing.curve.value(at: 0.5, duration: dismissing.duration)
        let interpolated = motion.height(at: 0) + (motion.height(at: 1) - motion.height(at: 0)) * progress
        #expect(interpolated > motion.height(at: progress))
    }

    @Test func bothReleaseDurationsHaveExactEndpointsAndMonotoneProgress() {
        for duration in [0.25, 0.3832] {
            let progress = KeyboardDismissalMotion.progress(duration: duration)
            #expect(progress.count == 1921)
            #expect(progress.first == 0)
            #expect(progress.last == 1)
            #expect(zip(progress, progress.dropFirst()).allSatisfy { $0 <= $1 })
        }
    }

    @Test func theViewportAndPhysicalKeyboardHaveOneValueUntilTheRestingEdge() throws {
        let motion = KeyboardDismissalMotion(beginHeight: 250, endHeight: -80, restingHeight: 20)
        let physical = KeyboardDismissalMotion.progress(duration: 0.3832)
        let transition = motion.transition(duration: 0.3832, progress: physical)
        let curve = try #require(transition.viewportCurve)
        for (index, progress) in physical.enumerated() {
            let physicalHeight = max(20, 250 - 330 * progress)
            let viewportHeight = 250 + (20 - 250) * curve.value(at: Double(index) / Double(physical.count - 1))
            #expect(abs(viewportHeight - physicalHeight) < 1e-10)
        }
        #expect(curve.progress.last == 1)
        #expect(curve.progress.dropLast().contains(1))
    }

    @Test func returnMotionWaitsAtRestUntilTheKeyboardReentersTheView() throws {
        let motion = KeyboardDismissalMotion(beginHeight: -60, endHeight: 250, restingHeight: 20)
        let physical = KeyboardDismissalMotion.progress(duration: 0.25)
        let transition = motion.transition(duration: 0.25, progress: physical)
        let curve = try #require(transition.viewportCurve)
        #expect(curve.progress[1] == 0)
        for (index, progress) in physical.enumerated() {
            let physicalHeight = max(20, -60 + 310 * progress)
            let viewportHeight = 20 + 230 * curve.value(at: Double(index) / Double(physical.count - 1))
            #expect(abs(viewportHeight - physicalHeight) < 1e-10)
        }
    }

    @Test func interpolatingAcrossTheClampedEdgeStaysWithinHalfAPoint() throws {
        for duration in [0.25, 0.3832] {
            for (begin, end) in [(900.0, -100.0), (-100.0, 900.0)] {
                let motion = KeyboardDismissalMotion(beginHeight: begin, endHeight: end, restingHeight: 20)
                let physical = ViewportCurve(progress: KeyboardDismissalMotion.progress(duration: duration))
                let viewport = try #require(motion.transition(duration: duration, progress: physical.progress).viewportCurve)
                for step in 0...10_000 {
                    let phase = Double(step) / 10_000
                    let keyboardHeight = motion.height(at: physical.value(at: phase))
                    let viewportHeight = motion.height(at: 0) + (motion.height(at: 1) - motion.height(at: 0)) * viewport.value(at: phase)
                    #expect(abs(keyboardHeight - viewportHeight) < 0.5)
                }
            }
        }
    }
}