#if os(iOS) && canImport(XCTest)
import XCTest
import UIKit

/// Chat bubbles as the screen shows them, read from screenshots the test
/// process takes. The app runs with no probe, marker view or diagnostic
/// flag: only the chat, in light mode, in each engine. Launch arguments
/// slow some animations down so that screenshots land inside them.
final class ChatBubbleScreenTests: XCTestCase {
    private let engines = ["keyframe", "uiKit", "stepped"]

    @MainActor private func launch(_ engine: String, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "lists", "-listScreen", "chat", "-listEngine", engine, "-AppleInterfaceStyle", "Light"] + extra
        app.launch()
        XCTAssertTrue(app.textViews["composer"].waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        return app
    }

    @MainActor func testTheChatShowsBubblesThatHugTheirTextOnTheirSendersSide() throws {
        for engine in engines {
            let app = launch(engine)
            let width = Double(app.frame.width)
            let bar = Points(app.otherElements["composerBar"].frame)
            let screen = try XCTUnwrap(ScreenRecorder(app: app).take(), engine)
            let rows = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'row-'")).allElementsBoundByIndex
            var outgoing = 0, incoming = 0, widths: [Double] = []
            for row in rows {
                // Rows wholly between the screen's controls and the composer.
                let frame = Points(row.frame)
                guard frame.minY > 200, frame.maxY < bar.minY else { continue }
                let name = "\(engine) \(row.identifier)"
                let isOutgoing = row.label == "You"
                XCTAssertTrue(isOutgoing || row.label == "Assistant", "\(name): \(row.label)")
                // Its time is part of what it says.
                let value = row.value as? String ?? ""
                XCTAssertNotNil(value.range(of: #", \d{1,2}:\d{2}$"#, options: .regularExpression), "\(name): \(value)")
                // Rows with the bubble's color along its sender's edge.
                let matching = isOutgoing ? Pixel.isOutgoing : Pixel.isIncoming
                let band: ClosedRange<Double> = isOutgoing ? (width - 40)...(width - 10) : 10...40
                guard let bubble = screen.runs(columns: band, from: frame.maxY, to: frame.minY, matching: matching).first else {
                    XCTFail("\(name): no bubble in \(frame)"); continue
                }
                XCTAssertGreaterThan(bubble.bottom - bubble.top, 32, "\(name): \(bubble)")
                // The row's padding: 6 points at a group's ends, 1 inside it,
                // give or take an antialiased edge pixel.
                let paddings: [Double] = [bubble.top - frame.minY, frame.maxY - bubble.bottom]
                for padding in paddings {
                    XCTAssertTrue((0...2).contains(padding) || (5...7).contains(padding), "\(name): padding \(padding) in \(frame), \(bubble)")
                }
                let middle = (bubble.top + bubble.bottom) / 2
                guard let left = screen.firstMatch(row: middle, from: 0, toward: width, matching: matching),
                      let right = screen.firstMatch(row: middle, from: width - 1, toward: 0, matching: matching) else {
                    XCTFail("\(name): no edges at \(middle)"); continue
                }
                widths.append(right - left)
                XCTAssertLessThanOrEqual(right - left, 0.75 * (width - 20) + 1.5, "\(name): a bubble spans the row: \(left)–\(right)")
                if isOutgoing {
                    outgoing += 1
                    XCTAssertEqual(right, width - 10, accuracy: 1.5, "\(name): an outgoing bubble isn't on the right: \(left)–\(right)")
                } else {
                    incoming += 1
                    XCTAssertEqual(left, 10, accuracy: 1.5, "\(name): an incoming bubble isn't on the left: \(left)–\(right)")
                }
            }
            print("Bubble screen \(engine) rest: \(outgoing) outgoing, \(incoming) incoming, widths \(widths.map { Int($0) })")
            XCTAssertGreaterThan(outgoing, 0, engine); XCTAssertGreaterThan(incoming, 0, engine)
            // Short messages get narrow bubbles, long ones wide.
            XCTAssertLessThan(widths.min() ?? width, width * 0.4, "\(engine): no bubble hugs a short message: \(widths)")
            XCTAssertGreaterThan(widths.max() ?? 0, width * 0.6, "\(engine): no bubble holds a long message: \(widths)")
            app.terminate()
        }
    }

    /// The sent bubble rises from the field to its place in steps, and from
    /// its first frame on it never leaves the screen. Slowed down, its first
    /// frames are seen at the field.
    @MainActor func testASentBubbleRisesOutOfTheFieldWithoutABlankFrame() throws {
        for (engine, duration) in engines.map({ ($0, 0.0) }) + [("keyframe", 1.5), ("uiKit", 1.5), ("stepped", 1.5)] {
            let app = launch(engine, duration > 0 ? ["-bubbleSendDuration", String(duration)] : [])
            let name = duration > 0 ? "\(engine) slowed" : engine
            let composer = app.textViews["composer"]
            composer.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), name)
            composer.typeText("Hello from the field")
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            let field = Points(composer.frame), bar = Points(app.otherElements["composerBar"].frame)
            let send = app.buttons["Send"]
            // Columns inside both the field and the bubble's place, clear of
            // the bubble's corners.
            let band: ClosedRange<Double> = (field.maxX - 50)...(field.maxX - 20)
            let recorder = ScreenRecorder(app: app)
            let before = try XCTUnwrap(recorder.take(), name)
            // The newest bubble, whose place the sent one takes.
            let resting = try XCTUnwrap(before.runs(columns: band, from: bar.minY - 1, to: bar.minY - 300, matching: Pixel.isOutgoing).first, name)
            recorder.record(for: 1.6 + duration * 1.3) { send.tap() }

            // The lowest bubble in each screen: the resting one until the
            // sent one shows below it, then the sent one.
            var lowest: [(time: Double, top: Double, bottom: Double)] = []
            for frame in recorder.frames.dropFirst() {
                guard let screen = recorder.screen(frame) else { continue }
                let run = screen.runs(columns: band, from: field.maxY - 1, to: bar.minY - 300, matching: Pixel.isOutgoing).first
                lowest.append((frame.time, run?.top ?? .nan, run?.bottom ?? .nan))
            }
            recorder.keep(as: "send-\(name)")
            print("Bubble screen \(name) send: field \(field), resting \(resting), \(recorder.frames.count) screens, lowest \(lowest.map { (Int($0.time * 1000), $0.top, $0.bottom) })")
            // Every screen has a bubble at or below the newest place.
            for item in lowest {
                XCTAssertGreaterThanOrEqual(item.bottom, resting.bottom - 1.5, "\(name): the newest place was empty at \(item)")
            }
            guard let last = lowest.last else { continue }
            XCTAssertEqual(last.bottom, resting.bottom, accuracy: 1.5, "\(name): the sent bubble didn't take the newest place")
            let settledScreen = try XCTUnwrap(recorder.screen(recorder.frames.last!), name)
            let previous = settledScreen.runs(columns: band, from: bar.minY - 1, to: bar.minY - 300, matching: Pixel.isOutgoing).dropFirst().first
            let previousBottom: Double = previous?.bottom ?? .infinity
            // The resting bubble moved up by at least the sent one's height
            // and sits above it.
            let sentHeight: Double = last.bottom - last.top
            XCTAssertLessThanOrEqual(previousBottom, resting.bottom - sentHeight + 1.5, "\(name): the resting bubble didn't move up by \(sentHeight)")
            XCTAssertLessThan(previousBottom, last.top, "\(name): the resting bubble overlaps the sent one at \(last)")
            // From the first screen that shows it in the field, the sent
            // bubble rises and never falls back.
            let rising = Array(lowest.drop { !($0.bottom > resting.bottom + 3) })
            if duration == 0, rising.isEmpty { continue }
            guard let first = rising.first else { XCTFail("\(name): the sent bubble was never seen in the field"); continue }
            XCTAssertGreaterThan(first.bottom, field.minY + 10, "\(name): the sent bubble first showed above the field: \(first)")
            for (a, b) in zip(rising, rising.dropFirst()) {
                XCTAssertLessThanOrEqual(b.top, a.top + 1.5, "\(name): the bubble fell back from \(a) to \(b)")
                XCTAssertLessThanOrEqual(b.bottom, a.bottom + 1.5, "\(name): the bubble fell back from \(a) to \(b)")
            }
            if duration > 0 {
                let travel: Double = first.top - last.top
                let startTolerance: Double = max(6, 0.15 * travel)
                XCTAssertGreaterThan(travel, 20, "\(name): the bubble didn't rise out of the field: \(first) → \(last)")
                XCTAssertEqual(first.top, field.minY, accuracy: startTolerance, "\(name): the bubble didn't start at the field \(field)")
                let between = rising.filter { $0.top < first.top - 2 && $0.top > last.top + 2 }
                XCTAssertGreaterThanOrEqual(between.count, 4, "\(name): too few steps")
                let stepLimit: Double = max(6, 0.3 * travel)
                for (a, b) in zip(rising, rising.dropFirst()) {
                    XCTAssertLessThan(a.top - b.top, stepLimit, "\(name): the bubble jumped from \(a) to \(b)")
                }
            }
            app.terminate()
        }
    }

