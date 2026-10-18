#if os(iOS) && canImport(XCTest)
import XCTest

/// Chat bubbles keep their edges on their rows' edges, their time in its
/// corner and their text in place in every frame while replies stream,
/// drafts are sent and messages are edited. The app's probe presses the real
/// buttons and samples presentation geometry; see ChatBubbleProbe.
final class ChatBubbleInteractionTests: XCTestCase {
    @MainActor private func report(_ app: XCUIApplication, timeout: Double) -> [String: Any] {
        let probe = app.staticTexts["chatBubbleGeometry"]
        XCTAssertTrue(probe.waitForExistence(timeout: 15), "the probe never published")
        let deadline = Date().addingTimeInterval(timeout)
        var latest: [String: Any] = [:]
        while Date() < deadline {
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

    @MainActor private func run(variants: [String], scenarios: [String]? = nil, timeout: Double) {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "lists", "-listScreen", "chat", "-chatBubbleProbe", "YES",
                               "-chatBubbleVariants", variants.joined(separator: ",")]
        if let scenarios { app.launchArguments += ["-chatBubbleScenarios", scenarios.joined(separator: ",")] }
        app.launch()
        let document = report(app, timeout: timeout)
        XCTAssertNil(document["failure"], "\(document["failure"] ?? "")")
        let results = document["scenarios"] as? [[String: Any]] ?? []
        XCTAssertEqual(results.count, variants.count * (scenarios?.count ?? 7), "\(document)")
        for result in results {
            let scenario = result["scenario"] as? String ?? "?"
            let name = "\(result["variant"] as? String ?? "?")/\(scenario)"
            print("Chat bubbles \(name): \(result)")
            XCTAssertEqual(result["violationCount"] as? Int, 0, "\(name) violations \(result["violations"] ?? "") first \(result["firstViolations"] ?? "")")
            XCTAssertEqual(result["settled"] as? Bool, true, "\(name) still animating: \(result["lingering"] ?? "")")
            XCTAssertLessThanOrEqual(result["staleMax"] as? Double ?? 1000, 0.5, "\(name): presentation differs from model at rest")
            XCTAssertGreaterThan(result["restingRows"] as? Int ?? 0, 0, name)
            XCTAssertEqual(result["mainThreadWork"] as? Int, 0, "\(name): the main thread measured, laid out or drew")
            if scenario == "streamPerf" {
                // A Debug build, and the test's own queries take the main
                // thread; this only catches regressions. Release streaming is
                // measured with the probe outside a UI test (Docs/UltraList.md).
                XCTAssertEqual(result["finalRevision"] as? Int, 40, name)
                XCTAssertLessThan(result["turnP99Milliseconds"] as? Double ?? 1000, 8, "\(name): main-thread turns")
                continue
            }
            XCTAssertGreaterThan(result["bubbleSamples"] as? Int ?? 0, 0, "\(name): no bubble was sampled")
            XCTAssertEqual(result["blankFrames"] as? Int, 0, name)
            if scenario.lowercased().contains("send") {
                // A sent bubble starts at the field: its first sampled frame
                // is no farther from it than its own motion explains. A send
                // that joins a stream's spring leaves the field at speed, and
                // a busy main thread can miss the first frame.
                let excess = result["sentFirstExcessMax"] as? Double ?? 1000
                XCTAssertLessThanOrEqual(excess, 0.5, "\(name): a sent bubble didn't start at the field: \(result["sentFirsts"] ?? "")")
                XCTAssertLessThan(result["sentMaxStepFraction"] as? Double ?? 1, 0.3, "\(name): the sent bubble jumped")
            }
            if scenario.lowercased().contains("stream") {
                XCTAssertGreaterThan(result["appearSamples"] as? Int ?? 0, 0, "\(name): the reply's appearance wasn't sampled")
            }
            // A bubble's edges follow its row's: the row never clips it and
            // its padding never steps.
            let edges = result["edges"] as? [String: Any] ?? [:]
            XCTAssertEqual(edges["clipFrames"] as? Int, 0, "\(name): rows clipped bubbles \(edges["padStepWorst"] ?? "")")
            XCTAssertLessThanOrEqual(edges["padStepMax"] as? Double ?? 1000, 1.5, "\(name): a bubble's padding stepped \(edges["padStepWorst"] ?? "")")
            XCTAssertEqual(edges["hostOverlapFrames"] as? Int, 0, "\(name): a row showed two hosts")
        }
        app.terminate()
    }

    @MainActor func testBubblesStayOnTheirRowsInEveryEngine() {
        run(variants: ["uiKit/light/default", "stepped/light/default", "keyframe/light/default"], timeout: 420)
    }

    @MainActor func testBubblesStayOnTheirRowsInDarkModeAndLargeText() {
        run(variants: ["keyframe/dark/default", "uiKit/light/ax3", "stepped/dark/ax3"],
            scenarios: ["stream", "send", "multilineSend", "edit"], timeout: 360)
    }
}
#endif
