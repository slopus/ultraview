#if os(iOS) && canImport(XCTest)
import XCTest

/// Real-touch scenarios for frame-by-frame video analysis. The host records
/// the screen around each test (`simctl io recordVideo`, or XCTest's own
/// screen recording on a device); the app logs list and keyboard geometry per
/// frame with `-listScenario touch`. Tools/Video/record.py runs them.
/// `VIDEO_ENGINE`, `VIDEO_CLIP` (or `VIDEO_CLIP_PREFIX`, which names each
/// test's log after the test and engine) arrive through the test runner's
/// environment (`TEST_RUNNER_VIDEO_ENGINE=…` on the xcodebuild command line).
/// Without either clip variable the tests skip. Only the UltraViewVideo
/// scheme builds this target.
final class ListVideoTouchTests: XCTestCase {
    @MainActor private lazy var app = XCUIApplication()
    /// When the app's scenario ends and writes its log.
    @MainActor private var scenarioEnd = Date()
    @MainActor private var plain = false

    @MainActor private func launch(_ screen: String, extra: [String] = [], seconds: Double) throws {
        let environment = ProcessInfo.processInfo.environment
        let engine = environment["VIDEO_ENGINE"] ?? "keyframe"
        // `name` reads "-[Class testMethod]".
        let test = name.split(separator: " ").last.map { String($0.dropLast()) } ?? name
        guard let clip = environment["VIDEO_CLIP"] ?? environment["VIDEO_CLIP_PREFIX"].map({ "\($0)\(test)-\(engine)" }) else {
            throw XCTSkip("Video recordings run only from Tools/Video/record.py.")
        }
        // Before a gesture, XCTest answers a system alert in the way with its
        // own handler, which taps the alert's default button. This one runs
        // first: it stops the test and leaves the alert as it is.
        addUIInterruptionMonitor(withDescription: "System alert") { [unowned self] alert in
            MainActor.assumeIsolated {
                continueAfterFailure = false
                XCTFail(SystemAlert(title: alert.label).description)
            }
            return true
        }
        // `VIDEO_PLAIN=1`: the demo exactly as a person launches it, with no
        // scenario (no log, no sampling); the video is the only record.
        plain = environment["VIDEO_PLAIN"] == "1"
        if plain {
            // Of the extra arguments, a plain launch keeps only the code-driven keyboard cycle.
            let cycle = extra.contains("-listKeyboardCycle") ? ["-listKeyboardCycle", "YES"] : []
            app.launchArguments = ["-screen", "lists", "-listScreen", screen, "-listEngine", engine] + cycle
            app.launch()
            settle(2.7)
            return try checkNoSystemAlert()
        }
        // `VIDEO_VIEWS=1`: also log every content view per commit (`-listVideoViews YES`).
        let views: [String] = environment["VIDEO_VIEWS"] == "1" ? ["-listVideoViews", "YES"] : []
        app.launchArguments = ["-screen", "lists", "-listScreen", screen, "-listEngine", engine,
                               "-listScenario", "touch", "-listScenarioDuration", String(seconds), "-listClip", clip,
                               "-listScenarioDelay", "0.5"] + extra + views
        app.launch()
        // Setup, the lead-in and the tail add a few seconds to the scenario.
        scenarioEnd = Date().addingTimeInterval(seconds + 4)
        // Let the scenario's setup and lead-in pass before touching.
        settle(2.2)
        try checkNoSystemAlert()
    }

    private struct SystemAlert: Error, CustomStringConvertible {
        let title: String
        var description: String { "A system alert covers the app: \(title)" }
    }

    /// A system alert (another app's permission prompt on a shared device)
    /// would take the gestures and hide the app, so the test stops instead.
    /// The query goes to SpringBoard, not the app under test; an alert that
    /// appears later reaches the interruption monitor in `launch`.
    @MainActor private func checkNoSystemAlert() throws {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if alert.exists { throw SystemAlert(title: alert.label) }
    }

    /// Keeps the app running until its scenario has written the log.
    @MainActor private func finish() {
        if plain { return settle(1) }
        XCTAssertTrue(app.otherElements["listVideoDone"].waitForExistence(timeout: max(0, scenarioEnd.timeIntervalSinceNow) + 60))
    }