    /// A streamed reply grows word by word with its bottom on the same line
    /// above the field, never narrows, shrinks or disappears, and its time
    /// stays at the same distance from its right edge.
    @MainActor func testAStreamedReplyGrowsWithItsTimeAlongItsEdge() throws {
        for engine in engines {
            let app = launch(engine, ["-bubbleStreamInterval", "250"])
            let width = Double(app.frame.width)
            let bar = Points(app.otherElements["composerBar"].frame)
            let stream = app.buttons["Stream"]
            let recorder = ScreenRecorder(app: app)
            let before = try XCTUnwrap(recorder.take(), engine)
            let column = 16.0
            // The newest incoming bubble; the reply comes in below it.
            let resting = before.runs(column: column, from: bar.minY - 2, to: bar.minY - 300, matching: Pixel.isIncoming).first
            recorder.record(for: 4) { stream.tap() }

            var seen: [BubbleEdges] = [], missing: [Double] = []
            for frame in recorder.frames {
                guard let screen = recorder.screen(frame) else { continue }
                guard let run = screen.runs(column: column, from: bar.minY - 2, to: bar.minY - 400, matching: Pixel.isIncoming)
                    .first(where: { resting == nil || $0.bottom > resting!.bottom + 10 }) else {
                    if !seen.isEmpty { missing.append(frame.time) }
                    continue
                }
                if let edges = BubbleEdges(screen, run: run, time: frame.time, column: column, width: width) { seen.append(edges) }
            }
            print("Bubble screen \(engine) stream: \(recorder.frames.count) screens, seen \(seen.map(\.summary))")
            XCTAssertTrue(missing.isEmpty, "\(engine): the reply vanished at \(missing)")
            // Past its appearance, a scale from its tail corner.
            let settled = Array(seen.drop { $0.time < (seen.first?.time ?? 0) + 0.5 })
            XCTAssertGreaterThan(settled.count, 5, "\(engine): the reply was seen in too few screens")
            guard let base = settled.first else { continue }
            for item in settled {
                XCTAssertEqual(item.bottom, base.bottom, accuracy: 1.5, "\(engine): the reply's bottom moved at \(item.time)")
            }
            for (a, b) in zip(settled, settled.dropFirst()) {
                XCTAssertGreaterThanOrEqual(b.right, a.right - 1.5, "\(engine): the reply narrowed: \(a.summary) → \(b.summary)")
                XCTAssertLessThanOrEqual(b.top, a.top + 1.5, "\(engine): the reply got shorter: \(a.summary) → \(b.summary)")
            }
            let sizes = Set(settled.map { [Int(($0.right / 2).rounded()), Int(($0.top / 2).rounded())] })
            XCTAssertGreaterThanOrEqual(sizes.count, 4, "\(engine): the reply didn't grow in steps: \(sizes)")
            // The time rides along the right edge, on the last line or on
            // its own.
            let offsets = settled.compactMap(\.timeOffset)
            XCTAssertGreaterThan(offsets.count, settled.count / 2, "\(engine): the time wasn't found")
            let median = offsets.sorted().dropFirst(offsets.count / 2).first ?? 0
            for offset in offsets {
                XCTAssertEqual(offset, median, accuracy: 2, "\(engine): the time didn't move with the bubble's edge: \(offsets)")
            }
            app.terminate()
        }
    }

