import Foundation
import Testing
@testable import UltraList

@Suite struct ScrollPhysicsTests {
    @Test(arguments: [(10.3, 2.0, 10.5), (10.25, 2, 10), (10.75, 2, 11), (0.5, 1, 0), (-10.25, 2, -10), (5.25, 0, 5.25)])
    func rounding(value: Double, scale: Double, expected: Double) {
        #expect(ScrollMath.pixelRound(value, scale: scale) == expected)
    }
    @Test(arguments: [0.55, 0.715]) func bandRoundTrip(coefficient: Double) {
        let edges = ScrollEdges(minimum: 0, maximum: 1000)
        for value in stride(from: -400.0, through: 1400, by: 7) {
            let banded = ScrollMath.rubberBand(value, edges: edges, range: 844, coefficient: coefficient)
            #expect(abs(ScrollMath.inverseRubberBand(banded, edges: edges, range: 844, coefficient: coefficient) - value) < 1e-6)
        }
        #expect(ScrollMath.rubberBand(900, edges: .init(), range: 844) == 900)
    }
    @Test func dragAndReanchor() {
        var axis = ScrollAxis(edges: .init(minimum: 0, maximum: 1000), range: 400)
        axis.beginDrag(); axis.drag(translation: 50)
        #expect(abs(axis.offset + 25.730994152) < 1e-6)
        let held = axis.offset
        axis.edges.minimum = -20
        var control = axis
        control.drag(translation: 50)
        #expect(abs(control.offset - held) > 8)
        axis.reanchorDrag(); axis.drag(translation: 50)
        #expect(abs(axis.offset - held) < 1e-8)
        axis.shift(by: 100)
        axis.edges = .init(minimum: 80, maximum: 1100)
        axis.drag(translation: 50)
        #expect(abs(axis.offset - held - 100) < 1e-8)
    }
    @Test func freeStepComposes() {
        var axis = ScrollAxis(); axis.release(velocity: 2)
        var split = axis
        axis.step(milliseconds: 16.667)
        #expect(abs(axis.offset - 32.7514) < 0.001)
        #expect(abs(axis.velocity - 1.934366) < 0.00001)
        split.step(milliseconds: 7); split.step(milliseconds: 9.667)
        #expect(abs(split.offset - axis.offset) < 1e-10)
    }
    @Test func springIgnoresMultiplierAndClampsAtRest() {
        var normal = ScrollAxis(offset: -100, edges: .init(minimum: 0, maximum: 1000), scale: 3)
        normal.release(velocity: -2)
        var fast = normal; fast.multiplier = 4
        normal.step(milliseconds: 16); fast.step(milliseconds: 16)
        #expect(normal.offset == fast.offset)
        for _ in 0..<1000 { normal.step(milliseconds: 1000 / 120) }
        #expect(normal.offset == 0)
        #expect(normal.phase == .idle)
    }
    @Test func deadAxisDoesNotEndLiveMotion() {
        var dead = ScrollAxis(edges: .init(minimum: 0, maximum: 0))
        dead.release(velocity: 0)
        #expect(!dead.step(milliseconds: 16).endedDeceleration)
        var live = ScrollAxis(); live.release(velocity: 3, multiplier: 4)
        #expect(!live.step(milliseconds: 16).endedDeceleration)
        #expect(live.multiplier == 4)
    }
    @Test func projectionFloor() {
        #expect(abs(ScrollMath.projectedOffset(100, velocity: 2) - 1094.005) < 0.001)
        #expect(ScrollMath.projectedOffset(100, velocity: 0.005) == 100)
    }
    @Test func releaseOrderingAndGuard() {
        var decision = ReleaseDecision()
        decision.beginGesture(); decision.sample(velocity: .init(y: -3000), translation: .zero)
        #expect(decision.release(recognizerVelocity: .init(y: -3000), at: 0).velocity.y == 3)
        decision.beginGesture(); decision.sample(velocity: .init(y: -2000), translation: .zero)
        decision.sample(velocity: .init(y: -4000), translation: .zero)
        #expect(decision.release(recognizerVelocity: .init(y: -4000), at: 0).velocity.y == 2.5)
        decision.beginGesture(); decision.sample(velocity: .init(y: -100), translation: .zero)
        decision.sample(velocity: .init(y: -500), translation: .zero)
        let release = decision.release(recognizerVelocity: .init(y: -500), at: 0)
        #expect(release.decelerates)
        #expect(abs(release.velocity.y - 0.2) < 1e-12)
        #expect(!decision.release(recognizerVelocity: .zero, at: 0).decelerates)
    }
    @Test func diagonalAndFlickStreak() {
        var decision = ReleaseDecision()
        decision.beginGesture(); decision.sample(velocity: .init(x: -200, y: -200), translation: .zero)
        #expect(decision.release(recognizerVelocity: .init(x: -200, y: -200), at: 0).decelerates)
        for index in 0..<40 {
            decision.touchDown(at: Double(index) * 0.4)
            decision.beginGesture()
            decision.sample(velocity: .init(y: -3000), translation: .init(y: -300))
            let release = decision.release(recognizerVelocity: .init(y: -3000), at: Double(index) * 0.4)
            if index == 3 { #expect(release.multiplier == 1.9) }
        }
        #expect(decision.multiplier == 16)
        decision.touchDown(at: 30)
        #expect(decision.multiplier == 1)
    }
    @Test func panHysteresisAndVelocity() {
        var pan = PanModel(); pan.begin(at: .init(y: 400), time: 0)
        pan.move(to: .init(y: 396), time: 0.01)
        #expect(!pan.recognized); #expect(pan.velocity.y == -80)
        pan.move(to: .init(y: 386), time: 0.02)
        #expect(pan.recognized); #expect(pan.translation.y == -4)
        pan.move(to: .init(y: 374), time: 0.03)
        #expect(pan.translation.y == -16)
    }
}

@Suite struct TrajectoryTests {
    @Test(arguments: [-3.0, -0.3, 0, 0.3, 3]) func bakeMatchesAxis(velocity: Double) {
        var axis = ScrollAxis(offset: 30.1234, edges: .init(minimum: 0, maximum: 1000), scale: 3)
        axis.release(velocity: velocity)
        let path = ScrollTrajectory(baking: axis)
        #expect(path.samples[0].offset == 30.1234)
        for sample in path.samples.dropFirst() {
            let write = axis.step(milliseconds: 1000 / 120)
            #expect(abs(write.written - sample.offset) < 1e-10)
        }
        #expect(axis.phase == .idle)
        #expect(path.additiveValues.last == 0)
        #expect(path.keyTimes.last == 1)
    }
    @Test func truncationAndSplicePreserveMotion() {
        var axis = ScrollAxis(); axis.release(velocity: 3)
        let path = ScrollTrajectory(baking: axis)
        let time = 0.327
        let truncated = path.truncated(at: time)
        for t in stride(from: 0.0, through: time, by: 0.001) {
            #expect(abs(path.sample(at: t).offset - truncated.sample(at: t).offset) < 1e-9)
        }
        #expect(truncated.multiplierResetTime == nil)
        let state = path.sample(at: time)
        axis.reseed(offset: state.offset + 50, velocity: state.velocity)
        axis.edges.maximum = 700
        let future = ScrollTrajectory(baking: axis)
        let splice = path.splicing(beginTime: 10, now: 10 + time, future: future, shift: 50)
        #expect(abs(splice.trajectory.sample(at: 10 + time - splice.beginTime).offset - state.offset - 50) < 1e-9)
        #expect(abs(splice.trajectory.sample(at: time).velocity - state.velocity) < 1e-8)
        #expect(splice.trajectory.multiplierResetTime != nil)
        #expect(path.extent(after: time).contains(state.offset))
    }
}