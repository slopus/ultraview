import Testing
@testable import UltraList

struct KeyboardInputPolicyTests {
    private let window = KeyboardInputPolicy.Frame(minX: 0, minY: 0, maxX: 400, maxY: 900)

    private func top(_ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double) -> Double? {
        KeyboardInputPolicy.dockedTop(keyboard: .init(minX: minX, minY: minY, maxX: maxX, maxY: maxY), window: window)
    }

    @Test func onlyADockedKeyboardCoveringTheWindowHasAnEdge() {
        #expect(top(0, 560, 400, 900) == 560)
        #expect(KeyboardInputPolicy.dockedTop(keyboard: nil, window: window) == nil)
        // Hidden: below the window, or resting on its bottom edge.
        #expect(top(0, 900, 400, 1240) == nil)
        #expect(top(0, 899.6, 400, 1240) == nil)
        // Floating, then undocked above the bottom edge.
        #expect(top(40, 500, 360, 760) == nil)
        #expect(top(0, 300, 400, 640) == nil)
        // A window narrower than the screen's keyboard, as in a split view.
        #expect(top(-300, 560, 700, 900) == 560)
        // A keyboard running past the bottom still docks; one taller than
        // the window covers all of it.
        #expect(top(0, 560, 400, 940) == 560)
        #expect(top(0, -40, 400, 900) == 0)
    }

    @Test func systemInputIsKeptOnlyForAnInteractiveScrollerOverADockedKeyboard() {
        for mode in [KeyboardInputPolicy.Mode.none, .onDrag, .interactive] {
            for inWindow in [false, true] {
                for docked in [false, true] {
                    let kept = KeyboardInputPolicy.keepsSystemInput(mode: mode, inWindow: inWindow, keyboardDocked: docked)
                    #expect(kept == (mode == .interactive && inWindow && docked))
                }
            }
        }
    }

    @Test func aControllerHandsOnlyADockedKeyboardItCannotMoveToTheSystem() {
        #expect(KeyboardInputPolicy.controllerMode(drivesKeyboard: true, keyboardDocked: true) == .none)
        #expect(KeyboardInputPolicy.controllerMode(drivesKeyboard: true, keyboardDocked: false) == .none)
        #expect(KeyboardInputPolicy.controllerMode(drivesKeyboard: false, keyboardDocked: false) == .none)
        #expect(KeyboardInputPolicy.controllerMode(drivesKeyboard: false, keyboardDocked: true) == .interactive)
    }
}
