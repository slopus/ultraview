#if os(iOS) && canImport(XCTest)
import XCTest

final class ComposerKeystrokeInteractionTests: XCTestCase {
    @MainActor func testNativeInputAndComposerResizeTogetherAtNewest() throws { try check(initialRow: 0) }
    @MainActor func testNativeInputAndComposerResizeTogetherAwayFromNewest() throws { try check(initialRow: 25) }

    @MainActor private func check(initialRow: Int) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "lists", "-listScreen", "chat", "-listInitialRow", "\(initialRow)", "-listComposerKeystrokeProbe", "YES"]
        app.launch()
        let report = app.staticTexts["composerKeystroke"]
        XCTAssertTrue(report.waitForExistence(timeout: 15))
        let deadline = Date().addingTimeInterval(90)
        var document: [String: Any] = [:]
        while Date() < deadline {
            guard app.state != .notRunning else { XCTFail("the input probe exited"); return }
            if let value = report.value as? String, let data = value.data(using: .utf8),
               let next = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                document = next
                if next["complete"] as? Bool == true { break }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertEqual(document["complete"] as? Bool, true)
        XCTAssertNil(document["failure"], "\(document)")
        let phases = try XCTUnwrap(document["phases"] as? [[String: Any]])
        XCTAssertEqual(phases.count, 18)
        for phase in phases {
            let name = "\(phase["engine"] ?? "?")/\(phase["phase"] ?? "?")/\(initialRow)"
            let trace = try XCTUnwrap(phase["trace"] as? [[String: Any]], name)
            let before = try XCTUnwrap(trace.first), end = try XCTUnwrap(trace.last)
            func number(_ entry: [String: Any], _ key: String) throws -> Double {
                try XCTUnwrap(entry[key] as? Double, "\(name)/\(key)")
            }
            let startHeight = try number(before, "barHeight"), finalDelta = try number(end, "barHeight") - startHeight
            let displays = trace.filter { $0["event"] as? String == "display" }
            XCTAssertGreaterThan(displays.count, 8, name)
            XCTAssertGreaterThan(displays.filter { $0["glyphBottom"] != nil }.count, 8, name)
            for frame in displays {
                let height = try number(frame, "barHeight") - startHeight
                XCTAssertLessThanOrEqual(min(abs(height), abs(height - finalDelta)), 0.5, "\(name): input height eased behind native text")
                let bar = try number(frame, "barTop") - number(before, "barTop")
                let row = try number(frame, "row") - number(before, "row")
                let text = try number(frame, "textTop") - number(before, "textTop")
                XCTAssertEqual(row, bar, accuracy: 1, name)
                XCTAssertEqual(text, bar, accuracy: 1, name)
                let caret = try number(frame, "nativeCaretBottom") - number(frame, "textTop")
                    - (number(before, "nativeCaretBottom") - number(before, "textTop"))
                XCTAssertEqual(caret, height, accuracy: 1, "\(name): native caret and bar changed in different frames")
                // Native text replaces its fragment layers during an edit. A new
                // fragment has no presentation until its first committed frame.
                if frame["glyphBottom"] != nil {
                    let glyphSpan = try number(frame, "glyphBottom") - number(frame, "glyphTop")
                        - (number(before, "glyphBottom") - number(before, "glyphTop"))
                    XCTAssertEqual(glyphSpan, height, accuracy: 1, "\(name): glyph layout and bar changed in different frames")
                    XCTAssertLessThanOrEqual(try number(frame, "glyphBottom"), try number(frame, "textBottom") + 1, name)
                }
                XCTAssertLessThanOrEqual(try number(frame, "nativeCaretBottom"), try number(frame, "textBottom") + 1, name)
            }
            if initialRow > 0 { XCTAssertGreaterThan(phase["firstIndex"] as? Int ?? 0, 10, name) }
            print("Composer native input \(name): \(displays.count) frames, height delta \(finalDelta)")
        }
        app.terminate()
    }
}
#endif