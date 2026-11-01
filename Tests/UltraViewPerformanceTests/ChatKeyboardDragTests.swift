#if canImport(UIKit) && !SWIFT_PACKAGE
import XCTest

/// Drags the demo chat with the keyboard down, then up, then once into the
/// keyboard, for a device trace of the main thread and the display during
/// chat drags. Each drag is marked in Points of Interest
/// (`dev.ultraview.keyboarddrag`). The chat's own keyboard dismissal moves
/// the keyboard on phones, so no drag may find the hidden system keyboard
/// input installed. Configure through the runner's environment
/// (`TEST_RUNNER_` prefixed with xcodebuild): `CHAT_DRAG_ENGINE` picks the
/// engine, `CHAT_DRAG_SYSTEM` set to YES leaves dismissal to the system,
/// `CHAT_DRAG_REPEAT` repeats each set of drags, `CHAT_DRAG_LANDSCAPE` set
/// to YES turns the device to landscape first, and `CHAT_DRAG_FALLBACK` set
/// to YES expects the hidden input with the keyboard up (no driven
/// keyboard: iPad).
@MainActor
final class ChatKeyboardDragTests: XCTestCase {
    func testChatDrags() throws {
        let environment = ProcessInfo.processInfo.environment
        let engine = environment["CHAT_DRAG_ENGINE"] ?? "keyframe"
        let system = environment["CHAT_DRAG_SYSTEM"] == "YES"
        let repeats = max(1, Int(environment["CHAT_DRAG_REPEAT"] ?? "") ?? 1)
        let landscape = environment["CHAT_DRAG_LANDSCAPE"] == "YES"
        let fallback = environment["CHAT_DRAG_FALLBACK"] == "YES"
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "lists", "-listScreen", "chat", "-listEngine", engine,
                               "-listKeyboardGeometryProbe", "YES", "-listSystemKeyboardDismissal", system ? "YES" : "NO"]
        app.launch()
        let composer = app.textViews["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        sleep(2)
        let window = app.windows.firstMatch
        let origin = window.coordinate(withNormalizedOffset: .zero)
        func point(_ y: Double) -> XCUICoordinate { origin.withOffset(.init(dx: window.frame.midX, dy: y)) }
        func drag(_ from: Double, _ to: Double, velocity: Double) {
            point(from).press(forDuration: 0.1, thenDragTo: point(to), withVelocity: .init(velocity), thenHoldForDuration: 0.4)
            usleep(700_000)
        }
        let height = window.frame.height
        // Keyboard down: slow and medium drags that end held.
        for _ in 0..<repeats {
            for (from, to, velocity) in [(0.3, 0.7, 300.0), (0.7, 0.3, 300.0), (0.3, 0.7, 1000.0), (0.7, 0.3, 1000.0)] {
                drag(height * from, height * to, velocity: velocity)
            }
        }
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        sleep(1)
        // Keyboard up: the same drags above the composer, short of the
        // keyboard. In landscape and on iPad they start lower, where each
        // one lands on the list.
        let bottom = composer.frame.minY - (landscape ? 10 : 30)
        let top = landscape ? window.frame.minY + 80 : fallback ? bottom - 400 : window.frame.minY + 200
        XCTAssertGreaterThan(bottom - top, landscape ? 30 : 120)
        for _ in 0..<repeats {
            for (from, to, velocity) in [(top, bottom, 300.0), (bottom, top, 300.0), (top, bottom, 1000.0), (bottom, top, 1000.0)] {
                drag(from, to, velocity: velocity)
            }
        }
        // Into the keyboard and on to the bottom: it dismisses.
        point(bottom - 20).press(forDuration: 0.1, thenDragTo: point(height - 40), withVelocity: .init(600), thenHoldForDuration: 0.1)
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        sleep(1)
        let probe = app.staticTexts["keyboardGeometry"]
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        let text = try XCTUnwrap(probe.value as? String)
        let attachment = XCTAttachment(string: text)
        attachment.name = "chat-\(engine)\(system ? "-system" : "")"; attachment.lifetime = .keepAlways
        add(attachment)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        if let drags = state["keyboardInputDrags"] as? [String: Int] {
            print("CHAT-DRAG keyboardInputDrags \(drags)")
            XCTAssertGreaterThanOrEqual(drags["down"] ?? 0, 4 * repeats)
            XCTAssertGreaterThanOrEqual(drags["up"] ?? 0, 4 * repeats)
            XCTAssertEqual(drags["downWithInput"], 0, "a drag with the keyboard down found the system keyboard input")
            if fallback { XCTAssertEqual(drags["upWithInput"], drags["up"], "the system keyboard input carries the docked keyboard") }
            else if !system { XCTAssertEqual(drags["upWithInput"], 0, "the chat's dismissal left the system keyboard input installed") }
        }
        app.terminate()
    }
}
#endif
