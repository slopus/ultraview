#if canImport(UIKit) && !SWIFT_PACKAGE
import XCTest

/// Runs separately from the unit tests: timing assertions need Release and
/// an otherwise idle device. The JSON attachment preserves every phase,
/// including startup and rotation, even when a frame budget is exceeded.
@MainActor
final class PerformanceTests: XCTestCase {
    func testMainThreadRegression() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["-perfRun", "YES", "-perfBackground", "YES"]
        let scenario = XCTDarwinNotificationExpectation(notificationName: "dev.ultraview.demo.perf.scenario-done")
        let done = XCTDarwinNotificationExpectation(notificationName: "dev.ultraview.demo.perf.done")
        app.launch()
        await fulfillment(of: [scenario], timeout: 240)

        XCUIDevice.shared.press(.home)
        app.activate()
        await fulfillment(of: [done], timeout: 30)
        let label = app.staticTexts["perf.result"]
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        let data = Data(label.label.utf8)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Main thread performance"
        attachment.lifetime = .keepAlways
        add(attachment)
        let report = try JSONDecoder().decode(Report.self, from: data)
        XCTAssertEqual(report.configuration, "Release", "Use the UltraViewPerformance scheme")
        XCTAssertEqual(report.mainThreadWork, 0, "Layout, text and drawing must stay off the main thread")
        XCTAssertEqual(Set(report.hosts.keys), Set(["layout", "feed", "stress"]))
        for (name, host) in report.hosts {
            XCTAssertTrue(host.maxApplyMs.isFinite && host.maxApplyMs >= 0)
            XCTAssertLessThanOrEqual(host.maxApplyMs, 50, "\(name): applying library commits exceeded 50 ms")
        }
        let required: Set<String> = [
            "launch", "first feed", "first stress", "first layout again",
            "tab switches", "rapid tab switches", "feed fling down", "feed fling up",
            "feed jumps", "stress", "rotation", "idle", "background", "return from background",
        ]
        XCTAssertEqual(Set(report.phases.map(\.phase)), required)
        for phase in report.phases {
            XCTAssertTrue(phase.maxTurnMs.isFinite && phase.maxTurnMs >= 0)
        }
        #if targetEnvironment(simulator)
        for phase in report.phases {
            // Scene creation and restoration include synchronous system work.
            // Library application is bounded separately above; the strict
            // frame benchmark still includes these recorded lifecycle turns.
            let lifecycle = phase.phase == "launch" || phase.phase == "return from background"
            let budget = lifecycle ? 200.0 : 50.0
            XCTAssertLessThanOrEqual(phase.maxTurnMs, budget, "\(phase.phase): main thread exceeded \(budget) ms")
        }
        #else
        let budgets: [String: Double] = [
            "launch": 200, "first feed": 50, "tab switches": 1000 / 30,
            "rapid tab switches": 25, "feed jumps": 1000 / 30,
            "rotation": 1000 / 15, "background": 50, "return from background": 200,
        ]
        for phase in report.phases {
            let budget = budgets[phase.phase] ?? 1000 / 60
            XCTAssertLessThanOrEqual(phase.maxTurnMs, budget, "\(phase.phase): main thread exceeded \(budget) ms")
        }
        #endif
    }

    private struct Report: Decodable {
        struct Phase: Decodable {
            let phase: String
            let maxTurnMs: Double
        }
        let configuration: String
        let mainThreadWork: Int
        let phases: [Phase]
        let hosts: [String: Host]
        struct Host: Decodable { let maxApplyMs: Double }
    }
}
#endif