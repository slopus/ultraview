/// Which keyboard host a dismissal controller moves itself. The controller
/// slides the host's layer in the keyboard's own window and reads the host in
/// the app window's coordinates by offsetting the two windows' frames. That
/// holds only while the app's window covers the screen: on a phone, and on an
/// iPad running the app full screen in any orientation. A smaller window, as
/// with windowed apps, Stage Manager or split view, sits somewhere on a
/// screen-wide keyboard it shares with other apps; its frame doesn't say
/// where, so the system's interactive dismissal keeps it. So does a keyboard
/// that isn't docked across the window's bottom: floating, split or undocked.
///
/// Frames are in window points, y growing down; the screen is in the same
/// orientation as the window.
enum KeyboardHostPolicy {
    /// Whether the controller moves `host` itself.
    static func drives(host: KeyboardInputPolicy.Frame, window: KeyboardInputPolicy.Frame,
                       screenWidth: Double, screenHeight: Double) -> Bool {
        guard coversScreen(window: window, screenWidth: screenWidth, screenHeight: screenHeight) else { return false }
        return host.maxY > host.minY && host.maxX - host.minX >= window.maxX - window.minX - 1 && abs(host.maxY - window.maxY) <= 1
    }

    /// Whether `window` is the size of the screen, so a docked keyboard
    /// that shows up in it is one the controller moves.
    static func coversScreen(window: KeyboardInputPolicy.Frame, screenWidth: Double, screenHeight: Double) -> Bool {
        abs(window.maxX - window.minX - screenWidth) <= 1 && abs(window.maxY - window.minY - screenHeight) <= 1
    }
}
