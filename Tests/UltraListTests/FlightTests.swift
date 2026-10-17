import Foundation
import Testing
@testable import UltraList

@Suite struct FlightTests {
    func released(edges: ScrollEdges = .init()) -> ScrollCore {
        var core = ScrollCore(); core.setEdges(edges)
        core.touchDown(at: 0); core.beginDrag()
        core.drag(translation: .init(y: -100), velocity: .init(y: -3000))
        core.endDrag(velocity: .init(y: -3000), at: 0)
        return core
    }
    @Test func offsetStableUntilTick() {
        var core = released()
        var state = FlightState(core: core, time: 0)
        let release = core.offset
        #expect(state.flight.offset(at: 0.1) > release + 200)
        #expect(core.offset == release)
        state.beginTick(at: 0.1, core: &core)
        #expect(core.offset == state.flight.offset(at: 0.1))
        for _ in 0..<100 { #expect(core.offset == state.flight.offset(at: 0.1)) }
    }
    @Test func shiftsPersistWithoutRebaking() {
        var core = released()
        var state = FlightState(core: core, time: 0)
        let old = state.flight
        core.shift(by: 50); state.shift(by: 50, edges: core.axis.edges)
        state.beginTick(at: 0.2, core: &core)
        #expect(abs(core.offset - old.offset(at: 0.2) - 50) < 1e-9)
        let rebaked = state.rebake(at: 0.2, core: core)
        #expect(!rebaked)
        #expect(state.generation == 0)
    }
    @Test func unreachableEdgeDoesNotRebake() {
        let core = released()
        var state = FlightState(core: core, time: 0)
        state.edgesChanged(to: .init(maximum: state.flight.settledOffset + 500))
        #expect(!state.rebakePending)
    }
    @Test func invalidationSurvivesTickAndSpliceIsContinuous() {
        var core = released()
        var state = FlightState(core: core, time: 0)
        state.beginTick(at: 0.1, core: &core)
        let old = state.flight
        core.setEdges(.init(maximum: core.offset + 10))
        state.edgesChanged(to: core.axis.edges)
        #expect(state.rebakePending)
        state.beginTick(at: 0.12, core: &core)
        let rebaked = state.rebake(at: 0.12, core: core)
        #expect(rebaked)
        #expect(abs(state.flight.offset(at: 0.12) - old.offset(at: 0.12)) < 1e-8)
        #expect(state.generation == 1)
        #expect(state.flight.settledOffset <= core.axis.edges.maximum! + 1)
    }
    @Test func brakeSwapHasNoReverseStepWithTwoFrameDelay() {
        let core = released()
        let state = FlightState(core: core, time: 0)
        let stop = FlightState.brakeStopTime(now: 0.1, lastFrame: 0.1, nextFrame: 0.1 + 1 / 60)
        let brake = state.braked(stoppingAt: stop)
        for time in stride(from: 0.1, through: stop, by: 0.0001) {
            #expect(abs(state.flight.offset(at: time) - brake.offset(at: time)) < 1e-8)
        }
        #expect(brake.offset(at: 100) == brake.settledOffset)
        // A hard stop is the positive control: it reverses by over one frame's travel.
        #expect(state.flight.offset(at: stop) - state.flight.offset(at: 0.1) > 60)
    }
    @Test func suppressionStillBouncesAndDoesNotLeak() {
        var core = ScrollCore(); core.setEdges(.init(minimum: 0, maximum: 1000))
        core.beginDrag(); core.drag(translation: .init(y: 200), velocity: .init(y: 3000))
        let bounced = core.endDrag(velocity: .zero, at: 0)
        #expect(bounced)
        for _ in 0..<120 { _ = core.step(seconds: 1 / 60) }
        #expect(core.offset == 0)
        core.beginDrag(); core.drag(translation: .init(y: -100), velocity: .init(y: -3000))
        let flung = core.endDrag(velocity: .init(y: -3000), at: 3)
        #expect(flung)
        #expect(core.axis.velocity == 3)
    }
    @Test func steppedAndBakedLandTogether() {
        var core = released(edges: .init(minimum: 0, maximum: 800))
        let path = ScrollTrajectory(baking: core.axis)
        for _ in 0..<600 { if core.step(seconds: 1 / 60) { break } }
        #expect(abs(core.offset - path.finalOffset) < 2)
    }
}