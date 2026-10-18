import Testing
import UltraView
@testable import UltraViewDemo

@Suite struct KeyboardViewportMotionTests {
    @Test func fullTravelClampsAtTheChatBoundaryInBothDirections() throws {
        let samples = (0...20).map { Double($0) / 20 }
        let show = KeyboardViewportMotion(beginHeight: -83, endHeight: 252, restingHeight: 0)
        let hide = KeyboardViewportMotion(beginHeight: 252, endHeight: -83, restingHeight: 0)
        let showing = try #require(show.viewportCurve(physicalProgress: samples))
        let hiding = try #require(hide.viewportCurve(physicalProgress: samples))
        #expect(showing.value(at: 0.2) == 0)
        #expect(hiding.value(at: 0.8) == 1)
        for step in 0...20 {
            let phase = Double(step) / 20
            let showingKeyboardTop = 844 - 335 * phase
            let hidingKeyboardTop = 509 + 335 * phase
            let showingBarBottom = 753 - 252 * showing.value(at: phase)
            let hidingBarBottom = 501 + 252 * hiding.value(at: phase)
            #expect(abs(showingBarBottom + 8 - min(761, showingKeyboardTop)) < 1e-9)
            #expect(abs(hidingBarBottom + 8 - min(761, hidingKeyboardTop)) < 1e-9)
        }
    }

    @Test func aSafeAreaAndAPartialStartUseTheirActualClampedDistance() throws {
        let motion = KeyboardViewportMotion(beginHeight: 150, endHeight: -50, restingHeight: 34)
        let curve = try #require(motion.viewportCurve(physicalProgress: [0, 0.25, 0.5, 0.75, 1]))
        #expect(abs(curve.value(at: 0.5) - 100.0 / 116) < 1e-9)
        #expect(curve.value(at: 0.75) == 1)
        #expect(KeyboardViewportMotion(beginHeight: -83, endHeight: -10, restingHeight: 0)
            .viewportCurve(physicalProgress: [0, 1]) == nil)
    }

    @Test func sampledOrdinarySpringTravelStaysWithinOnePointOfThePhysicalEdge() throws {
        // The fitted keyboard clock and a longer clock. Gesture return
        // clocks resolve separately and do not use this profile.
        for duration in [0.3833333333333333, 0.5] {
            let samples = (0...480).map { step in
                step == 480 ? 1 : ListCurve.keyboardSpring.value(at: Double(step) / 480, duration: duration)
            }
            for (begin, end) in [(-83.0, 252.0), (252.0, -83.0)] {
                let motion = KeyboardViewportMotion(beginHeight: begin, endHeight: end, restingHeight: 0)
                let curve = try #require(motion.viewportCurve(physicalProgress: samples))
                for step in 0...10_000 {
                    let phase = Double(step) / 10_000
                    let physical = step == 10_000 ? 1 : ListCurve.keyboardSpring.value(at: phase, duration: duration)
                    let actual = motion.height(at: 0) + (motion.height(at: 1) - motion.height(at: 0)) * curve.value(at: phase)
                    #expect(abs(actual - motion.height(at: physical)) < 1,
                            "duration \(duration), start \(begin), phase \(phase): sampled clamp must follow the physical edge")
                }
            }
        }
    }
}