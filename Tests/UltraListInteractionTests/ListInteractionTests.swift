#if os(iOS) && canImport(XCTest)
import XCTest

final class ListInteractionTests: XCTestCase {
    @MainActor func testDeviceProbes() {
        let app = XCUIApplication()
        for screen in ["feed", "chat"] {
            app.launchArguments = ["-screen", "lists", "-listScreen", screen, "-listProbe", "YES"]
            app.launch()
            let deadline = Date().addingTimeInterval(11)
            while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "device-\(screen)"; screenshot.lifetime = .keepAlways; add(screenshot)
            app.terminate()
        }
    }
    @MainActor func testRecordPublicGestures() throws {
        try recordGestures(["slow-drag", "medium-flick", "into-bottom", "overscroll"])
    }
    @MainActor func testRecordEdgeFlick() throws {
        try recordGestures(["into-bottom"])
    }
    @MainActor private func recordGestures(_ fixtures: [String]) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "lists", "-listScreen", "record"]
        app.launch()
        let canvas = app.scrollViews["gestureCanvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        let name = app.textFields["recordingName"]
        for fixture in fixtures {
            name.tap()
            if let value = name.value as? String { name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count)) }
            name.typeText(fixture)
            app.buttons["beginGestureRecording"].tap()
            let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            if fixture == "slow-drag" {
                start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
            } else {
                start.press(forDuration: 0.02, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
            }
            // Wait through deceleration before exporting the delegate observations.
            let deadline = Date().addingTimeInterval(4)
            while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            app.buttons["saveGestureRecording"].tap()
        }
    }

    @MainActor func testFeedMutationsAndChatKeyboard() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "lists", "-listScreen", "feed"]
        app.launch()
        XCTAssertTrue(app.buttons["Insert"].waitForExistence(timeout: 10))
        for title in ["Insert", "Move", "Delete", "5,000", "Top"] { app.buttons[title].tap() }
        app.segmentedControls["listScreens"].buttons["Chat"].tap()
        app.buttons["Stream"].tap()
        let composer = app.textFields["composer"]
        composer.tap(); composer.typeText("A message during streaming")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.buttons["Stream"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
#endif