    /// Tapping a bubble edits it: the bubble resizes in steps with its
    /// corners still round, its time rides along its edge, and its old text
    /// fades out as the new one fades in, so no screen is blank and some show
    /// both.
    @MainActor func testAnEditedBubbleResizesWithRoundCornersAndCrossfadesItsText() throws {
        for engine in engines {
            let app = launch(engine, ["-bubbleGrowthDuration", "1.5"])
            let width = Double(app.frame.width)
            let bar = Points(app.otherElements["composerBar"].frame)
            let recorder = ScreenRecorder(app: app)
            let before = try XCTUnwrap(recorder.take(), engine)
            let column = 16.0
            // The newest incoming bubble.
            let bubble = try XCTUnwrap(before.runs(column: column, from: bar.minY - 2, to: bar.minY - 300, matching: Pixel.isIncoming).first, engine)
            let target = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 60, dy: (bubble.top + bubble.bottom) / 2))
            recorder.record(for: 2.5) { target.tap() }

            var seen: [BubbleEdges] = [], text: [[Int]] = [], missing: [Double] = []
            for frame in recorder.frames {
                guard let screen = recorder.screen(frame) else { continue }
                guard let run = screen.runs(column: column, from: bar.minY - 2, to: bar.minY - 300, matching: Pixel.isIncoming).first,
                      abs(run.bottom - bubble.bottom) < 3, let edges = BubbleEdges(screen, run: run, time: frame.time, column: column, width: width) else {
                    missing.append(frame.time); continue
                }
                seen.append(edges)
                // The first line, where the bubble's text starts.
                text.append(screen.brightness(in: CGRect(x: 22, y: run.top + 7, width: 100, height: 20)))
            }
            recorder.keep(as: "edit-\(engine)")
            print("Bubble screen \(engine) edit: \(recorder.frames.count) screens, seen \(seen.map(\.summary))")
            XCTAssertTrue(missing.isEmpty, "\(engine): the bubble was lost at \(missing)")
            guard let first = seen.first, let last = seen.last, let firstText = text.first, let lastText = text.last else { continue }
            XCTAssertLessThan(last.right, first.right - 20, "\(engine): the edit didn't narrow the bubble: \(first.summary) → \(last.summary)")
            let between = seen.filter { $0.right < first.right - 2 && $0.right > last.right + 2 }
            XCTAssertGreaterThanOrEqual(between.count, 3, "\(engine): the bubble didn't resize in steps")
            for item in seen {
                // A rounded corner keeps its radius at every size.
                XCTAssertEqual(item.corner, first.corner, accuracy: 1.5, "\(engine): the corner changed at \(item.summary)")
                if let offset = item.timeOffset, let initial = first.timeOffset {
                    XCTAssertEqual(offset, initial, accuracy: 1.5, "\(engine): the time left the edge at \(item.summary)")
                }
            }
            XCTAssertNotNil(first.timeOffset, engine); XCTAssertNotNil(last.timeOffset, engine)
            // Each screen shows the old text, the new, or both faded.
            let change = Screen.difference(firstText, lastText)
            XCTAssertGreaterThan(change, 5, "\(engine): the text didn't change")
            var blended = 0
            for (index, sample) in text.enumerated() {
                let fromOld = Screen.difference(sample, firstText), fromNew = Screen.difference(sample, lastText)
                if min(fromOld, fromNew) > 0.2 * change { blended += 1 }
                XCTAssertGreaterThan(Screen.ink(sample), 0.3 * min(Screen.ink(firstText), Screen.ink(lastText)),
                                     "\(engine): no text at \(seen[index].summary)")
            }
            print("Bubble screen \(engine) edit: text change \(change), \(blended) blended screens of \(text.count)")
            XCTAssertGreaterThan(blended, 0, "\(engine): the text jumped instead of crossfading")
            app.terminate()
        }
    }
}

