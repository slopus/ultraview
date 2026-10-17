#if os(iOS) && canImport(XCTest)
import XCTest

final class ComposerMotionInteractionTests: XCTestCase {
    @MainActor func testProgrammaticInputMotionPushesContentAwayFromNewest() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "lists", "-listScreen", "chat", "-listInitialRow", "25", "-listComposerMotionProbe", "YES"]
        app.launch()
        let report = app.staticTexts["composerMotion"]
        XCTAssertTrue(report.waitForExistence(timeout: 15))
        let deadline = Date().addingTimeInterval(90)
        var document: [String: Any] = [:]
        while Date() < deadline {
            guard app.state != .notRunning else { XCTFail("the composer motion probe exited"); return }
            if let text = report.value as? String, let data = text.data(using: .utf8),
               let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                document = value
                if value["complete"] as? Bool == true { break }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertEqual(document["complete"] as? Bool, true)
        XCTAssertNil(document["failure"], "\(document)")
        let phases = try XCTUnwrap(document["phases"] as? [[String: Any]])
        XCTAssertEqual(phases.count, 21)
        for phase in phases {
            let name = "\(phase["engine"] ?? "?")/\(phase["phase"] ?? "?")"
            print("Composer motion \(name): \(phase)")
            XCTAssertEqual(phase["nonFinite"] as? Int, 0, name)
            XCTAssertGreaterThan(phase["samples"] as? Int ?? 0, 8, name)
            XCTAssertLessThanOrEqual(phase["maxRelativeGap"] as? Double ?? 1000, 0.5, name)
            let bar = phase["composerDelta"] as? Double ?? 0, row = phase["rowDelta"] as? Double ?? 1000
            XCTAssertGreaterThan(abs(bar), 8, "\(name): the composer never moved")
            XCTAssertEqual(row, bar, accuracy: 0.5, name)
            XCTAssertGreaterThan(phase["firstIndex"] as? Int ?? 0, 10, "\(name): content reached newest")
        }
        let drafts = try XCTUnwrap(document["nextDrafts"] as? [[String: Any]])
        XCTAssertEqual(drafts.count, 3)
        for draft in drafts {
            let name = draft["engine"] as? String ?? "?"
            XCTAssertEqual(draft["sendStillPreparing"] as? Bool, true, name)
            XCTAssertEqual(draft["newDraftRetained"] as? Bool, true, name)
            let old = draft["oldHeight"] as? Double ?? 1000, immediate = draft["immediateHeight"] as? Double ?? 0
            XCTAssertGreaterThan(immediate, old + 20, "\(name): ordinary typing waited for Send preparation")
            XCTAssertEqual(draft["finalHeight"] as? Double ?? 0, immediate, accuracy: 0.5, name)
        }
        app.terminate()
    }
}
#endif