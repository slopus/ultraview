/// When a scroller on our engines keeps the system's interactive keyboard
/// input. That input is a hidden scroll view whose pan runs beside ours on
/// every drag event, so it is kept only while a docked keyboard is up and
/// nothing else moves it with the finger. With no keyboard there is nothing
/// to dismiss.
///
/// Frames are in window points, y growing down.
enum KeyboardInputPolicy {
    enum Mode: Sendable, Equatable { case none, onDrag, interactive }

    struct Frame: Sendable, Equatable {
        var minX: Double, minY: Double, maxX: Double, maxY: Double
    }

    /// The keyboard's top edge when it is docked along the bottom of the
    /// window and covers some of it. A hidden, floating or undocked keyboard
    /// has none: the system's interactive dismissal doesn't move those either.
    static func dockedTop(keyboard: Frame?, window: Frame) -> Double? {
        guard let keyboard, keyboard.minY < window.maxY - 0.5, keyboard.maxY >= window.maxY - 1,
              keyboard.minX <= window.minX + 1, keyboard.maxX >= window.maxX - 1 else { return nil }
        return max(window.minY, keyboard.minY)
    }

    /// Whether a scroller in `mode` keeps the system's interactive input.
    static func keepsSystemInput(mode: Mode, inWindow: Bool, keyboardDocked: Bool) -> Bool {
        mode == .interactive && inWindow && keyboardDocked
    }

    /// The mode a keyboard dismissal controller leaves on its scroller:
    /// none while it moves the keyboard itself or no keyboard is docked, the
    /// system's interactive mode for a docked keyboard it can't move.
    static func controllerMode(drivesKeyboard: Bool, keyboardDocked: Bool) -> Mode {
        !drivesKeyboard && keyboardDocked ? .interactive : .none
    }
}