/// A frame from the accessibility tree, in points as `Double`s.
private struct Points: CustomStringConvertible {
    let minX: Double, minY: Double, maxX: Double, maxY: Double
    init(_ rect: CGRect) {
        minX = Double(rect.minX); minY = Double(rect.minY); maxX = Double(rect.maxX); maxY = Double(rect.maxY)
    }
    var description: String { "(\(minX), \(minY))–(\(maxX), \(maxY))" }
}

/// An incoming bubble's edges and time on one screen, in points.
private struct BubbleEdges {
    var time: Double, top: Double, bottom: Double, right: Double
    /// How far in from `right` the top-right corner is two points down.
    var corner: Double
    /// From the time's last glyph to `right`.
    var timeOffset: Double?

    init?(_ screen: Screen, run: (bottom: Double, top: Double), time: Double, column: Double, width: Double) {
        self.time = time; top = run.top; bottom = run.bottom
        // Where the corners are straight: the time's band, over the bottom corner.
        guard let right = screen.firstMatch(row: run.bottom - 13, from: width - 1, toward: column, matching: Pixel.isIncoming),
              let topRight = screen.firstMatch(row: run.top + 2, from: width - 1, toward: column, matching: Pixel.isIncoming) else { return nil }
        self.right = right
        corner = right - topRight
        timeOffset = screen.lastInk(rows: (run.bottom - 18)...(run.bottom - 7), from: column + 6, to: right - 1).map { right - $0 }
    }

