#if os(iOS) && canImport(XCTest)
import XCTest
import UIKit

/// The system control path. Screenshots come from the test process without diagnostic
/// flags, marker views, display links, or geometry queries during the drag.
final class UninstrumentedKeyboardInteractionTests: XCTestCase {
    @MainActor func testPortraitComposerFollowsThePhysicalKeyboardWithoutProbes() throws {
        try checkTracking(orientation: .portrait)
    }

    @MainActor func testLandscapeComposerFollowsThePhysicalKeyboardWithoutProbes() throws {
        try checkTracking(orientation: .landscapeLeft)
    }

    /// The app moves the keyboard itself, here as on a full-screen iPad. The
    /// drag stops short of dismissing, so only the moving frames are checked.
    @MainActor func testPortraitComposerFollowsTheDrivenKeyboardWithoutProbes() throws {
        try checkTracking(orientation: .portrait, system: false)
    }

    @MainActor func testLandscapeComposerFollowsTheDrivenKeyboardWithoutProbes() throws {
        try checkTracking(orientation: .landscapeLeft, system: false)
    }

    @MainActor private func checkTracking(orientation: UIDeviceOrientation, system: Bool = true) throws {
        XCUIDevice.shared.orientation = orientation
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        for mode in ["keyframe", "uiKit", "stepped"] {
            app.launchArguments = ["-screen", "lists", "-listScreen", "chat", "-listEngine", mode, "-listSystemKeyboardDismissal", system ? "YES" : "NO"]
            app.launch()
            let composer = app.textViews["composer"], keyboard = app.keyboards.firstMatch
            XCTAssertTrue(composer.waitForExistence(timeout: 10))
            let restingComposerFrame = composer.frame, restingAppFrame = app.frame
            // The strip below the resting composer: the tab bar on a phone,
            // the home indicator's margin where the tab bar floats at the top.
            let stripFrame = CGRect(x: restingAppFrame.minX, y: restingComposerFrame.maxY, width: restingAppFrame.width,
                                    height: restingAppFrame.maxY - restingComposerFrame.maxY).intersection(restingAppFrame)
            XCTAssertFalse(stripFrame.isEmpty, "The resting strip below the composer must be visible before the keyboard")
            let resting = KeyboardScreenCapture(screenSize: restingAppFrame.size)
            resting.capture()
            composer.tap(); XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            XCTAssertFalse(app.staticTexts["keyboardGeometry"].exists)
            let composerFrame = composer.frame, keyboardFrame = keyboard.frame, appFrame = app.frame
            let key = keyboard.keys["E"].exists ? keyboard.keys["E"] : keyboard.keys["e"]
            XCTAssertTrue(key.exists, "The physical keyboard must expose the reference key")
            let keyFrame = key.frame
            let recorder = KeyboardScreenCapture(screenSize: appFrame.size)
            recorder.capture()
            let timer = Timer(timeInterval: 0.06, repeats: true) { _ in
                MainActor.assumeIsolated { recorder.capture() }
            }
            RunLoop.main.add(timer, forMode: .common)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let listFrame = app.otherElements["chatList"].frame.intersection(appFrame)
            let startY = max(listFrame.minY + 8, composerFrame.minY - 35)
            let travel = min(100, keyboardFrame.height * 0.3)
            let start = origin.withOffset(.init(dx: appFrame.midX, dy: startY))
            let end = origin.withOffset(.init(dx: appFrame.midX, dy: keyboardFrame.minY + travel))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .init(rawValue: 120), thenHoldForDuration: 0.5)
            timer.invalidate()
            recorder.capture()
            let prefix = "\(orientation.rawValue)/\(mode)\(system ? "" : "/driven")"
            print("No-probe \(prefix): captured \(recorder.frames.count) screens")
            XCTAssertGreaterThan(recorder.frames.count, 4, "\(prefix): missing screens during the finger movement")
            let first = try XCTUnwrap(recorder.frames.first.flatMap(UIImage.init(data:))?.cgImage)
            let restingImage = try XCTUnwrap(resting.frames.first.flatMap(UIImage.init(data:))?.cgImage)
            let scale = Double(first.width) / appFrame.width
            print("No-probe \(prefix): normalized screen \(first.width)x\(first.height), app \(appFrame.size), scale \(scale)")
            let physicalTop = try XCTUnwrap(KeyboardPixelTemplate.keyboardTop(in: first,
                after: composerFrame.maxY, before: keyboardFrame.minY, scale: scale))
            let restGap = physicalTop - composerFrame.maxY
            print("No-probe \(prefix): pixel rest gap \(restGap)")
            XCTAssertEqual(restGap, 8, accuracy: 1.5, "\(prefix): initial physical keyboard gap")
            let barPatch = CGRect(x: composerFrame.minX + 6, y: composerFrame.minY + 5, width: min(80, composerFrame.width - 12), height: 28)
            let keyPatch = keyFrame.insetBy(dx: 4, dy: 5)
            let bar = try XCTUnwrap(KeyboardPixelTemplate(image: first, rect: barPatch, scale: scale))
            let letter = try XCTUnwrap(KeyboardPixelTemplate(image: first, rect: keyPatch, scale: scale))
            print("No-probe \(prefix): strip \(stripFrame), height \(stripFrame.height), inset height \(stripFrame.insetBy(dx: 4, dy: 4).height)")
            let strip = try XCTUnwrap(KeyboardPixelTemplate(image: restingImage,
                rect: stripFrame.insetBy(dx: 4, dy: 4), scale: scale))
            // The strip is covered while the physical keyboard is present.
            // Its return is independent of either moving template's match.
            let coveredDifference = try XCTUnwrap(strip.difference(in: first))
            XCTAssertGreaterThan(coveredDifference, 3, "The strip's pixels must distinguish the keyboard from rest")
            let restingShift = Double(restingComposerFrame.minY - composerFrame.minY)
            let maximumTravel = max(travel + 80, restingShift + 12)
            var moving = 0, hidden = 0, maximumGap = 0.0, covered: [Double] = [], uncovered: [Double] = []
            for (index, data) in recorder.frames.enumerated() {
                guard let image = UIImage(data: data)?.cgImage,
                      let barShift = bar.translation(in: image, maximum: maximumTravel),
                      let stripDifference = strip.difference(in: image) else {
                    XCTFail("\(prefix) frame \(index): a reference disappeared"); continue
                }
                if stripDifference <= 3 {
                    hidden += 1; uncovered.append(stripDifference)
                    print("No-probe \(prefix) frame \(index): keyboard absent, composer \(barShift), rest \(restingShift), strip difference \(stripDifference)")
                    XCTAssertEqual(barShift, restingShift, accuracy: 1.5,
                                   "\(prefix) frame \(index): composer must reach its pixel rest position with the keyboard gone")
                    continue
                }
                covered.append(stripDifference)
                guard let keyShift = letter.translation(in: image, maximum: maximumTravel) else {
                    XCTFail("\(prefix) frame \(index): the visible keyboard reference disappeared"); continue
                }
                guard keyShift > 12 else { continue }
                moving += 1
                let gap = keyShift - barShift
                maximumGap = max(maximumGap, abs(gap))
                print("No-probe \(prefix) frame \(index): keyboard \(keyShift), composer \(barShift), gap \(gap)")
                XCTAssertLessThanOrEqual(abs(gap), 1.5, "\(prefix) frame \(index): composer left the physical keyboard")
            }
            XCTAssertGreaterThan(moving, 2, "\(prefix): no physical keyboard movement was captured")
            if system { XCTAssertGreaterThan(hidden, 0, "\(prefix): missing the keyboard's dismissal and the composer's pixel rest position") }
            print("No-probe \(prefix): moving \(moving), hidden \(hidden), maximum gap \(maximumGap)")
            print("No-probe \(prefix): strip difference with the keyboard up \(coveredDifference), covered frames \(covered.min() ?? -1)...\(covered.max() ?? -1), uncovered frames \(uncovered.min() ?? -1)...\(uncovered.max() ?? -1)")
            if maximumGap > 1.5, let last = recorder.frames.last {
                let attachment = XCTAttachment(data: last, uniformTypeIdentifier: "public.png")
                attachment.name = "no-probe-\(prefix)"; attachment.lifetime = .keepAlways; add(attachment)
            }
            app.terminate()
        }
    }
}

