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
    /// list must move, reach the picture it rests at within `limit` seconds
    /// of starting toward it, and then not change again: no jump or bounce
    /// once it lands. The tap call itself can take seconds to deliver its
    /// event, so the clock starts where the captures first move toward the
    /// top, and no later than the tap call's return.
    @MainActor private func tapAndWatch(_ app: XCUIApplication, list: XCUIElement, tab: Bool = false, limit: Double = 1.2, _ label: String) {
        let region = list.frame.intersection(app.frame)
        let capture = ListCapture(region: region, screen: app.frame.size)
        capture.capture()
        let timer = Timer(timeInterval: 0.04, repeats: true) { _ in MainActor.assumeIsolated { capture.capture() } }
        RunLoop.main.add(timer, forMode: .common)
        if tab { app.listsTab.tap() }
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
        let reading = Date()
        let steps = CaptureStep.steps(frames, width: Int(region.width / 2), height: Int(region.height / 2), through: landed)
        let read = Date().timeIntervalSince(reading)
        let clock = CaptureStep.start(steps, landed: landed, tapReturned: start)
        let at = { (index: Int) in String(format: "%.2fs", frames[index].time - frames[0].time) }
        print("Scroll to top \(label) steps: " + steps.enumerated().map { "\(at($0.offset + 1)) \($0.element)" }.joined(separator: ", ")
              + String(format: "; read in %.1f s", read)
              + "; tap returned before \(at(min(start, frames.count - 1))), pixel onset \(at(clock.pixelOnset)),"
              + " onset from \(clock.onset < clock.pixelOnset ? "the tap return" : "pixels"), clock from \(at(clock.begin)),"
              + String(format: " landed %.2f s later", frames[landed].time - frames[clock.begin].time))
        XCTAssertLessThan(frames[landed].time - frames[clock.begin].time, limit, "\(label): landed late")
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

    /// The clock's start, from synthetic captures of cards with lines of
    /// text, moved by half pixels as a list coasting at 2 points per pixel.
    @MainActor func testCaptureStepsTellCoastingFromTheScrollToTheTop() {
        let width = 160, height = 200, tall = 2 * height + 200
        var canvas = [Double](repeating: 242, count: 2 * width * tall)
        var seed: UInt64 = 7
        func next() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) }
        var top = 0
        while top + 64 < tall {
            let card = 60 + next() % 140
            for y in top + 4..<min(tall, top + card - 4) { for x in 12..<2 * width - 12 { canvas[y * 2 * width + x] = 255 } }
            for line in stride(from: top + 18, to: min(tall - 14, top + card - 18), by: 19) {
                var x = 26
                while x < 2 * width - 40 {
                    let word = 10 + next() % 50, tone = Double(70 + next() % 50)
                    for y in line + 2..<line + 11 { for column in x..<min(2 * width - 26, x + word) { canvas[y * 2 * width + column] = tone } }
                    x += word + 6
                }
            }
            top += card
        }
        // The content moved down the screen by `points`, sampled 2 points per pixel.
        func capture(_ points: Int) -> [UInt8] {
            (0..<width * height).map { index in
                let x = 2 * (index % width), y = 2 * (index / width) + 100 - points
                let sum = canvas[y * 2 * width + x] + canvas[y * 2 * width + x + 1] + canvas[(y + 1) * 2 * width + x] + canvas[(y + 1) * 2 * width + x + 1]
                return UInt8((sum / 4).rounded())
            }
        }
        let rest = capture(0)
        func step(_ b: [UInt8]) -> CaptureStep { CaptureStep.between(rest, b, width: width, height: height) }
        XCTAssertTrue(step(rest).isStill)
        for points in [-3, -4, -41] {
            guard case let .fling(found, _) = step(capture(points)) else { XCTFail("\(points) pt: \(step(capture(points)))"); continue }
            XCTAssertEqual(found, Double(points))
        }
        for points in [3, 41] {
            guard case let .toward(found, _, matched) = step(capture(points)) else { XCTFail("\(points) pt: \(step(capture(points)))"); continue }
            XCTAssertEqual(found, Double(points)); XCTAssertTrue(matched)
        }
        for b in [capture(-1), (0..<width * height).map { _ in UInt8(truncatingIfNeeded: next()) }] {
            guard case let .toward(_, _, matched) = step(b) else { XCTFail("\(step(b))"); continue }
            XCTAssertFalse(matched)
        }
        let frames = [0, -4, -4, -8, -12].map { ListCapture.Frame(time: 0, pixels: capture($0)) }
        XCTAssertEqual(CaptureStep.steps(frames, width: width, height: height, through: 4, budget: 2).map(\.description),
                       ["fling -4pt e0.0", "still", "fling -4pt e0.0", "unread"])
        let still = CaptureStep.still, coast = CaptureStep.fling(points: -4, error: 1), toward = CaptureStep.toward(points: 40, error: 9, matched: true)
        func start(_ steps: [CaptureStep], landed: Int, tapReturned: Int) -> [Int] {
            let clock = CaptureStep.start(steps, landed: landed, tapReturned: tapReturned)
            return [clock.begin, clock.pixelOnset, clock.onset]
        }
        XCTAssertEqual(start([still, still, still, toward, toward], landed: 5, tapReturned: 9), [3, 4, 4])
        XCTAssertEqual(start([coast, coast, still, still, toward], landed: 6, tapReturned: 9), [4, 5, 5])
        XCTAssertEqual(start([coast, coast, coast, toward], landed: 5, tapReturned: 9), [2, 4, 4])
        XCTAssertEqual(start([toward], landed: 3, tapReturned: 9), [0, 1, 1])
        XCTAssertEqual(start([coast, coast, coast], landed: 6, tapReturned: 3), [1, 6, 3])
        XCTAssertEqual(start([still, still, still], landed: 5, tapReturned: 3), [2, 5, 3])
        XCTAssertEqual(start([coast, coast, .unread], landed: 6, tapReturned: 9), [1, 3, 3])
    }
}
extension XCUIApplication {
    /// The Lists tab's button. iPadOS 26 floats the tab bar over the content
    /// and exposes its buttons without a tab bar element, so the button is
    /// found by its label; nothing else in the demo is labelled Lists.
    var listsTab: XCUIElement { buttons["Lists"].firstMatch }
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
/// How the list moved between two captures, read from their pixels alone.
/// Every fling in these tests carries the content up the screen, and the
/// scroll to the top carries it down.
private enum CaptureStep: CustomStringConvertible {
    case still
    /// The content moved up by `points`, as it does while it still coasts.
    case fling(points: Double, error: Double)
    /// Anything else. `matched` when the content moved down, toward the
    /// top; otherwise no shift explains the change well enough to call it
    /// coasting.
    case toward(points: Double, error: Double, matched: Bool)
    /// A step past the comparison budget, counted toward the top unread.
    case unread

