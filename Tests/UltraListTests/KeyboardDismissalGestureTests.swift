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
        #expect(gesture.move(y: 403, time: 0.02) == 0)
        #expect(gesture.move(y: 650, time: 0.2) == 130)
        #expect(gesture.move(y: 1000, time: 0.3) == 400)
        #expect(gesture.move(y: 300, time: 0.4) == 0)
    }

    @Test func aSlowPartialDragReturnsAndPassingTheBottomDismisses() {
        var gesture = KeyboardDismissalGesture()
        begin(&gesture)
        #expect(gesture.move(y: 800, time: 2) == 280)
        #expect(gesture.end(y: 800, time: 2.1) == .init(offset: 280, targetOffset: 0, dismisses: false))
        begin(&gesture, time: 3)
        #expect(gesture.move(y: 850, time: 5) == 330)
        #expect(gesture.end(y: 850, time: 5.1) == .init(offset: 330, targetOffset: 400, dismisses: true))
        #expect(gesture.dismissedInTouchSequence)
    }

    @Test func theLastTenthOfASecondDecidesVelocityAndTheFingerMustPassTheKeyboard() {
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

    @Test func aHoldOrCancellationDoesNotDismissAndANewTouchClearsTheOutcome() {
        var gesture = KeyboardDismissalGesture()
        begin(&gesture)
        gesture.move(y: 710, time: 0.05)
        #expect(gesture.end(y: 710, time: 0.3)?.dismisses == false)
        begin(&gesture, time: 1)
        gesture.move(y: 900, time: 1.1)
        #expect(gesture.end(y: 900, time: 1.11, cancelled: true)?.dismisses == false)
        begin(&gesture, time: 2)
        gesture.move(y: 900, time: 2.1)
        #expect(gesture.end(y: 900, time: 2.11)?.dismisses == true)
        let ignored = gesture.begin(y: 960, time: 3, geometry: geometry, hasFirstResponder: true)
        #expect(!ignored)
        #expect(!gesture.dismissedInTouchSequence)
    }

    private func begin(_ gesture: inout KeyboardDismissalGesture, time: Double = 0) {
        let armed = gesture.begin(y: 400, time: time, geometry: geometry, hasFirstResponder: true)
        #expect(armed)
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
        if touches.matches(primary) { gesture.move(y: 650, time: 0.2) }
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