@MainActor final class KeyboardScreenCapture {
    let screenSize: CGSize
    var frames: [Data] = []
    init(screenSize: CGSize) { self.screenSize = screenSize }
    func capture() {
        let image = XCUIScreen.main.screenshot().image
        if frames.isEmpty {
            print("No-probe raw screen \(image.cgImage?.width ?? 0)x\(image.cgImage?.height ?? 0), orientation \(image.imageOrientation.rawValue)")
        }
        guard let raw = image.cgImage else { XCTFail("The screen capture has no pixel image"); return }
        let quarterTurns: [UIImage.Orientation] = [.left, .leftMirrored, .right, .rightMirrored]
        let turns = quarterTurns.contains(image.imageOrientation)
        let width = Double(turns ? raw.height : raw.width), height = Double(turns ? raw.width : raw.height)
        guard abs((width / height) / (screenSize.width / screenSize.height) - 1) < 0.01 else {
            XCTFail("The screen capture's orientation does not match the app; refusing to stretch it"); return
        }
        let format = UIGraphicsImageRendererFormat()
        let shortPixels = image.cgImage.map { CGFloat(min($0.width, $0.height)) }
            ?? min(image.size.width, image.size.height) * image.scale
        format.scale = shortPixels / min(screenSize.width, screenSize.height); format.opaque = true
        guard abs(format.scale - format.scale.rounded()) < 0.01 else {
            XCTFail("The screen capture has an invalid point scale \(format.scale)"); return
        }
        let normalized = UIGraphicsImageRenderer(size: screenSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: screenSize))
        }
        if let data = normalized.pngData() { frames.append(data) }
    }
}

