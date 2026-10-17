import Foundation
import Testing
@testable import UltraList

private struct SyntheticClock {
    var now: Double = 0
    mutating func advance(_ seconds: Double) { now += seconds }
}

private struct Simulation {
    var clock = SyntheticClock()
    var core = ScrollCore()
    var flight: FlightState?
    var trace: [(time: Double, offset: Double)] = []
    mutating func release(velocity: Double) {
        core.touchDown(at: clock.now); core.beginDrag()
        core.drag(translation: .zero, velocity: .init(y: -velocity * 1000))
        core.endDrag(velocity: .init(y: -velocity * 1000), at: clock.now)
        flight = FlightState(core: core, time: clock.now)
    }
    mutating func tick(_ seconds: Double) {
        clock.advance(seconds)
        flight?.beginTick(at: clock.now, core: &core)
        if var flight, flight.rebake(at: clock.now, core: core) { self.flight = flight }
        trace.append((clock.now, core.offset))
    }
    mutating func shift(_ delta: Double) { core.shift(by: delta); flight?.shift(by: delta, edges: core.axis.edges) }
    mutating func edge(_ maximum: Double?) { core.setEdges(.init(maximum: maximum)); flight?.edgesChanged(to: core.axis.edges) }
}

@Suite struct SimulationTests {
    @Test func counterfactualMutationCannotLurchAtFrozenTime() {
        var control = Simulation(); control.release(velocity: 4)
        var mutated = control
        var frameBase = 0.0
        for frame in 0..<120 {
            control.tick(1 / 60); mutated.tick(1 / 60)
            if frame % 3 == 0 {
                let before = frameBase - mutated.core.offset
                let shift = frame % 2 == 0 ? 73.0 : -41
                mutated.shift(shift); frameBase += shift
                #expect(abs(frameBase - mutated.core.offset - before) < 1e-9)
            }
            #expect(abs(frameBase - mutated.core.offset + control.core.offset) < 1e-7)
        }
        // Deliberately omit the content translation to confirm the oracle detects a bad shift.
        let badScreen = frameBase - mutated.core.offset - 50
        #expect(abs(badScreen + control.core.offset) > 49)
    }
    @Test func stalledSamplerCatchesUpInsteadOfSlowingFlight() {
        var regular = Simulation(); regular.release(velocity: 3)
        var stalled = regular
        for _ in 0..<60 { regular.tick(1 / 60) }
        stalled.tick(1)
        #expect(abs(regular.core.offset - stalled.core.offset) < 1e-7)
    }
    @Test func successiveEdgesCoalesceAndRemovedEdgeContinues() {
        var simulation = Simulation(); simulation.release(velocity: 3)
        simulation.tick(0.1)
        simulation.edge(500); simulation.edge(600)
        simulation.tick(0.01)
        #expect(simulation.flight?.generation == 1)
        #expect((simulation.flight?.flight.settledOffset ?? 0) <= 601)
        simulation.edge(nil); simulation.tick(0.01)
        #expect(simulation.flight?.generation == 2)
        #expect((simulation.flight?.flight.settledOffset ?? 0) > 900)
    }
    @Test func replayCodableAndPositiveControl() throws {
        let events: [GestureRecording.Event] = [
            .init(time: 0, phase: .touchDown),
            .init(time: 0.01, phase: .began, translation: .init(y: -10), velocity: .init(y: -3000)),
            .init(time: 0.02, phase: .changed, translation: .init(y: -40), velocity: .init(y: -3000)),
            .init(time: 0.03, phase: .ended, translation: .init(y: -40), velocity: .init(y: -3000)),
        ]
        var fixture = GestureRecording(name: "synthetic", viewport: 400, edges: .init(minimum: 0, maximum: 5000), frames: [
            .init(time: 0.01, offset: 10, dragging: true, translation: .init(y: -10), velocity: .init(y: -3000)),
            .init(time: 0.02, offset: 40, dragging: true, translation: .init(y: -40), velocity: .init(y: -3000)),
        ] + (0..<120).map { .init(time: 0.03 + Double($0) / 60, offset: 0, dragging: false) }, events: events)
        let expected = fixture.replay(events: true)
        for index in fixture.frames.indices { fixture.frames[index].offset = expected[index] }
        #expect(fixture.maximumDivergence(events: true) < 1e-9)
        let data = try JSONEncoder().encode(fixture)
        let decoded = try JSONDecoder().decode(GestureRecording.self, from: data)
        #expect(decoded.frames.count == 122)
        fixture.frames[20].offset += 5
        #expect(fixture.maximumDivergence(events: true) >= 5 - 1e-8)
    }
    @Test(arguments: [UInt64(11), 62, 387, 0x102030]) func mixedFlightStress(seed: UInt64) {
        var random = seed, simulation = Simulation(), shiftSum = 0.0
        func next() -> UInt64 { random = random &* 2862933555777941757 &+ 3037000493; return random }
        simulation.release(velocity: 5)
        for _ in 0..<200 {
            switch next() % 5 {
            case 0:
                let before = simulation.core.offset
                let shift = Double(Int(next() % 200) - 100)
                simulation.shift(shift); shiftSum += shift
                #expect(abs(simulation.core.offset - before - shift) < 1e-8)
            case 1: simulation.edge(simulation.core.offset + Double(next() % 1000))
            case 2: simulation.edge(nil)
            default: simulation.tick(1 / Double(60 + next() % 61))
            }
            #expect(simulation.core.offset.isFinite)
            #expect(simulation.flight!.flight.trajectory.samples.count < 1400)
            #expect(abs(simulation.flight!.flight.offset(at: simulation.clock.now) - simulation.core.offset) < 1e-7)
        }
        #expect(shiftSum.isFinite)
    }
}