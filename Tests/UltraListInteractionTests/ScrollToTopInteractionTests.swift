#if os(iOS) && canImport(XCTest)
import XCTest
import UIKit

/// A tap on the status bar, or on the tab that is already selected, scrolls
/// the list to the edge shown at the top. The app runs without probes: the
/// screen is captured from the test process while the tap runs, and the row
/// at the top is read from accessibility once it lands.
final class ScrollToTopInteractionTests: XCTestCase {
    private let engines = ["uiKit", "stepped", "keyframe"]

    @MainActor private func launch(_ screen: String, engine: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "lists", "-listScreen", screen, "-listEngine", engine]
        app.launch()
        return app
    }
    @MainActor private func pause(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    @MainActor private func row(_ app: XCUIApplication, _ identity: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "row-\(identity)").firstMatch
    }
    /// Taps the status bar's left side (the clock, clear of the camera
    /// cutout), or the selected tab, capturing the list while it moves. The
    /// list must move, reach the picture it rests at within `limit` seconds,
    /// and then not change again: no jump or bounce once it lands.
    @MainActor private func tapAndWatch(_ app: XCUIApplication, list: XCUIElement, tab: Bool = false, limit: Double = 1.2, _ label: String) {
        let region = list.frame.intersection(app.frame)
        let capture = ListCapture(region: region, screen: app.frame.size)
        capture.capture()
        let timer = Timer(timeInterval: 0.04, repeats: true) { _ in MainActor.assumeIsolated { capture.capture() } }
        RunLoop.main.add(timer, forMode: .common)
        if tab { app.tabBars.buttons["Lists"].tap() }
        else { app.coordinate(withNormalizedOffset: .init(dx: 0, dy: 0)).withOffset(.init(dx: 60, dy: 20)).tap() }
        let start = capture.frames.count
        RunLoop.current.run(until: Date().addingTimeInterval(limit + 0.6))
        timer.invalidate()
        let frames = capture.frames, rest = frames[frames.count - 1]
        let differences = frames.map { ListCapture.difference($0.pixels, rest.pixels) }
        print("Scroll to top \(label): " + zip(frames, differences).map { String(format: "%.2fs %.1f", $0.0.time - frames[0].time, $0.1) }.joined(separator: ", "))
        XCTAssertGreaterThan(frames.count - start, 6, "\(label): too few screens captured")
        XCTAssertGreaterThan(differences[0], 2, "\(label): the list was already at the top")
        guard let landed = differences.firstIndex(where: { $0 < 1 }) else { XCTFail("\(label): never came to rest"); return }
        XCTAssertLessThan(frames[landed].time - frames[0].time, limit, "\(label): landed late")
        for index in landed..<frames.count {
            XCTAssertLessThan(differences[index], 1, "\(label): changed again \(frames[index].time - frames[landed].time) s after landing")
        }
    }
    /// The row shown at the top edge of the list, where it rests.
    @MainActor private func expectAtTop(_ app: XCUIApplication, _ identity: String, atY y: CGFloat, _ label: String) {
        let element = row(app, identity)
        XCTAssertTrue(element.exists, "\(label): row-\(identity) isn't shown")
        if element.exists { XCTAssertEqual(element.frame.minY, y, accuracy: 0.5, "\(label): row-\(identity) rests at \(element.frame.minY)") }
    }

    @MainActor func testStatusBarTapScrollsTheFeedToItsFirstRow() throws {
        for engine in engines {
            let app = launch("feed", engine: engine)
            let first = row(app, "0")
            XCTAssertTrue(first.waitForExistence(timeout: 10))
            pause(1)
            let top = first.frame.minY
            let feed = app.otherElements["virtualFeed"]
            for _ in 0..<4 { feed.swipeUp(velocity: .fast) }
            pause(2.5)
            XCTAssertFalse(first.exists && first.frame.minY == top, "\(engine): the feed didn't move away")
            tapAndWatch(app, list: feed, "feed \(engine) from deep")
            expectAtTop(app, "0", atY: top, "feed \(engine) from deep")
            // Again while the feed is still coasting from a fling.
            feed.swipeUp(velocity: .fast); feed.swipeUp(velocity: .fast)
            tapAndWatch(app, list: feed, "feed \(engine) mid-fling")
            expectAtTop(app, "0", atY: top, "feed \(engine) mid-fling")
            app.terminate()
        }
    }

    @MainActor func testStatusBarTapScrollsTheChatToItsOldestMessage() throws {
        for engine in engines {
            let app = launch("chat", engine: engine)
            let chat = app.otherElements["chatList"]
            XCTAssertTrue(chat.waitForExistence(timeout: 10))
            pause(1)
            // Upside down: the oldest loaded message is the one shown at the top.
            let top = chat.frame.minY
            tapAndWatch(app, list: chat, "chat \(engine) from newest")
            expectAtTop(app, "message-59", atY: top, "chat \(engine) from newest")
            // Toward the newest again, then the tap while it still coasts.
            chat.swipeUp(velocity: .fast); chat.swipeUp(velocity: .fast)
            tapAndWatch(app, list: chat, "chat \(engine) mid-fling")
            expectAtTop(app, "message-59", atY: top, "chat \(engine) mid-fling")
            // With the keyboard up, which stays up.
            chat.swipeUp(velocity: .fast); chat.swipeUp(velocity: .fast)
            pause(2)
            app.textViews["composer"].tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            pause(0.8)
            tapAndWatch(app, list: chat, "chat \(engine) keyboard up")
            expectAtTop(app, "message-59", atY: top, "chat \(engine) keyboard up")
            XCTAssertTrue(app.keyboards.firstMatch.exists, "\(engine): the keyboard went away")
            app.terminate()
        }
    }

    @MainActor func testReselectingTheListsTabScrollsToTheTop() throws {
        for engine in engines {
            let app = launch("feed", engine: engine)
            let first = row(app, "0")
            XCTAssertTrue(first.waitForExistence(timeout: 10))
            pause(1)
            let top = first.frame.minY
            let feed = app.otherElements["virtualFeed"]
            for _ in 0..<3 { feed.swipeUp(velocity: .fast) }
            pause(2.5)
            tapAndWatch(app, list: feed, tab: true, "feed \(engine) tab")
            expectAtTop(app, "0", atY: top, "feed \(engine) tab")
            app.segmentedControls["listScreens"].buttons["Chat"].tap()
            let chat = app.otherElements["chatList"]
            XCTAssertTrue(chat.waitForExistence(timeout: 5))
            pause(1)
            tapAndWatch(app, list: chat, tab: true, "chat \(engine) tab")
            expectAtTop(app, "message-59", atY: chat.frame.minY, "chat \(engine) tab")
            app.terminate()
        }
    }
}
/// Grey pictures of one screen region, 2 points per pixel, from the test
/// process.
@MainActor private final class ListCapture {
    struct Frame { var time: Double; var pixels: [UInt8] }
    let region: CGRect, screen: CGSize
    private(set) var frames: [Frame] = []
    init(region: CGRect, screen: CGSize) { self.region = region; self.screen = screen }
    func capture() {
        let image = XCUIScreen.main.screenshot().image
        let width = Int(region.width / 2), height = Int(region.height / 2)
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            UIGraphicsPushContext(context)
            context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 0.5, y: -0.5)
            image.draw(in: CGRect(x: -region.minX, y: -region.minY, width: screen.width, height: screen.height))
            UIGraphicsPopContext()
            return true
        }
        if drawn { frames.append(.init(time: Date.timeIntervalSinceReferenceDate, pixels: pixels)) }
    }
    /// Mean absolute grey difference, 0 to 255.
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 255 }
        var total = 0
        for index in a.indices { total += abs(Int(a[index]) - Int(b[index])) }
        return Double(total) / Double(a.count)
    }
}
#endif
