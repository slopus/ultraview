#if os(iOS) && canImport(XCTest)
import XCTest

/// Sending while a reply streams must keep every visible pair of chat rows at
/// its declared gap, in each engine. The app's probe presses the real buttons
/// and samples presentation geometry every frame; see ListStreamSendProbe.
final class StreamSendInteractionTests: XCTestCase {
    @MainActor private func report(_ app: XCUIApplication, timeout: Double) throws -> [String: Any] {
        let probe = app.staticTexts["streamSendGeometry"]
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

    @MainActor func testSendDuringStreamKeepsRowsWelded() throws {
        let app = XCUIApplication()
        for engine in ["uiKit", "stepped", "keyframe"] {
            app.launchArguments = ["-screen", "lists", "-listScreen", "chat", "-listEngine", engine,
                                   "-listStreamSendProbe", "YES", "-listStreamSendEngines", engine]
            app.launch()
            let document = try report(app, timeout: 150)
            XCTAssertNil(document["failure"], "\(engine): \(document["failure"] ?? "")")
            let scenarios = document["scenarios"] as? [[String: Any]] ?? []
            XCTAssertEqual(scenarios.count, 4, "\(engine): \(document)")
            for scenario in scenarios {
                let name = "\(engine)/\(scenario["scenario"] as? String ?? "?")"
                print("Stream/send \(name): \(scenario)")
                XCTAssertEqual(scenario["violationCount"] as? Int, 0, "\(name) violations \(scenario["violations"] ?? "") first \(scenario["firstViolations"] ?? "")")
                XCTAssertGreaterThan(scenario["strictPairSamples"] as? Int ?? 0, 0, "\(name): no visible pair was sampled")
                XCTAssertLessThanOrEqual(scenario["maxGapError"] as? Double ?? 1000, 0.5, "\(name) worst \(scenario["worstGap"] ?? "")")
                XCTAssertEqual(scenario["nonFinite"] as? Int, 0, name)
                XCTAssertEqual(scenario["settled"] as? Bool, true, "\(name) still animating: \(scenario["lingeringAnimations"] ?? "")")
                XCTAssertLessThanOrEqual(scenario["staleMax"] as? Double ?? 1000, 0.5, "\(name): presentation differs from model at rest")
                XCTAssertLessThanOrEqual(scenario["settledMax"] as? Double ?? 1000, 0.5, "\(name): model differs from settled frames")
                XCTAssertEqual(scenario["heightMismatch"] as? Int, 0, name)
                XCTAssertEqual(scenario["finalNonFinite"] as? Int, 0, name)
                XCTAssertLessThanOrEqual(abs(scenario["newestGapToInset"] as? Double ?? 1000), 0.5, "\(name): newest row is off the inset line")
                XCTAssertLessThanOrEqual(abs(scenario["newestGapToComposer"] as? Double ?? 1000), 0.5, "\(name): newest row does not meet the composer")
                XCTAssertEqual(scenario["modelOK"] as? Bool, true, "\(name): \(scenario["modelProblems"] ?? "")")
                let hits = scenario["midGrowHits"] as? [[String: Any]] ?? []
                XCTAssertTrue(hits.contains { $0["required"] as? Bool == true }, "\(name): no send was scheduled mid-grow")
                if scenario["scenario"] as? String == "keyboardSendMidGrow" {
                    XCTAssertEqual(scenario["keyboardVisible"] as? Bool, true, "\(name): the software keyboard did not appear")
                }
            }
            app.terminate()
        }
    }
}
#endif
