#if os(iOS) && canImport(XCTest)
import XCTest

/// The chat's bottom gravity under real touches, measured every display
/// frame by the app's ListGravityProbe: the row under a finger stays under it
/// while the collection changes around it, and a reply streamed at the
/// newest message is followed by the budget, then left to grow below.
final class BottomGravityInteractionTests: XCTestCase {
    @MainActor private func launch(_ engine: String, scenario: String, initialRow: Int) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "lists", "-listScreen", "chat", "-chatCards", "YES", "-listEngine", engine,
                               "-listInitialRow", "\(initialRow)", "-listGravityProbe", "YES", "-listGravityScenario", scenario]
        app.launch()
        return app
    }

    @MainActor private func report(_ app: XCUIApplication, complete: Bool, timeout: Double) throws -> [String: Any] {
        let probe = app.staticTexts["gravityProbe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 15), "the probe never published")
        let deadline = Date().addingTimeInterval(timeout)
        var latest: [String: Any] = [:]
        while Date() < deadline {
            if let text = probe.value as? String, let data = text.data(using: .utf8),
               let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                latest = document
                if document[complete ? "complete" : "ready"] as? Bool == true { return document }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTFail("the probe did not \(complete ? "complete" : "start") in \(timeout) s: \(latest)")
        return latest
    }

    @MainActor func testTheRowUnderTheFingerStaysUnderItWhileContentChanges() throws {
        for engine in ["keyframe", "stepped", "uiKit"] {
            for initialRow in [25, 0] {
                let name = "\(engine)/\(initialRow == 0 ? "newest" : "history")"
                let app = launch(engine, scenario: "hold", initialRow: initialRow)
                _ = try report(app, complete: false, timeout: 15)
                // Press, drag slowly toward older messages, then rest on the row.
                let start = app.windows.firstMatch.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
                start.press(forDuration: 0.4, thenDragTo: start.withOffset(.init(dx: 0, dy: 80)),
                            withVelocity: XCUIGestureVelocity(120), thenHoldForDuration: 2.5)
                let document = try report(app, complete: true, timeout: 20)
                print("Gravity hold \(name): \(document)")
                XCTAssertFalse((document["touched"] as? String ?? "").isEmpty, "\(name): no row under the finger")
                XCTAssertGreaterThan(document["holdFrames"] as? Int ?? 0, 60, name)
                XCTAssertGreaterThanOrEqual((document["mutations"] as? [String] ?? []).count, 14, name)
                XCTAssertEqual(document["missingFrames"] as? Int, 0, name)
                XCTAssertLessThanOrEqual(document["holdMaxError"] as? Double ?? 1000, 0.5, "\(name): the row slid under a resting finger \(document["worst"] ?? "")")
                // Moving, the finger and the frame it shows can be one touch sample apart.
                let step = document["dragMaxStep"] as? Double ?? 0
                XCTAssertLessThanOrEqual(document["dragMaxError"] as? Double ?? 1000, max(1, step) + 0.5, "\(name): the row slid under a moving finger")
                XCTAssertEqual(document["following"] as? Bool, false, "\(name): a drag stops following")
                app.terminate()
            }
        }
    }

    @MainActor func testAReplyAtTheNewestIsFollowedByTheBudgetThenGrowsBelow() throws {
        for engine in ["keyframe", "stepped", "uiKit"] {
            let app = launch(engine, scenario: "stream", initialRow: 0)
            _ = try report(app, complete: false, timeout: 15)
            app.buttons["Stream"].tap()
            let document = try report(app, complete: true, timeout: 30)
            print("Gravity stream \(engine): \(document)")
            let budget = try XCTUnwrap(document["budget"] as? Double, engine)
            XCTAssertGreaterThan(budget, 30, engine)
            XCTAssertGreaterThan(document["streamFrames"] as? Int ?? 0, 60, engine)
            XCTAssertLessThanOrEqual(document["riseMax"] as? Double ?? 1000, budget + 0.5, "\(engine): followed past the budget")
            XCTAssertEqual(document["finalRise"] as? Double ?? -1, budget, accuracy: 0.5, "\(engine): didn't follow the budget")
            XCTAssertEqual(document["following"] as? Bool, false, engine)
            XCTAssertGreaterThan(document["distanceFromBottom"] as? Double ?? 0, 100, "\(engine): the reply didn't go on below")
            app.terminate()
        }
    }
}
#endif