    @MainActor private func settle(_ seconds: Double) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor private func openKeyboard() -> XCUIElement {
        let composer = app.textViews["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        settle(0.6)
        return composer
    }

    @MainActor private func waitForKeyboardToHide() {
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
    }

    @MainActor private func drag(from start: Double, to end: Double, x: Double? = nil, press: Double = 0.05, velocity: XCUIGestureVelocity = .fast, hold: Double = 0) {
        let origin = app.coordinate(withNormalizedOffset: .zero), column = x ?? app.frame.midX
        origin.withOffset(.init(dx: column, dy: start)).press(forDuration: press, thenDragTo: origin.withOffset(.init(dx: column, dy: end)), withVelocity: velocity, thenHoldForDuration: hold)
    }

    // The keyboard gestures and launch arguments match the keyboard
    // interaction tests (`-listKeyboardGeometryProbe YES` adds a Hide button).
    private let keyboardProbe = ["-listKeyboardGeometryProbe", "YES"]

    /// Tap to open, then a fast swipe down through the keyboard.
    @MainActor func testVideoKeyboardFastDismissal() throws {
        try launch("chat", extra: keyboardProbe, seconds: 14)
        let composer = openKeyboard()
        drag(from: composer.frame.minY - 90, to: app.frame.maxY - 180)
        waitForKeyboardToHide()
        settle(1.5)
        finish()
    }

    /// The same, scrolled away from the newest messages.
    @MainActor func testVideoKeyboardFastDismissalAway() throws {
        try launch("chat", extra: keyboardProbe + ["-listInitialRow", "25"], seconds: 14)
        let composer = openKeyboard()
        drag(from: composer.frame.minY - 90, to: app.frame.maxY - 180)
        waitForKeyboardToHide()
        settle(1.5)
        finish()
    }

    /// A slow drag that carries the keyboard down with the finger and holds.
    @MainActor func testVideoKeyboardSlowDismissal() throws {
        try launch("chat", extra: keyboardProbe, seconds: 14)
        let composer = openKeyboard()
        drag(from: composer.frame.minY - 90, to: app.frame.maxY - 70, velocity: .slow, hold: 0.5)
        waitForKeyboardToHide()
        settle(1.5)
        finish()
    }

    /// A slow drag into the keyboard that stops and releases there. The
    /// system decides whether the keyboard returns or hides; the video shows
    /// which, so nothing is asserted.
    @MainActor func testVideoKeyboardReturn() throws {
        try returnDrag(depth: 60)
    }

    /// A slow drag down into the keyboard that holds about half way down
    /// the chat's overlap, then releases there. No probe and no guide marker:
    /// the chat's own layout is all that moves the composer.
    @MainActor func testVideoKeyboardHoldMidway() throws {
        try launch("chat", extra: ["-listVideoNoMarker", "YES"], seconds: 12)
        let composer = openKeyboard()
        let keyboardTop = composer.frame.maxY + 8
        drag(from: composer.frame.minY - 90, to: keyboardTop + 125, velocity: .slow, hold: 0.8)
        settle(2)
        finish()
    }

    /// Landscape: a partial drag into the keyboard, a 0.5 s hold, then release,
    /// so the keyboard returns. The gesture matches the no-probe interaction check.
    @MainActor func testVideoKeyboardLandscapeReturn() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        try launch("chat", extra: ["-listVideoNoMarker", "YES"], seconds: 12)
        let composer = openKeyboard(), keyboard = app.keyboards.firstMatch.frame
        let list = app.otherElements["chatList"].frame.intersection(app.frame)
        let travel = min(100, keyboard.height * 0.3)
        // `VIDEO_DEPTH`: how far below the visible keyboard top (composer bottom + 8) to release instead.
        let depth = ProcessInfo.processInfo.environment["VIDEO_DEPTH"].flatMap(Double.init)
        let end = depth.map { composer.frame.maxY + 8 + $0 } ?? keyboard.minY + travel
        drag(from: max(list.minY + 8, composer.frame.minY - 35), to: end, press: 0.1,
             velocity: .init(rawValue: 120), hold: 0.5)
        settle(2)
        finish()
    }