    var isStill: Bool { if case .still = self { true } else { false } }
    var isTowardTheTop: Bool { switch self { case .toward, .unread: true; case .still, .fling: false } }
    var description: String {
        switch self {
        case .still: "still"
        case .unread: "unread"
        case let .fling(points, error): String(format: "fling %+.0fpt e%.1f", points, error)
        case let .toward(points, error, matched): (matched ? "toward " : "unclear ") + String(format: "%+.0fpt e%.1f", points, error)
        }
    }

    /// Compares grey captures of `width` × `height` pixels, 2 points per
    /// pixel. `b` is matched against `a` moved by every half pixel up to half
    /// the height, a half step comparing with the mean of two neighbouring
    /// rows, sampling every 4th column and 2nd row. Coasting needs a shift
    /// up of at least 2 points that fits less than half as badly as the best
    /// shift that isn't up.
    @MainActor static func between(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int) -> CaptureStep {
        guard a.count == width * height, b.count == a.count, height > 2 else { return .toward(points: 0, error: 255, matched: false) }
        guard ListCapture.difference(a, b) >= 1 else { return .still }
        let reach = height / 2
        var best = (points: 0, error: Double.infinity), bestDown = Double.infinity, bestNotDown = Double.infinity
        a.withUnsafeBufferPointer { a in
            b.withUnsafeBufferPointer { b in
                // A shift of `points` moves the content down by that many points.
                for points in -2 * reach...2 * reach {
                    let shift = points >> 1, half = points & 1 == 1
                    var total = 0, count = 0
                    for y in stride(from: max(1, shift + 1), to: min(height, height + shift), by: 2) {
                        let row = y * width, from = (y - shift) * width, above = from - width
                        for x in stride(from: 0, to: width, by: 4) {
                            total += half ? abs(2 * Int(b[row + x]) - Int(a[from + x]) - Int(a[above + x]))
                                          : 2 * abs(Int(b[row + x]) - Int(a[from + x]))
                            count += 1
                        }
                    }
                    let error = Double(total) / Double(2 * max(1, count))
                    if error < best.error { best = (points, error) }
                    if points >= 0 { bestDown = min(bestDown, error) }
                    if points <= 0 { bestNotDown = min(bestNotDown, error) }
                }
            }
        }
        let points = Double(best.points)
        if points <= -2, best.error < 0.5 * bestDown { return .fling(points: points, error: best.error) }
        return .toward(points: points, error: best.error, matched: points >= 2 && best.error < 0.5 * bestNotDown)
    }

    /// The steps into captures 1 through `last`, up to the first one that
    /// moves toward the top. Once `budget` steps that changed have been
    /// searched, the next one that changed counts as toward the top without
    /// a search, which can only start the clock earlier.
    @MainActor static func steps(_ frames: [ListCapture.Frame], width: Int, height: Int, through last: Int, budget: Int = 16) -> [CaptureStep] {
        var steps: [CaptureStep] = [], searched = 0
        for index in stride(from: 1, through: last, by: 1) {
            let a = frames[index - 1].pixels, b = frames[index].pixels
            if searched >= budget, ListCapture.difference(a, b) >= 1 { steps.append(.unread); break }
            steps.append(between(a, b, width: width, height: height))
            if !steps[index - 1].isStill { searched += 1 }
            if steps[index - 1].isTowardTheTop { break }
        }
        return steps
    }

    /// Where the clock for a tap starts. `steps[k - 1]` is the step into
    /// capture `k`, `landed` is the first capture at rest, and `tapReturned`
    /// the first capture taken after the tap call came back, by when its
    /// event had been delivered. The onset is the first capture that moved
    /// toward the top, and no later than `tapReturned`. The clock starts at
    /// the capture before the onset, or one earlier when the list coasted
    /// into that one, since the tap may have come during that step. It
    /// starts at the first capture when nothing still or coasting comes
    /// before the onset.
    ///
    /// For a list that already coasts, this places the tap only within a
    /// step of the onset: a list that kept coasting the same way after the
    /// tap for longer than a step looks the same as one not yet tapped.
    static func start(_ steps: [CaptureStep], landed: Int, tapReturned: Int) -> (begin: Int, pixelOnset: Int, onset: Int) {
        let pixelOnset = steps.firstIndex { $0.isTowardTheTop }.map { $0 + 1 } ?? landed
        let onset = max(1, min(pixelOnset, tapReturned, landed))
        guard onset > 1 else { return (0, pixelOnset, onset) }
        return (steps[onset - 2].isStill ? onset - 1 : onset - 2, pixelOnset, onset)
    }
}
#endif
