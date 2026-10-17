import Testing
import UltraView
@testable import UltraList
@testable import UltraViewDemo

enum KeyboardReturnOrder: CaseIterable {
    case beforeEnd, afterEnd, beforeLastMovement, targetLayoutBeforeEnd, duplicateBeforeEnd, duplicateAfterEnd, guideOnly, guideBeforeEnd, trackingNotificationAfterReturn
}

@Suite struct KeyboardInsetGestureTests {
    @Test(arguments: KeyboardReturnOrder.allCases)
    func aReturnInvertsTheTrackedInsetExactlyOnce(order: KeyboardReturnOrder) {
        var state = KeyboardInsetGesture(), results: [KeyboardInsetGesture.Resolution] = []
        state.begin(inset: 352, height: 300, restingHeight: 34)
        state.track(inset: 272, height: 220)
        if order == .beforeLastMovement { #expect(state.keyboardOutcome(height: 300) == nil) }
        state.track(inset: 282, height: 230)
        if order == .beforeEnd || order == .duplicateBeforeEnd || order == .targetLayoutBeforeEnd || order == .trackingNotificationAfterReturn {
            #expect(state.keyboardOutcome(height: 300) == nil)
            if order == .duplicateBeforeEnd { #expect(state.keyboardOutcome(height: 300) == nil) }
            if order == .targetLayoutBeforeEnd {
                let accepted = state.track(inset: 352, height: 300)
                #expect(!accepted)
            }
        }
        if order == .guideBeforeEnd {
            #expect(state.keyboardOutcome(height: 300) == nil)
            let accepted = state.track(inset: 352, height: 300)
            #expect(!accepted)
        }
        if let result = state.end(height: 230) { results.append(result) }
        if let result = state.keyboardOutcome(height: 300) { results.append(result) }
        if order == .duplicateAfterEnd { #expect(state.keyboardOutcome(height: 300) == nil) }
        #expect(results == [.returned(inset: 352, height: 300, displacement: 70)])
        #expect(!state.isTracking && !state.awaitsOutcome)
    }

    @Test(arguments: [0.0, -2, 2])
    func theReturnTranslatesAnExistingFlightWithoutChangingItsMotion(velocity: Double) {
        var state = KeyboardInsetGesture()
        state.begin(inset: 352, height: 300, restingHeight: 34)
        state.track(inset: 272, height: 220); state.track(inset: 282, height: 230)
        #expect(state.end(height: 230) == nil)
        var core = ScrollCore(offset: 500, viewport: 604)
        core.setEdges(.init(minimum: -352, maximum: 10_000))
        if velocity != 0 { core.reseed(offset: 500, velocity: velocity) }
        var flight = ScrollFlight(trajectory: .init(baking: core.axis), beginTime: 10, coordinateShift: 0)
        let shown = flight.offset(at: 10.1), initialVelocity = core.axis.velocity
        guard case let .returned(_, _, displacement) = state.keyboardOutcome(height: 300) else { Issue.record("No return"); return }
        core.shift(by: -displacement); flight.coordinateShift -= displacement
        #expect(core.offset == 430 && core.axis.velocity == initialVelocity && core.isDecelerating == (velocity != 0))
        #expect(abs(flight.offset(at: 10.1) - shown + 70) < 1e-9)
        #expect(state.keyboardOutcome(height: 300) == nil)
    }

    @Test func aDismissalDoesNotCompensateTheRelease() {
        var state = KeyboardInsetGesture()
        state.begin(inset: 352, height: 300, restingHeight: 34)
        state.track(inset: 82, height: 30)
        #expect(state.keyboardOutcome(height: 34) == nil)
        #expect(state.end(height: 34) == .dismissed(height: 34))
        #expect(state.keyboardOutcome(height: 34) == nil)
    }

    @Test func aPartialAnimatedTargetWaitsForTheKeyboardOutcome() {
        var state = KeyboardInsetGesture()
        state.begin(inset: 352, height: 300, restingHeight: 34)
        state.track(inset: 272, height: 220)
        #expect(state.keyboardOutcome(height: 240) == nil)
        let accepted = state.track(inset: 292, height: 240)
        #expect(!accepted)
        #expect(state.end(height: 230) == nil && state.awaitsOutcome)
        #expect(state.keyboardOutcome(height: 300) == .returned(inset: 352, height: 300, displacement: 80))
    }

    @Test func aNewDragAtAPartialHeightKeepsTheUnresolvedOriginalReturn() {
        var state = KeyboardInsetGesture()
        state.begin(inset: 352, height: 300, restingHeight: 34)
        state.track(inset: 282, height: 230)
        #expect(state.end(height: 230) == nil && state.awaitsOutcome)
        let resumed = state.resumeTracking(inset: 282)
        #expect(resumed)
        #expect(state.isTracking && !state.awaitsOutcome)
        state.track(inset: 262, height: 210)
        #expect(state.end(height: 210) == nil)
        #expect(state.keyboardOutcome(height: 300) == .returned(inset: 352, height: 300, displacement: 90))
        let resumedAgain = state.resumeTracking(inset: 352)
        #expect(!resumedAgain)
        #expect(state.keyboardOutcome(height: 300) == nil)
    }
}