/// The empty composer's placeholder and one keyboard key translate as rigid
/// pixel patches. Their relative translation measures the physical gap.
struct KeyboardPixelTemplate {
    let rect: CGRect
    let scale: Double
    let pixels: [UInt8]
    init?(image: CGImage, rect: CGRect, scale: Double) {
        self.rect = CGRect(x: (rect.minX * scale).rounded(), y: (rect.minY * scale).rounded(),
                           width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded())
        self.scale = scale
        guard let patch = image.cropping(to: self.rect), let pixels = Self.pixels(patch) else { return nil }
        self.pixels = pixels
    }
    func translation(in image: CGImage, maximum: Double) -> Double? {
        var best = Double.infinity, offset = 0
        let last = min(Int(maximum * scale), image.height - Int(rect.maxY))
        guard last >= 0 else { return nil }
        for displacement in -min(3, Int(rect.minY))...last {
            guard let patch = image.cropping(to: rect.offsetBy(dx: 0, dy: Double(displacement))),
                  let candidate = Self.pixels(patch), candidate.count == pixels.count else { continue }
            var error = 0.0, count = 0
            for index in stride(from: 0, to: pixels.count, by: 12) {
                error += abs(Double(pixels[index]) - Double(candidate[index]))
                    + abs(Double(pixels[index + 1]) - Double(candidate[index + 1]))
                    + abs(Double(pixels[index + 2]) - Double(candidate[index + 2]))
                count += 3
            }
            error /= Double(max(1, count))
            if error < best { best = error; offset = displacement }
        }
        guard best < 24 else { return nil }
        return Double(offset) / scale
    }
    func difference(in image: CGImage) -> Double? {
        guard let patch = image.cropping(to: rect), let candidate = Self.pixels(patch), candidate.count == pixels.count else { return nil }
        var error = 0.0, count = 0
        for index in stride(from: 0, to: pixels.count, by: 12) {
            for channel in 0..<3 { error += abs(Double(pixels[index + channel]) - Double(candidate[index + channel])) }
            count += 3
        }
        return error / Double(max(1, count))
    }
    private static func pixels(_ image: CGImage) -> [UInt8]? {
        var result = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let made = result.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); return true
        }
        return made ? result : nil
    }
    static func keyboardTop(in image: CGImage, after composerBottom: Double, before accessibilityTop: Double, scale: Double) -> Double? {
        // The accessibility keyboard frame can omit its prediction row. Find
        // the physical background edge in the pixels below the resting bar.
        let low = max(3, Int(max(composerBottom + 2, accessibilityTop - 130) * scale))
        let high = min(image.height - 3, Int((accessibilityTop - 4) * scale))
        guard low <= high else { return nil }
        let x = Double(image.width) * 0.1, width = Double(image.width) * 0.8
        func mean(at y: Int) -> [Double]? {
            guard let row = image.cropping(to: CGRect(x: x, y: Double(y), width: width, height: 1)),
                  let values = pixels(row) else { return nil }
            var total = [0.0, 0.0, 0.0], count = 0
            for index in stride(from: 0, to: values.count, by: 12) {
                for channel in 0..<3 { total[channel] += Double(values[index + channel]) }
                count += 1
            }
            return total.map { $0 / Double(max(1, count)) }
        }
        var best = 0.0, edge: Int?
        for y in low...high {
            guard let above = mean(at: y - 2), let below = mean(at: y + 1) else { continue }
            let difference = zip(above, below).reduce(0.0) { $0 + abs($1.0 - $1.1) }
            if difference > best { best = difference; edge = y }
        }
        guard best > 12, let edge else { return nil }
        return Double(edge) / scale
    }
}
#endif