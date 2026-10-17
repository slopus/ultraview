#if os(iOS) && canImport(XCTest)
import XCTest

final class ListInteractionTests: XCTestCase {
    @MainActor private func keyboardGeometry(_ app: XCUIApplication) throws -> [String: Any] {
        let probe = app.staticTexts["keyboardGeometry"]
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        let text = try XCTUnwrap(probe.value as? String)
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    @MainActor private func settle(_ seconds: Double = 0.4) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
    private func logGeometry(_ label: String, _ state: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        print("\(label): \(String(decoding: data, as: UTF8.self))")
    }
    @MainActor func testKeyboardTracksComposerAndViewportDuringShowHideAndInteractiveDismissal() throws {
        let app = XCUIApplication()
        for mode in ["uiKit", "stepped", "keyframe"] {
            app.launchArguments = ["-screen", "lists", "-listScreen", "chat", "-listEngine", mode, "-listKeyboardGeometryProbe", "YES"]
            app.launch()
            let composer = app.textViews["composer"]
            XCTAssertTrue(composer.waitForExistence(timeout: 10))
            composer.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            settle()
            let shown = try keyboardGeometry(app)
            try logGeometry("Keyboard shown \(mode)", shown)
            XCTAssertGreaterThan(shown["keyboardSpringSamples"] as? Int ?? 0, 0, "\(mode): first show must animate the rows")
            XCTAssertLessThanOrEqual(shown["rowGap"] as? Double ?? 1000, 1.5, "\(mode): first show \(shown)")
            app.buttons["dismissKeyboard"].tap()
            settle()
            let hiddenState = try keyboardGeometry(app)
            try logGeometry("Keyboard hidden \(mode)", hiddenState)
            XCTAssertGreaterThan(hiddenState["keyboardSpringSamples"] as? Int ?? 0, shown["keyboardSpringSamples"] as? Int ?? 0, "\(mode): hide must animate the rows")
            composer.tap(); settle()
            let reshown = try keyboardGeometry(app)
            XCTAssertGreaterThan(reshown["keyboardSpringSamples"] as? Int ?? 0, hiddenState["keyboardSpringSamples"] as? Int ?? 0, "\(mode): repeated show must animate the rows")
            let composerTop = composer.frame.minY
            let x = app.frame.midX
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let partialStart = origin.withOffset(.init(dx: x, dy: composerTop - 40))
            let partialEnd = origin.withOffset(.init(dx: x, dy: composerTop + 20))
            partialStart.press(forDuration: 0.05, thenDragTo: partialEnd, withVelocity: .slow, thenHoldForDuration: 0.2)
            settle()
            XCTAssertTrue(app.keyboards.firstMatch.exists, "\(mode): a drag ending above the keyboard should keep it open")
            XCTAssertEqual(try keyboardGeometry(app)["stoppedReleases"] as? Int, 0, "\(mode): an undismissed keyboard must not veto the release")
            let start = origin.withOffset(.init(dx: x, dy: composerTop - 90))
            let end = origin.withOffset(.init(dx: x, dy: app.frame.maxY - 70))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
            let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
            XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed, mode)
            let state = try keyboardGeometry(app)
            try logGeometry("Keyboard dismissed \(mode)", state)
            XCTAssertGreaterThan(state["movingSamples"] as? Int ?? 0, 5, "\(mode): \(state)")
            XCTAssertGreaterThan(state["dragSamples"] as? Int ?? 0, 5, "\(mode): \(state)")
            XCTAssertGreaterThan(state["dragKeyboardTravel"] as? Double ?? 0, 20, "\(mode): \(state)")
            for key in ["composerGap", "rowGap"] {
                XCTAssertLessThanOrEqual(state[key] as? Double ?? 1000, 1.5, "\(mode) \(key): \(state)")
            }
            XCTAssertEqual(state["rowAnimationSamples"] as? Int, 0, "\(mode): \(state)")
            XCTAssertEqual(state["keyboardPasses"] as? Int, 0, "\(mode): \(state)")
            XCTAssertLessThanOrEqual(state["viewportHeightChange"] as? Double ?? 1000, 0.5, "\(mode): \(state)")
            XCTAssertEqual(state["cancelled"] as? Int, 0, "\(mode): \(state)")
            XCTAssertGreaterThan(state["keyboardSpringSamples"] as? Int ?? 0, 0, "\(mode): \(state)")
            XCTAssertEqual(state["keyboardSpringCorrect"] as? Bool, true, "\(mode): \(state)")
            XCTAssertLessThan(state["insetP99"] as? Double ?? 1000, 2, "\(mode): \(state)")
            XCTAssertEqual(state["stoppedReleases"] as? Int, 0, "\(mode): \(state)")
            XCTAssertGreaterThan(state["coast"] as? Double ?? 0, 8, "\(mode): dismissal release lost momentum: \(state)")
            XCTAssertEqual(state["newestSnaps"] as? Int, 0, "\(mode): a fling must not snap to newest: \(state)")
            XCTAssertEqual((state["handoffSamples"] as? [[String: Double]])?.count, 4, "\(mode): \(state)")
            XCTAssertLessThanOrEqual(state["detachedAnimationAmplitude"] as? Double ?? 1000, 1, "\(mode): dismissal added content motion: \(state)")
            let afterStart = origin.withOffset(.init(dx: x, dy: composer.frame.minY - 40))
            let afterEnd = origin.withOffset(.init(dx: x, dy: composer.frame.minY - 220))
            afterStart.press(forDuration: 0.03, thenDragTo: afterEnd, withVelocity: .fast, thenHoldForDuration: 0)
            settle()
            let after = try keyboardGeometry(app)
            XCTAssertGreaterThan(after["coast"] as? Double ?? 0, 8, "\(mode): post-dismissal release lost momentum: \(after)")
            app.terminate()
        }
    }
    @MainActor func testKeyboardDoesNotVetoReleaseMomentumInEitherDirection() throws {
        let app = XCUIApplication()
        for mode in ["uiKit", "stepped", "keyframe"] {
            app.launchArguments = ["-screen", "lists", "-listScreen", "chat", "-listEngine", mode, "-listKeyboardGeometryProbe", "YES", "-listInitialRow", "25"]
            app.launch()
            let composer = app.textViews["composer"]
            XCTAssertTrue(composer.waitForExistence(timeout: 10))
            composer.tap(); XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5)); settle()
            let origin = app.coordinate(withNormalizedOffset: .zero), x = app.frame.midX
            let high = origin.withOffset(.init(dx: x, dy: composer.frame.minY - 210))
            let low = origin.withOffset(.init(dx: x, dy: composer.frame.minY - 35))
            for (start, end) in [(high, low), (low, high)] {
                start.press(forDuration: 0.03, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
                settle()
                let state = try keyboardGeometry(app)
                XCTAssertGreaterThan(state["coast"] as? Double ?? 0, 8, "\(mode): \(state)")
                XCTAssertGreaterThan(abs(state["releaseVelocity"] as? Double ?? 0), 100, "\(mode): \(state)")
                XCTAssertEqual(state["cancelled"] as? Int, 0, "\(mode): \(state)")
                XCTAssertEqual(state["stoppedReleases"] as? Int, 0, "\(mode): \(state)")
            }
            app.terminate()
        }
    }
    @MainActor func testFastKeyboardDismissalKeepsMomentumAwayFromNewest() throws {
        try checkKeyboardDismissal(stationaryRelease: false, initialRow: 25)
    }
    @MainActor func testFastKeyboardDismissalKeepsMomentumFromNewest() throws {
        try checkKeyboardDismissal(stationaryRelease: false)
    }
    @MainActor func testStationaryKeyboardDismissalPreservesTheReleasePosition() throws {
        try checkKeyboardDismissal(stationaryRelease: true)
    }
    @MainActor private func checkKeyboardDismissal(stationaryRelease: Bool, initialRow: Int = 0) throws {
        let app = XCUIApplication()
        for mode in ["uiKit", "stepped", "keyframe"] {
            app.launchArguments = ["-screen", "lists", "-listScreen", "chat", "-listEngine", mode, "-listKeyboardGeometryProbe", "YES"]
            if initialRow > 0 { app.launchArguments += ["-listInitialRow", "\(initialRow)"] }
            app.launch()
            let composer = app.textViews["composer"]
            XCTAssertTrue(composer.waitForExistence(timeout: 10))
            if initialRow > 0 {
                settle()
                XCTAssertGreaterThan(try keyboardGeometry(app)["firstIndex"] as? Int ?? 0, 10, "\(mode): the away-from-newest scenario did not start away")
            }
            composer.tap(); XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5)); settle()
            let origin = app.coordinate(withNormalizedOffset: .zero), x = app.frame.midX
            let start = origin.withOffset(.init(dx: x, dy: composer.frame.minY - 90))
            let end = origin.withOffset(.init(dx: x, dy: app.frame.maxY - (stationaryRelease ? 70 : 180)))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: stationaryRelease ? .slow : .fast, thenHoldForDuration: stationaryRelease ? 0.5 : 0)
            let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
            XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed, mode)
            settle(0.7)
            let state = try keyboardGeometry(app)
            try logGeometry("Keyboard release \(mode) stationary=\(stationaryRelease)", state)
            XCTAssertEqual(state["stoppedReleases"] as? Int, 0, "\(mode): \(state)")
            XCTAssertEqual(state["keyboardSpringCorrect"] as? Bool, true, "\(mode): \(state)")
            XCTAssertEqual((state["handoffSamples"] as? [[String: Double]])?.count, 4, "\(mode): \(state)")
            XCTAssertLessThanOrEqual(state["detachedAnimationAmplitude"] as? Double ?? 1000, 1, "\(mode): \(state)")
            XCTAssertLessThanOrEqual(state["composerGap"] as? Double ?? 1000, 1.5, "\(mode): \(state)")
            let frames = try XCTUnwrap(state["releaseFrames"] as? [[String: Double]])
            XCTAssertGreaterThan(frames.count, 10, mode)
            let firstTime = try XCTUnwrap(frames.first?["time"]), lastTime = try XCTUnwrap(frames.last?["time"])
            XCTAssertGreaterThan(lastTime - firstTime, 0.45, "\(mode): release sampling ended too early")
            if let hideTime = state["keyboardHideTime"] as? Double, hideTime > 0 {
                XCTAssertGreaterThanOrEqual(lastTime, hideTime + 0.45, "\(mode): missing frames after keyboard hide")
            }
            if stationaryRelease {
                XCTAssertLessThanOrEqual(state["handoffExcess"] as? Double ?? 1000, 1, "\(mode): stationary content moved between samples: \(state)")
                XCTAssertLessThan(abs(state["releaseVelocity"] as? Double ?? 1000), 250, "\(mode): \(state)")
                XCTAssertLessThanOrEqual(state["coast"] as? Double ?? 1000, 3, "\(mode): \(state)")
                XCTAssertLessThanOrEqual(abs((state["position"] as? Double ?? 1000) - (state["releasePosition"] as? Double ?? 0)), 3, "\(mode): release position changed: \(state)")
                XCTAssertGreaterThan(state["newestGap"] as? Double ?? -1, 8, "\(mode): content must stay away from newest: \(state)")
                XCTAssertEqual(state["followsComposer"] as? Bool, false, "\(mode): \(state)")
            } else {
                XCTAssertGreaterThan(abs(state["releaseVelocity"] as? Double ?? 0), 250, "\(mode): \(state)")
                XCTAssertGreaterThan(state["coast"] as? Double ?? 0, 8, "\(mode): \(state)")
                XCTAssertEqual(state["newestSnaps"] as? Int, 0, "\(mode): \(state)")
                let deadline = Date().addingTimeInterval(6)
                var final = state
                while final["decelerating"] as? Bool == true, Date() < deadline {
                    settle(0.1); final = try keyboardGeometry(app)
                }
                XCTAssertEqual(final["decelerating"] as? Bool, false, "\(mode): \(final)")
                XCTAssertTrue((final["newestGap"] as? Double ?? -1) < 0 || (final["newestGap"] as? Double ?? 0) > 8, "\(mode): coast returned to newest: \(final)")
            }
            app.terminate()
        }
    }
    @MainActor func testUndismissedKeyboardDragCanReturnToTheNewestEdge() throws {
        let app = XCUIApplication()
        for mode in ["uiKit", "stepped", "keyframe"] {
            app.launchArguments = ["-screen", "lists", "-listScreen", "chat", "-listEngine", mode, "-listKeyboardGeometryProbe", "YES"]
            app.launch()
            let composer = app.textViews["composer"]
            XCTAssertTrue(composer.waitForExistence(timeout: 10))
            composer.tap(); XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5)); settle()
            let origin = app.coordinate(withNormalizedOffset: .zero), x = app.frame.midX, y = composer.frame.minY - 90
            let high = origin.withOffset(.init(dx: x, dy: y)), low = origin.withOffset(.init(dx: x, dy: y + 35))
            high.press(forDuration: 0.05, thenDragTo: low, withVelocity: .slow, thenHoldForDuration: 0.2)
            low.press(forDuration: 0.05, thenDragTo: high, withVelocity: .slow, thenHoldForDuration: 0.2)
            settle()
            XCTAssertTrue(app.keyboards.firstMatch.exists)
            var state = try keyboardGeometry(app)
            XCTAssertEqual(state["followsComposer"] as? Bool, true, "\(mode): \(state)")
            XCTAssertLessThanOrEqual(state["newestGap"] as? Double ?? 1000, 1.5, "\(mode): \(state)")
            app.buttons["dismissKeyboard"].tap(); settle()
            state = try keyboardGeometry(app)
            XCTAssertLessThanOrEqual(state["newestGap"] as? Double ?? 1000, 1.5, "\(mode): \(state)")
            app.terminate()
        }
    }
    @MainActor func testMultilineComposerKeepsTrailingButtonsInside() throws {
        let app = XCUIApplication(); app.launchArguments = ["-screen", "lists", "-listScreen", "chat", "-listComposerMetrics", "YES"]
        app.launch()
        let composer = app.textViews["composer"], send = app.buttons["Send"], stream = app.buttons["Stream"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        settle()
        let initial = composer.frame.height
        let line = try keyboardGeometry(app)["composerLineHeight"] as? Double ?? 0
        XCTAssertGreaterThan(line, 0)
        composer.tap()
        composer.typeText("First line\nSecond line\nThird line\nFourth line\nFifth line\nSixth line with a long continuation that wraps inside the composer.")
        XCTAssertGreaterThan(composer.frame.height, initial + 20)
        XCTAssertLessThanOrEqual(composer.frame.height, ceil(line * 5 + 16) + 1)
        XCTAssertLessThanOrEqual(composer.frame.height, max(initial, app.frame.height * 0.4) + 1)
        let bar = app.otherElements["composerBar"]
        XCTAssertTrue(bar.frame.contains(send.frame))
        XCTAssertEqual(send.frame.maxX, bar.frame.maxX, accuracy: 2)
        XCTAssertLessThanOrEqual(send.frame.maxX, app.frame.maxX - 8)
        XCTAssertGreaterThanOrEqual(send.frame.minX, stream.frame.maxX)
        XCTAssertGreaterThanOrEqual(stream.frame.minX, composer.frame.maxX)
        XCTAssertEqual(send.frame.maxY, composer.frame.maxY, accuracy: 2)
        app.buttons["Send"].tap()
        settle()
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