    var summary: String { "\(Int(time * 1000)) ms \(top)–\(bottom) right \(right) corner \(corner) time \(timeOffset ?? -1)" }
}

/// Screenshots of the app, in points, timed from an action.
@MainActor private final class ScreenRecorder {
    struct Frame { var time: Double; var shot: XCUIScreenshot }
    private(set) var frames: [Frame] = []
    private let width: Double
    private var start = Date()

    init(app: XCUIApplication) { width = Double(app.frame.width) }

    func take() -> Screen? { screen(XCUIScreen.main.screenshot()) }

    func screen(_ frame: Frame) -> Screen? { screen(frame.shot) }

    private func screen(_ shot: XCUIScreenshot) -> Screen? {
        guard let image = shot.image.cgImage else { return nil }
        return Screen(image: image, scale: Double(image.width) / width)
    }

    /// Takes screenshots back to back for `seconds`, one before `action` and
    /// the rest also while the test waits for the action to finish, which it
    /// does only once the app's animations have.
    func record(for seconds: Double, during action: () -> Void) {
        start = Date()
        let end = start.addingTimeInterval(seconds)
        let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if Date() < end { self?.capture() } }
        }
        capture()
        RunLoop.main.add(timer, forMode: .common)
        action()
        while Date() < end { RunLoop.current.run(until: min(end, Date().addingTimeInterval(0.05))) }
        timer.invalidate()
    }

    /// Writes the screens as PNGs into the directory in `BUBBLE_SCREENS`, if set.
    func keep(as name: String) {
        guard let directory = ProcessInfo.processInfo.environment["BUBBLE_SCREENS"] else { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for (index, frame) in frames.enumerated() {
            let path = "\(directory)/\(name)-\(String(format: "%02d", index))-\(Int(frame.time * 1000)).png"
            try? frame.shot.pngRepresentation.write(to: URL(fileURLWithPath: path))
        }
    }

    private func capture() {
        frames.append(Frame(time: Date().timeIntervalSince(start), shot: XCUIScreen.main.screenshot()))
    }
}

