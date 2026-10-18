import Testing
@testable import UltraList

struct KeyboardDismissalGestureTests {
    private let geometry = KeyboardDismissalGesture.Geometry(screenHeight: 1000, keyboardTop: 600, accessoryHeight: 80)

    @Test func armingNeedsAnInputAndATouchAboveTheAccessory() {
        for (y, responder, expected) in [(400.0, true, true), (520, true, false), (960, true, false), (400, false, false)] {
            var gesture = KeyboardDismissalGesture()
            #expect(gesture.begin(y: y, time: 0, geometry: geometry, hasFirstResponder: responder) == expected)
        }
    }

    @Test func trackingBeginsAfterThreePointsAndUsesTheFingerBound() {
        var gesture = KeyboardDismissalGesture()
        begin(&gesture)
        #expect(gesture.move(y: 402, time: 0.01) == nil)
        #expect(gesture.move(y: 403, time: 0.02) == .init(boundary: 483, offset: 0))
        #expect(gesture.move(y: 650, time: 0.2) == .init(boundary: 730, offset: 130))
        #expect(gesture.move(y: 1000, time: 0.3) == .init(boundary: 1080, offset: 480))
        #expect(gesture.move(y: 300, time: 0.4) == .init(boundary: 380, offset: 0))
        begin(&gesture)
        #expect(gesture.move(y: 397, time: 0.01) == .init(boundary: 477, offset: 0))
    }

    @Test func onlyACommittedBoundaryKeepsAcceptingMovesBelowTheThreshold() {
        var gesture = KeyboardDismissalGesture()
        begin(&gesture)
        let first = gesture.move(y: 403, time: 0.01)
        #expect(gesture.move(y: 401, time: 0.02) == nil)
        if let first { gesture.commit(first) }
        #expect(gesture.move(y: 401, time: 0.03) == .init(boundary: 481, offset: 0))
    }

    @Test func theEightPointGapIsNotPartOfTheCapturedAccessory() {
        var gesture = KeyboardDismissalGesture()
        let composerTop = geometry.keyboardTop - geometry.accessoryHeight - 8
        let upperStripArmed = gesture.begin(y: composerTop + 4, time: 0, geometry: geometry, hasFirstResponder: true)
        #expect(upperStripArmed)
        let lowerStripArmed = gesture.begin(y: geometry.keyboardTop - geometry.accessoryHeight, time: 0,
                                           geometry: geometry, hasFirstResponder: true)
        #expect(!lowerStripArmed)
    }

    @Test func aSlowPartialDragReturnsAndPassingTheBottomDismisses() {
        var gesture = KeyboardDismissalGesture()
        begin(&gesture)
        commit(&gesture, y: 800, time: 2)
        #expect(gesture.end(y: 800, time: 2.1) == .init(offset: 280, targetOffset: 0, dismisses: false))
        begin(&gesture, time: 3)
        commit(&gesture, y: 850, time: 5)
        #expect(gesture.end(y: 850, time: 5.1) == .init(offset: 330, targetOffset: 400, dismisses: true))
        #expect(gesture.dismissedInTouchSequence)
    }

    @Test func theFingerAndCapturedAccessoryMustCrossTheKeyboardTop() {
        var gesture = KeyboardDismissalGesture()
        begin(&gesture)
        gesture.move(y: 500, time: 1)
        gesture.move(y: 650, time: 1.05)
        #expect(gesture.end(y: 710, time: 1.1)?.dismisses == true)
        begin(&gesture, time: 2)
        gesture.move(y: 450, time: 2.02)
        gesture.move(y: 500, time: 2.04)
        #expect(gesture.end(y: 500, time: 2.05)?.dismisses == false)
    }

