#if os(iOS) && canImport(XCTest)
import XCTest

final class ComposerClearInteractionTests: XCTestCase {
    @MainActor private func timingReport(_ app: XCUIApplication, timeout: Double) throws -> [String: Any] {
        let probe = app.staticTexts["composerTiming"]
        XCTAssertTrue(probe.waitForExistence(timeout: 15), "the probe never published")
        let deadline = Date().addingTimeInterval(timeout)
        var latest: [String: Any] = [:]
        while Date() < deadline {
            guard app.state != .notRunning else { XCTFail("the composer probe exited before reporting"); return latest }
            if let text = probe.value as? String, let data = text.data(using: .utf8),
               let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                latest = document
                if document["complete"] as? Bool == true { return document }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        XCTFail("the probe did not complete in \(timeout) s: \(latest)")
        return latest
    }

    @MainActor func testClearAlternativesAgainstTheTextSetter() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "lists", "-listScreen", "chat", "-listComposerTiming", "YES", "-listComposerTimingRuns", "4"]
        app.launch()
        let document = try timingReport(app, timeout: 300)
        XCTAssertNil(document["failure"], "\(document["failure"] ?? "")")
        XCTAssertEqual(document["keyboardVisible"] as? Bool, true)
        let equivalence = try XCTUnwrap(document["clearEquivalence"] as? [String: Any])
        for draft in ["plain", "typed", "marked"] {
            let entry = try XCTUnwrap(equivalence[draft] as? [String: Any], draft)
            let setter = try XCTUnwrap(entry["textSetter"] as? [String: Any], draft)
            let before = setter["before"] as? [String: Any] ?? [:]
            XCTAssertEqual(setter["firstResponder"] as? Bool, true, draft)
            if draft == "marked" { XCTAssertEqual(before["marked"] as? Bool, true) }
            let rested = setter["rested"] as? [String: Any] ?? [:]
            XCTAssertEqual(rested["text"] as? String, "", draft)
            XCTAssertEqual(rested["selected"] as? String, "{0, 0}", draft)
            XCTAssertEqual(rested["marked"] as? Bool, false, draft)
            XCTAssertEqual(rested["placeholderVisible"] as? Bool, true, draft)
            XCTAssertEqual(rested["typingFont"] as? String, rested["font"] as? String, draft)
            let typed = setter["typed"] as? [String: Any] ?? [:]
            XCTAssertEqual(typed["text"] as? String, "Next", draft)
            XCTAssertEqual(typed["selected"] as? String, "{4, 0}", draft)
            XCTAssertEqual(typed["fontAt0"] as? String, typed["font"] as? String, draft)
            XCTAssertEqual(typed["colorAt0"] as? String, typed["textColor"] as? String, draft)
            print("Composer clear \(draft) differences: \(entry["differences"] ?? "")")
        }
        print("Composer clear savings: \(document["clearSavingsVsSetter"] ?? "")")
        print("Composer clear unproven: \(document["clearUnproven"] ?? "")")
    }

    @MainActor func testSendThenTypeWithTheRealKeyboard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "lists", "-listScreen", "chat"]
        app.launch()
        let composer = app.textViews["composer"], send = app.buttons["Send"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let single = composer.frame.height
        composer.typeText("First line\nSecond line\nThird line")
        XCTAssertGreaterThan(composer.frame.height, single + 20)
        send.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(composer.value as? String ?? "", "")
        XCTAssertLessThanOrEqual(composer.frame.height, single + 1)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        composer.typeText("Next")
        XCTAssertEqual(composer.value as? String, "Next")
        send.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(composer.value as? String ?? "", "")
    }
}
#endif