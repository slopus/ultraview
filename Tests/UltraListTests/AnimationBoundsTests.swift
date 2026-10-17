import Testing
@testable import UltraList

@Suite struct AnimationBoundsTests {
    @Test func boundsIncludeSpringAndBezierOvershoot() {
        let transitions: [ListTransition] = [
            .init(duration: 1, curve: .linear), .easeInOut(1), .spring(0.5), .spring(0.7),
            .spring(1, damping: 0.1), .spring(1, damping: 40), .keyboard(0.35),
            .init(duration: 1, curve: .bezier(0.3, -1, 0.7, 1.5)),
        ]
        for transition in transitions {
            let track = AnimationTrack(generation: 1, from: -252, to: 0, startTime: 10, transition: transition)
            for step in 0...240 {
                let value = track.value(at: 10 + transition.duration * Double(step) / 240)
                #expect(value >= track.valueBounds.lowerBound - 1e-9 && value <= track.valueBounds.upperBound + 1e-9)
            }
        }
    }
    @Test func boundsUseBezierVerticalControlsAndTrackDirection() {
        #expect(ListCurve.bezier(-10, -1, 10, 1.5).progressBounds == -1...1.5)
        let transition = ListTransition.spring(1, damping: 5)
        #expect(AnimationTrack(generation: 1, from: -252, to: 0, startTime: 0, transition: transition).valueBounds == -252...252)
        #expect(AnimationTrack(generation: 1, from: 252, to: 0, startTime: 0, transition: transition).valueBounds == -252...252)
    }
    @Test func simultaneousScrollAndViewportMotionAddTheirExtents() {
        let transition = ListTransition(duration: 1, curve: .linear)
        let forward = AnimationTrack(generation: 1, from: 252, to: 0, startTime: 0, transition: transition)
        let reverse = AnimationTrack(generation: 1, from: -252, to: 0, startTime: 0, transition: transition)
        #expect(forward.adding(to: 0...100) == 0...352)
        #expect(reverse.adding(to: -100...0) == -352...0)
    }
}