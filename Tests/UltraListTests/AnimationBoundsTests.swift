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
    @Test func viewportSamplesKeepTheirHoldsAndBoundsWithoutChangingRowTiming() throws {
        let curve = ViewportCurve(progress: [0, 0, 0.5, 1.1, 1])
        let transition = ListTransition(duration: 1, curve: .linear, viewportCurve: curve)
        var model = ListAnimationModel()
        let viewportTrack = model.replace(.viewport, .viewportOffset, from: -252, to: 0, at: 10, transition: transition)
        let rowTrack = model.replace(.row("a"), .height, from: 100, to: 200, at: 10, transition: transition)
        let viewport = try #require(viewportTrack), row = try #require(rowTrack)
        #expect(viewport.value(at: 10.125) == -252)
        #expect(viewport.value(at: 10.375) == -189)
        #expect(abs(viewport.value(at: 10.75) - 25.2) < 1e-9)
        #expect(viewport.value(at: 11) == 0)
        #expect(abs(viewport.valueBounds.upperBound - 25.2) < 1e-9)
        #expect(viewport.valueBounds.lowerBound == -252)
        #expect(row.value(at: 10.125) == 112.5)
        #expect(row.viewportCurve == nil)
        let scaledTrack = model.replace(.viewport, .viewportOffset, from: -252, to: 0, at: 10, transition: transition.scaled(by: 2))
        let scaled = try #require(scaledTrack)
        #expect(scaled.value(at: 10.75) == viewport.value(at: 10.375))
        #expect(scaled.deadline == 12)
        for frame in 0...240 {
            #expect(viewport.valueBounds.contains(viewport.value(at: 10 + Double(frame) / 240)))
        }
    }
}