    @Test func aHoldReturnsButCancellationCanDismissAtTheCommittedThreshold() {
        var gesture = KeyboardDismissalGesture()
        begin(&gesture)
        gesture.move(y: 710, time: 0.05)
        #expect(gesture.end(y: 710, time: 0.3)?.dismisses == false)
        begin(&gesture, time: 1)
        commit(&gesture, y: 900, time: 1.1)
        #expect(gesture.end(y: 900, time: 1.11, cancelled: true)?.dismisses == true)
        begin(&gesture, time: 2)
        gesture.move(y: 900, time: 2.1)
        #expect(gesture.end(y: 900, time: 2.11)?.dismisses == true)
        let ignored = gesture.begin(y: 960, time: 3, geometry: geometry, hasFirstResponder: true)
        #expect(!ignored)
        #expect(!gesture.dismissedInTouchSequence)
    }

    @Test func aReleaseCanDismissWithoutAMoveAndTheVelocityThresholdIsStrict() {
        var gesture = KeyboardDismissalGesture()
        let first = gesture.begin(y: 500, time: 0, geometry: geometry, hasFirstResponder: true)
        #expect(first)
        #expect(gesture.end(y: 550, time: 0.1)?.dismisses == false)
        let second = gesture.begin(y: 500, time: 1, geometry: geometry, hasFirstResponder: true)
        #expect(second)
        #expect(gesture.end(y: 550.001, time: 1.1)?.dismisses == true)
    }

    @Test func aChangedKeyboardTopGovernsTheReleaseCrossing() {
        var gesture = KeyboardDismissalGesture()
        let initial = KeyboardDismissalGesture.Geometry(screenHeight: 1000, keyboardTop: 500, accessoryHeight: 50)
        let armed = gesture.begin(y: 440, time: 0, geometry: initial, hasFirstResponder: true)
        #expect(armed)
        gesture.updateGeometry(screenHeight: 1000, keyboardTop: 544)
        #expect(gesture.end(y: 480, time: 0.01) == .init(offset: 0, targetOffset: 0, dismisses: false))
    }

    @Test func currentGeometryPreservesTheCapturedAccessoryAndCommittedBoundary() {
        var gesture = KeyboardDismissalGesture()
        let initial = KeyboardDismissalGesture.Geometry(screenHeight: 1000, keyboardTop: 500, accessoryHeight: 50)
        let armed = gesture.begin(y: 400, time: 0, geometry: initial, hasFirstResponder: true)
        #expect(armed)
        let value = gesture.move(y: 900, time: 1)
        #expect(value == .init(boundary: 950, offset: 450))
        if let value { gesture.commit(value) }
        gesture.updateGeometry(screenHeight: 1100, keyboardTop: 600)
        #expect(gesture.end(y: 900, time: 2, cancelled: true) == .init(offset: 450, targetOffset: 0, dismisses: false))

        let rearmed = gesture.begin(y: 400, time: 3, geometry: initial, hasFirstResponder: true)
        #expect(rearmed)
        gesture.updateGeometry(screenHeight: 1200, keyboardTop: 700)
        let current = gesture.move(y: 1100, time: 4)
        #expect(current == .init(boundary: 1150, offset: 450))
        if let current { gesture.commit(current) }
        #expect(gesture.end(y: 1100, time: 5, cancelled: true) == .init(offset: 450, targetOffset: 500, dismisses: true))
    }

    @Test func onlyTheCommittedBoundaryDecidesThePositionThreshold() {
        var gesture = KeyboardDismissalGesture()
        begin(&gesture)
        gesture.move(y: 900, time: 1)
        #expect(gesture.end(y: 900, time: 2)?.dismisses == false)
        begin(&gesture, time: 3)
        commit(&gesture, y: 840, time: 4)
        gesture.move(y: 600, time: 5)
        #expect(gesture.end(y: 600, time: 6)?.dismisses == true)
    }

    @Test func theCrossingCheckIsStrictEvenWithAPassingCommittedBoundary() {
        var gesture = KeyboardDismissalGesture()
        begin(&gesture)
        commit(&gesture, y: 900, time: 1)
        #expect(gesture.end(y: 520, time: 2, cancelled: true)?.dismisses == false)
    }

