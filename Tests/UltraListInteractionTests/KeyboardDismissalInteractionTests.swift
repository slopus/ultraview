#if os(iOS) && canImport(XCTest)
import XCTest

/// Automatic XCTest video is retained by the runner. The app has no geometry
/// probes, markers, timers, or display links added for these interactions.
final class KeyboardDismissalInteractionTests: XCTestCase {
    private enum Scenario: String {
        case slowDismiss, flingDismiss, partialReturn, midwayRelease
        var dismisses: Bool { self == .slowDismiss || self == .flingDismiss }
    }

    @MainActor func testSlowDismissal() throws { try check(.slowDismiss) }
    @MainActor func testFlingDismissal() throws { try check(.flingDismiss) }
    @MainActor func testPartialDragReturns() throws { try check(.partialReturn) }
    @MainActor func testMidwayReleaseReturns() throws { try check(.midwayRelease) }
    @MainActor func testDismissalPreservesListInertia() throws {
        let app = XCUIApplication()
        for mode in ["keyframe", "uiKit", "stepped"] {
            for system in [true, false] {
                var displacement: [Double] = [], travel = 0.0
                for velocity in [160.0, 1200] {
                    app.launchArguments = ["-screen", "lists", "-listScreen", "chat", "-listEngine", mode,
                                           "-listInitialRow", "25", "-chatCards", "YES", "-listSystemKeyboardDismissal", system ? "YES" : "NO"]
                    app.launch()
                    let composer = app.textViews["composer"]
                    XCTAssertTrue(composer.waitForExistence(timeout: 10))
                    composer.tap(); XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5)); settle(0.8)
                    let frame = app.frame, bar = composer.frame
                    let startY = bar.minY - 55, endY = frame.maxY - bar.height - 8
                    travel = endY - startY
                    let before = try rowPosition(app)
                    let origin = app.coordinate(withNormalizedOffset: .zero)
                    let start = origin.withOffset(.init(dx: frame.midX - frame.minX, dy: startY - frame.minY))
                    let end = origin.withOffset(.init(dx: frame.midX - frame.minX, dy: endY - frame.minY))
                    let label = "inertia/\(mode)/\(system ? "system" : "driven")/\(velocity < 500 ? "slow" : "fling")"
                    try XCTContext.runActivity(named: label) { activity in
                        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                        image.name = "\(label)-before"; image.lifetime = .keepAlways; activity.add(image)
                        let metadata: [String: Any] = [
                            "scenario": "inertia", "engine": mode, "system": system, "time": Date().timeIntervalSince1970,
                            "screenWidth": frame.width, "screenHeight": frame.height, "keyboardTop": bar.maxY + 8,
                            "composerBottom": bar.maxY, "startY": startY, "endY": endY, "velocity": velocity, "hold": 0,
                        ]
                        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
                        let details = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                        details.name = "\(label)-geometry"; details.lifetime = .keepAlways; activity.add(details)
                        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .init(rawValue: velocity), thenHoldForDuration: 0)
                        settle(1.2)
                    }
                    displacement.append(abs(try rowPosition(app) - before))
                    app.terminate()
                }
                let label = "\(mode)/\(system ? "system" : "driven")"
                XCTAssertGreaterThan(displacement[1], 2 * travel, "\(label): fling displacement \(displacement), finger \(travel)")
                XCTAssertGreaterThan(displacement[1] - displacement[0], travel * 0.5,
                                     "\(label): the fling must coast farther than the same distance dragged slowly: \(displacement)")
            }
        }
    }

    @MainActor private func check(_ scenario: Scenario) throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        for mode in ["keyframe", "uiKit", "stepped"] {
            for system in [true, false] {
                let label = "\(scenario.rawValue)/\(mode)/\(system ? "system" : "driven")"
                app.launchArguments = ["-screen", "lists", "-listScreen", "chat", "-listEngine", mode,
                                       "-listSystemKeyboardDismissal", system ? "YES" : "NO"]
                app.launch()
                let composer = app.textViews["composer"], keyboard = app.keyboards.firstMatch
                XCTAssertTrue(composer.waitForExistence(timeout: 10), label)
                composer.tap()
                XCTAssertTrue(keyboard.waitForExistence(timeout: 5), label)
                settle(0.8)
                XCTAssertFalse(app.staticTexts["keyboardGeometry"].exists, label)
                let frame = app.frame, composerFrame = composer.frame
                let physicalTop = composerFrame.maxY + 8
                let accessory = composerFrame.height + 8
                let startY = max(app.otherElements["chatList"].frame.minY + 20, composerFrame.minY - 55)
                let endY: Double
                let velocity: Double
                let hold: Double
                switch scenario {
                case .slowDismiss:
                    endY = frame.maxY - accessory; velocity = 160; hold = 0.25
                case .flingDismiss:
                    endY = physicalTop + 110; velocity = 1000; hold = 0
                case .partialReturn:
                    endY = physicalTop + 65; velocity = 160; hold = 0.3
                case .midwayRelease:
                    endY = physicalTop + 90; velocity = 160; hold = 0
                }
                let origin = app.coordinate(withNormalizedOffset: .zero)
                let start = origin.withOffset(.init(dx: frame.midX - frame.minX, dy: startY - frame.minY))
                let end = origin.withOffset(.init(dx: frame.midX - frame.minX, dy: endY - frame.minY))
                try XCTContext.runActivity(named: label) { activity in
                    let before = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                    before.name = "\(label)-before"; before.lifetime = .keepAlways; activity.add(before)
                    let metadata: [String: Any] = [
                        "scenario": scenario.rawValue, "engine": mode, "system": system,
                        "time": Date().timeIntervalSince1970, "screenWidth": frame.width, "screenHeight": frame.height,
                        "keyboardTop": physicalTop, "composerBottom": composerFrame.maxY,
                        "accessoryHeight": accessory, "startY": startY, "endY": endY,
                        "velocity": velocity, "hold": hold,
                    ]
                    let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
                    let details = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                    details.name = "\(label)-geometry"; details.lifetime = .keepAlways; activity.add(details)
                    start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .init(rawValue: velocity), thenHoldForDuration: hold)
                    settle(0.9)
                    let after = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                    after.name = "\(label)-after"; after.lifetime = .keepAlways; activity.add(after)
                }
                if !system {
                    XCTAssertEqual(keyboard.exists, !scenario.dismisses, label)
                }
                app.terminate()
            }
        }
    }

    /// The demo's three repeating card heights are measured from accessibility
    /// frames. Any visible identity then locates the same virtual row origin,
    /// even after the original witness has left the loaded window.
    @MainActor private func rowPosition(_ app: XCUIApplication) throws -> Double {
        // Live index queries can lose a row while the list coasts. Read every
        // identity and frame from the same immutable accessibility snapshot.
        let snapshot = try app.otherElements["chatList"].snapshot()
        let viewport = snapshot.frame
        var rows = snapshot.children
        var heights: [Int: Double] = [:], witnesses: [(Int, CGRect)] = []
        while let row = rows.popLast() {
            rows.append(contentsOf: row.children)
            guard row.elementType == .other, row.identifier.hasPrefix("row-message-") else { continue }
            guard let index = Int(row.identifier.dropFirst("row-message-".count)) else { continue }
            let frame = row.frame
            guard frame.height > 0 else { continue }
            heights[index % 3] = frame.height
            if frame.intersects(viewport) { witnesses.append((index, frame)) }
        }
        XCTAssertEqual(heights.count, 3, "The card-height cycle must be visible before inferring displacement")
        let witness = try XCTUnwrap(witnesses.min { abs($0.1.midY - viewport.midY) < abs($1.1.midY - viewport.midY) })
        var position = witness.1.maxY
        for index in 0..<witness.0 { position += try XCTUnwrap(heights[index % 3]) }
        return position
    }

    @MainActor private func settle(_ seconds: Double) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
#endif