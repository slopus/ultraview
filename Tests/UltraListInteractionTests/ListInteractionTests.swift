#if os(iOS) && canImport(XCTest)
import XCTest

final class ListInteractionTests: XCTestCase {
    @MainActor func testMultilineComposerKeepsTrailingButtonsInside() {
        let app = XCUIApplication(); app.launchArguments = ["-screen", "lists", "-listScreen", "chat"]
        app.launch()
        let composer = app.textViews["composer"], send = app.buttons["Send"], stream = app.buttons["Stream"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let initial = composer.frame.height
        composer.tap()
        composer.typeText("First line\nSecond line\nThird line\nFourth line\nFifth line\nSixth line with a long continuation that wraps inside the composer.")
        XCTAssertGreaterThan(composer.frame.height, initial + 20)
        XCTAssertLessThan(composer.frame.height, initial + 120)
        let bar = app.otherElements["composerBar"]
        XCTAssertTrue(bar.frame.contains(send.frame))
        XCTAssertEqual(send.frame.maxX, bar.frame.maxX, accuracy: 2)
        XCTAssertLessThanOrEqual(send.frame.maxX, app.frame.maxX - 8)
        XCTAssertGreaterThanOrEqual(send.frame.minX, stream.frame.maxX)
        XCTAssertGreaterThanOrEqual(stream.frame.minX, composer.frame.maxX)
        XCTAssertEqual(send.frame.maxY, composer.frame.maxY, accuracy: 2)
        app.buttons["Send"].tap()
        XCTAssertLessThanOrEqual(composer.frame.height, initial + 2)
    }
    @MainActor func testSharedCompareTouchAndBlocker() {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "lists", "-listScreen", "compare"]
        app.launch()
        XCTAssertTrue(app.staticTexts["compare-uiKit"].waitForExistence(timeout: 10))
        // Start inside the keyframe pane: the common recognizer must also drive UIKit.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.75))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.35))
        start.press(forDuration: 0.03, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        for mode in ["uiKit", "stepped", "keyframe"] {
            let value = Double(app.staticTexts["compare-\(mode)"].value as? String ?? "") ?? 0
            XCTAssertGreaterThan(value, 100, "\(mode) did not receive the shared touch")
        }
        XCTAssertGreaterThan(Double(app.staticTexts["nativeCoast"].value as? String ?? "") ?? 0, 10, "UIKit stopped at release")
        let blocker = app.segmentedControls["listMainBlocker"]
        blocker.buttons["100 ms"].tap()
        XCTAssertTrue(blocker.buttons["100 ms"].isSelected)
        start.press(forDuration: 0.03, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        blocker.buttons["Main off"].tap()
        XCTAssertEqual(app.state, .runningForeground)
    }
    @MainActor func testBackgroundStressTimersKeepTheirQueueIsolation() {
        let app = XCUIApplication(); app.launchArguments = ["-screen", "stress"]
        app.launch()
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(app.state, .runningForeground)
    }
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
        app.launchArguments = ["-screen", "lists", "-listScreen", "feed", "-listHostProbe", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["Insert"].waitForExistence(timeout: 10))
        for title in ["Insert", "Resize", "Move", "Delete", "5,000", "Top"] { app.buttons[title].tap() }
        app.segmentedControls["listScreens"].buttons["Chat"].tap()
        app.buttons["Stream"].tap()
        let composer = app.textViews["composer"]
        composer.tap(); composer.typeText("A message during streaming")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.buttons["Stream"].exists)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
#endif