    /// Plain: the app shows and hides the keyboard from code twice and shows it
    /// again (`-listKeyboardCycle`, about 10 s), then the hold-midway drag and release.
    @MainActor func testVideoKeyboardPlainCycle() throws {
        try launch("chat", extra: ["-listKeyboardCycle", "YES"], seconds: 16)
        settle(8)
        let composer = app.textViews["composer"]
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        settle(1)
        let keyboardTop = composer.frame.maxY + 8
        drag(from: composer.frame.minY - 90, to: keyboardTop + 125, velocity: .slow, hold: 0.8)
        settle(2)
        finish()
    }

    /// The same, released just inside the keyboard.
    @MainActor func testVideoKeyboardReturnShort() throws {
        try returnDrag(depth: 25)
    }

    @MainActor private func returnDrag(depth: Double) throws {
        try launch("chat", extra: keyboardProbe, seconds: 14)
        let composer = openKeyboard()
        let keyboardTop = app.keyboards.firstMatch.frame.minY
        drag(from: composer.frame.minY - 90, to: keyboardTop + depth, velocity: .slow, hold: 0.5)
        settle(2)
        finish()
    }

    /// A drag that ends above the keyboard: it stays open and the list coasts.
    @MainActor func testVideoKeyboardPartialDrag() throws {
        try launch("chat", extra: keyboardProbe, seconds: 14)
        let composer = openKeyboard()
        drag(from: composer.frame.minY - 40, to: composer.frame.minY + 20, velocity: .slow, hold: 0.2)
        settle(2)
        finish()
    }

    /// Real keystrokes with the keyboard up: words until the composer grows
    /// line by line to five lines, then deletes back to one line, then Hide.
    /// Each call is followed by a pause, so each wrap stands alone in the
    /// video, and the app logs every text change.
    @MainActor func testVideoComposerTyping() throws {
        try typeAndDelete(extra: [])
    }

    /// The same, scrolled away from the newest messages.
    @MainActor func testVideoComposerTypingAway() throws {
        try typeAndDelete(extra: ["-listInitialRow", "25"])
    }