    @Test func theVelocityIsAnUnweightedMeanOfRecentPairsDividedByFive() {
        var gesture = KeyboardDismissalGesture()
        begin(&gesture)
        gesture.move(y: 500, time: 1)
        gesture.move(y: 600, time: 1.05)
        #expect(abs(gesture.estimatedVelocity(at: 1.05) - 210) < 1e-9)
        #expect(gesture.estimatedVelocity(at: 2) == 0)
    }

    @Test func onlyTheLatestSixSamplesRemainAndCutoffPairsAreIncludedWhole() {
        var gesture = KeyboardDismissalGesture()
        begin(&gesture)
        let positions = [401.0, 403, 406, 410, 415, 421, 428, 436]
        for (index, y) in positions.enumerated() { gesture.move(y: y, time: Double(index + 1) / 100) }
        #expect(abs(gesture.estimatedVelocity(at: 0.08) - 120) < 1e-9)
        begin(&gesture)
        gesture.move(y: 450, time: 0.1)
        #expect(gesture.estimatedVelocity(at: 0.2) == 100)
    }

    @Test func cancellationDoesNotAddTheEndpointAndDuplicateTimesAreNotFiltered() {
        var gesture = KeyboardDismissalGesture()
        begin(&gesture)
        gesture.move(y: 500, time: 0.1)
        let before = gesture.estimatedVelocity(at: 0.1)
        #expect(gesture.end(y: 900, time: 0.1, cancelled: true)?.dismisses == false)
        #expect(gesture.estimatedVelocity(at: 0.1) == before)
        begin(&gesture)
        gesture.move(y: 500, time: 0)
        #expect(gesture.estimatedVelocity(at: 0).isInfinite)
    }

    @Test func theBottomFortyFourPointsCannotArmTheGesture() {
        let shortKeyboard = KeyboardDismissalGesture.Geometry(screenHeight: 1000, keyboardTop: 990, accessoryHeight: 10)
        var gesture = KeyboardDismissalGesture()
        let above = gesture.begin(y: 955.999, time: 0, geometry: shortKeyboard, hasFirstResponder: true)
        let equal = gesture.begin(y: 956, time: 0, geometry: shortKeyboard, hasFirstResponder: true)
        let below = gesture.begin(y: 956.001, time: 0, geometry: shortKeyboard, hasFirstResponder: true)
        #expect(above)
        #expect(equal)
        #expect(!below)
    }

    private func begin(_ gesture: inout KeyboardDismissalGesture, time: Double = 0) {
        let armed = gesture.begin(y: 400, time: time, geometry: geometry, hasFirstResponder: true)
        #expect(armed)
    }

    private func commit(_ gesture: inout KeyboardDismissalGesture, y: Double, time: Double) {
        if let tracking = gesture.move(y: y, time: time) { gesture.commit(tracking) }
        else { Issue.record("A committed sample must pass the movement threshold") }
    }

    @Test func aSecondFingerCannotReplaceOrFinishThePrimaryDrag() {
        final class Touch {}
        let first = Touch(), second = Touch()
        let primary = ObjectIdentifier(first), extra = ObjectIdentifier(second)
        var touches = KeyboardPrimaryTouch(), gesture = KeyboardDismissalGesture()
        let started = touches.begin(primary)
        #expect(started)
        begin(&gesture)
        let replaced = touches.begin(extra)
        #expect(!replaced)
        if touches.matches(primary) { commit(&gesture, y: 650, time: 0.2) }
        if touches.matches(extra) { gesture.move(y: 900, time: 0.21) }
        let endedExtra = touches.end(extra)
        #expect(!endedExtra)
        #expect(gesture.isTracking)
        #expect(gesture.offset == 130)
        let endedPrimary = touches.end(primary)
        #expect(endedPrimary)
        #expect(gesture.end(y: 650, time: 0.5)?.dismisses == false)
        #expect(!touches.isActive)
    }
}