private enum Pixel {
    /// The outgoing bubble's blue (0x3478F6 in light mode).
    static func isOutgoing(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool {
        abs(Int(r) - 0x34) < 24 && abs(Int(g) - 0x78) < 24 && abs(Int(b) - 0xF6) < 24
    }
    /// An incoming bubble's white, also dimmed while pressed, against the
    /// chat's light gray (242, 242, 247).
    static func isIncoming(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool { r >= 248 && g >= 248 && b >= 250 }
}

/// One screenshot's pixels, read in points.
private struct Screen {
    let width: Int, height: Int, scale: Double
    private let pixels: [UInt8]

    init(image: CGImage, scale: Double) {
        width = image.width; height = image.height; self.scale = scale
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        pixels = buffer
    }

    private func pixel(_ x: Double, _ y: Double) -> (UInt8, UInt8, UInt8)? {
        let px = Int(x * scale), py = Int(y * scale)
        guard px >= 0, py >= 0, px < width, py < height else { return nil }
        let index = (py * width + px) * 4
        return (pixels[index], pixels[index + 1], pixels[index + 2])
    }

    /// Runs of matching pixels down column `column`, scanning up from `from`
    /// to `to` (points), nearest first. A run's bottom is its lowest point.
    func runs(column: Double, from: Double, to: Double, matching: (UInt8, UInt8, UInt8) -> Bool) -> [(bottom: Double, top: Double)] {
        var result: [(bottom: Double, top: Double)] = []
        var bottom: Double?
        var y = from
        let step = 1 / scale
        while y >= to {
            let inside = pixel(column, y).map { matching($0.0, $0.1, $0.2) } ?? false
            if inside, bottom == nil { bottom = y }
            if !inside, let start = bottom { if start - y > 4 { result.append((start, y + step)) }; bottom = nil }
            y -= step
        }
        if let start = bottom { result.append((start, to)) }
        return result
    }

    /// Runs of rows with a matching pixel between `columns`, scanning up
    /// from `from` to `to` (points), nearest first.
    func runs(columns: ClosedRange<Double>, from: Double, to: Double, matching: (UInt8, UInt8, UInt8) -> Bool) -> [(bottom: Double, top: Double)] {
        var result: [(bottom: Double, top: Double)] = []
        var bottom: Double?
        var y = from
        let step = 1 / scale
        while y >= to {
            var inside = false, x = columns.lowerBound
            while !inside, x <= columns.upperBound {
                if let p = pixel(x, y), matching(p.0, p.1, p.2) { inside = true }
                x += step
            }
            if inside, bottom == nil { bottom = y }
            if !inside, let start = bottom { if start - y > 4 { result.append((start, y + step)) }; bottom = nil }
            y -= step
        }
        if let start = bottom { result.append((start, to)) }
        return result
    }

    /// The first matching point along row `row`, going from `from` toward `toward`.
    func firstMatch(row: Double, from: Double, toward: Double, matching: (UInt8, UInt8, UInt8) -> Bool) -> Double? {
        let step = (toward > from ? 1 : -1) / scale
        var x = from
        while (toward - x) * step >= 0 {
            if let p = pixel(x, row), matching(p.0, p.1, p.2) { return x }
            x += step
        }
        return nil
    }

    /// The rightmost dark pixel (text) in `rows`, between `from` and `to`.
    func lastInk(rows: ClosedRange<Double>, from: Double, to: Double) -> Double? {
        var best: Double?
        let step = 1 / scale
        var y = rows.lowerBound
        while y <= rows.upperBound {
            var x = to
            while x > from {
                if let p = pixel(x, y), Int(p.0) + Int(p.1) + Int(p.2) < 3 * 200 { best = max(best ?? -1, x); break }
                x -= step
            }
            y += step
        }
        return best
    }

    /// Each pixel's brightness (0–765) in `rect`, row by row.
    func brightness(in rect: CGRect) -> [Int] {
        var result: [Int] = []
        let step = 1 / scale
        var y = rect.minY
        while y < rect.maxY {
            var x = rect.minX
            while x < rect.maxX {
                result.append(pixel(x, y).map { Int($0.0) + Int($0.1) + Int($0.2) } ?? 0)
                x += step
            }
            y += step
        }
        return result
    }

    /// The mean brightness difference between two samples of one rectangle.
    static func difference(_ a: [Int], _ b: [Int]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        return Double(zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) }) / Double(a.count)
    }

    /// How much darker than white a sample is, on average.
    static func ink(_ sample: [Int]) -> Double {
        sample.isEmpty ? 0 : Double(sample.reduce(0) { $0 + 765 - $1 }) / Double(sample.count)
    }
}
#endif