    @MainActor private func typeAndDelete(extra: [String]) throws {
        try launch("chat", extra: keyboardProbe + extra, seconds: 80)
        let composer = openKeyboard()
        let text = "Typing until the composer wraps onto a second line, then a third line, a fourth line and finally a fifth line of text so it grows five lines"
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map { $0 + " " }
        for word in words {
            composer.typeText(String(word))
            settle(0.3)
        }
        settle(0.6)
        // A few deletes per call; each call costs XCUITest about half a second.
        var remaining = words.joined().count
        while remaining > 0 {
            let count = min(3, remaining)
            composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count))
            remaining -= count
            settle(0.25)
        }
        settle(0.8)
        if app.buttons["Hide"].exists { app.buttons["Hide"].tap() }
        settle(1.5)
        finish()
    }

    /// The manual flow from the demo's default chat: open the keyboard, tap
    /// Stream, and while the reply streams type and Send twice (about 0.5 s
    /// and 1.5 s in), then Send once more after the stream ends.
    @MainActor func testVideoStreamThenSend() throws {
        // Message cards, as in the first recordings, whatever the chat's default.
        try launch("chat", extra: ["-listVideoViews", "YES", "-chatCards", "YES"], seconds: 16)
        let composer = openKeyboard()
        let stream = app.buttons["Stream"], send = app.buttons["Send"]
        stream.tap()
        let started = Date()
        func at(_ seconds: Double) { settle(max(0, seconds - Date().timeIntervalSince(started))) }
        at(0.3)
        composer.typeText("First")
        at(0.5)
        send.tap()
        at(1.3)
        composer.typeText("Second")
        at(1.5)
        send.tap()
        at(5.5)
        composer.typeText("After")
        send.tap()
        settle(2)
        finish()
    }

    /// Flings toward older messages and back in the chat.
    @MainActor func testVideoChatFlings() throws {
        try launch("chat", seconds: 7)
        drag(from: app.frame.height * 0.35, to: app.frame.height * 0.75, press: 0.03)
        settle(2.5)
        drag(from: app.frame.height * 0.75, to: app.frame.height * 0.3, press: 0.03)
        settle(2.5)
        finish()
    }

    /// Flings down and up the 10k feed.
    @MainActor func testVideoFeedFlings() throws {
        try launch("feed", seconds: 7)
        drag(from: app.frame.height * 0.8, to: app.frame.height * 0.3, press: 0.03)
        settle(2.5)
        drag(from: app.frame.height * 0.35, to: app.frame.height * 0.8, press: 0.03)
        settle(2.5)
        finish()
    }

    /// The feed's far jump with real taps: 5,000, then Top, which lands on
    /// the first carousel.
    @MainActor func testVideoFeedJump() throws {
        try launch("feed", seconds: 8)
        app.buttons["5,000"].tap()
        settle(3)
        app.buttons["Top"].tap()
        settle(3)
        finish()
    }

    /// The swipe probe's JSON (`-listSwipeProbe YES`): row frames in screen points.
    @MainActor private func swipeProbe() throws -> [String: Any] {
        XCTAssertTrue(app.staticTexts["swipeProbe"].waitForExistence(timeout: 10))
        let text = try XCTUnwrap(app.staticTexts["swipeProbe"].value as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @MainActor private func swipe(from: CGPoint, to: CGPoint, speed: Double, hold: Double = 0) {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: from.x, dy: from.y)).press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: to.x, dy: to.y)),
                                                                  withVelocity: XCUIGestureVelocity(rawValue: speed), thenHoldForDuration: hold)
    }

    /// With the keyboard up: reveal Reply on the newest message and tap it,
    /// then delete the next message with a full swipe. On message cards: the
    /// chat's bubbles are mostly shorter than the rows it swipes.
    @MainActor func testVideoChatSwipes() throws {
        try launch("chat", extra: keyboardProbe + ["-listSwipeProbe", "YES", "-chatCards", "YES"], seconds: 14)
        let composer = openKeyboard()
        let top = composer.frame.minY - 12
        func visible() throws -> [CGRect] {
            try ((swipeProbe()["rowFrames"] as? [String: [Double]]) ?? [:]).values.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
                .filter { $0.maxY < top && $0.minY > 0 && $0.height > 60 }.sorted { $0.minY > $1.minY }
        }
        let first = try XCTUnwrap(try visible().first)
        swipe(from: .init(x: first.minX + 30, y: first.midY), to: .init(x: first.minX + 150, y: first.midY), speed: 300, hold: 0.15)
        settle(0.8)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: first.minX + 30, dy: first.midY)).tap()
        settle(1)
        let second = try XCTUnwrap(try visible().dropFirst().first)
        swipe(from: .init(x: second.maxX - 15, y: second.midY), to: .init(x: second.minX + 15, y: second.midY), speed: 1500)
        settle(2)
        finish()
    }

    /// The feed's carousel: a fast swipe toward later cards, then a slow one back.
    @MainActor func testVideoFeedCarousel() throws {
        try launch("feed", extra: ["-listSwipeProbe", "YES"], seconds: 9)
        let values = try XCTUnwrap((try swipeProbe()["rowFrames"] as? [String: [Double]])?["carousel-2"])
        let frame = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        swipe(from: .init(x: frame.maxX - 40, y: frame.midY), to: .init(x: frame.minX + 60, y: frame.midY), speed: 1500)
        settle(2.5)
        swipe(from: .init(x: frame.minX + 60, y: frame.midY), to: .init(x: frame.maxX - 40, y: frame.midY), speed: 400)
        settle(2)
        finish()
    }

    /// Across: flings in the left-to-right list, then in the right-to-left one.
    @MainActor func testVideoAcrossFlings() throws {
        try launch("horizontal", seconds: 10)
        for identifier in ["horizontalList", "horizontalListRTL"] {
            let list = app.otherElements[identifier]
            XCTAssertTrue(list.waitForExistence(timeout: 5), identifier)
            let frame = list.frame
            let right = CGPoint(x: frame.maxX - 40, y: frame.midY), left = CGPoint(x: frame.minX + 40, y: frame.midY)
            // Toward later cards first: leftward in LTR, rightward in RTL.
            let (forward, back) = identifier == "horizontalList" ? (right, left) : (left, right)
            swipe(from: forward, to: back, speed: 1500)
            settle(2)
            swipe(from: back, to: forward, speed: 1500)
            settle(2)
        }
        finish()
    }

    /// One real drag in the keyframe pane drives all three Compare panes.
    @MainActor func testVideoCompareSharedDrag() throws {
        try launch("compare", seconds: 7)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.75))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.35))
        start.press(forDuration: 0.03, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        settle(2.5)
        end.press(forDuration: 0.03, thenDragTo: start, withVelocity: .fast, thenHoldForDuration: 0)
        settle(2.5)
        finish()
    }
}
#endif
