#if canImport(UIKit)
import UIKit
@testable import UltraCore
import UltraView

/// A node tree shown in a window-backed host, as on screen.
@MainActor
final class Hosted {
    let window: UIWindow
    let host: NodeHostView

    init(_ root: UltraNode, size: CGSize = CGSize(width: 390, height: 700)) {
        window = makeWindow()
        window.frame = CGRect(origin: .zero, size: size)
        host = NodeHostView(rootNode: root)
        host.frame = window.bounds
        window.addSubview(host)
        window.isHidden = false
        host.layoutIfNeeded()
    }

    /// Waits for the pipeline and applies what it produced.
    func settle() async {
        await host.settle()
    }

    var scale: CGFloat {
        host.traitCollection.displayScale > 0 ? host.traitCollection.displayScale : 3
    }
}

/// A window outside any scene. Test bundles run without an app and so
/// without a window scene; the scene-less initializers are deprecated, so
/// this goes through `NSObject`'s `init`, which UIKit still serves.
@MainActor
func makeWindow() -> UIWindow {
    (UIWindow.self as NSObject.Type).init() as! UIWindow
}

/// The pixels of a node's bitmap, read back for probes. Coordinates are in
/// points from the top-left of the node.
struct Pixels {
    let width: Int
    let height: Int
    let scale: CGFloat
    private let bytes: [UInt8]

    @MainActor
    init?(_ node: UltraNode) {
        guard let view = node.view, let contents = view.layer.contents else { return nil }
        let image = contents as! CGImage
        self.init(image, pointWidth: view.bounds.width)
    }

    init(_ image: CGImage, pointWidth: CGFloat) {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        self.width = width
        self.height = height
        self.scale = CGFloat(width) / pointWidth
        self.bytes = bytes
    }

    /// Red, green, blue (premultiplied) and alpha in 0...1 at a pixel.
    func rgba(px x: Int, _ y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
        let offset = (y * width + x) * 4
        return (Double(bytes[offset]) / 255, Double(bytes[offset + 1]) / 255, Double(bytes[offset + 2]) / 255, Double(bytes[offset + 3]) / 255)
    }

    /// The pixel rows and columns covering a rectangle in points.
    func pixelRange(_ rect: CGRect) -> (xs: Range<Int>, ys: Range<Int>) {
        let x0 = max(0, Int((rect.minX * scale).rounded(.down)))
        let x1 = min(width, Int((rect.maxX * scale).rounded(.up)))
        let y0 = max(0, Int((rect.minY * scale).rounded(.down)))
        let y1 = min(height, Int((rect.maxY * scale).rounded(.up)))
        return (x0..<max(x0, x1), y0..<max(y0, y1))
    }

    /// Pixels in `rect` with alpha over one half.
    func ink(in rect: CGRect) -> Int {
        let (xs, ys) = pixelRange(rect)
        var count = 0
        for y in ys {
            for x in xs where rgba(px: x, y).a > 0.5 {
                count += 1
            }
        }
        return count
    }

    /// The average un-premultiplied color of the inked pixels in `rect`.
    func averageInkColor(in rect: CGRect) -> (r: Double, g: Double, b: Double)? {
        let (xs, ys) = pixelRange(rect)
        var sum = (r: 0.0, g: 0.0, b: 0.0)
        var count = 0
        for y in ys {
            for x in xs {
                let pixel = rgba(px: x, y)
                guard pixel.a > 0.8 else { continue }
                sum.r += pixel.r / pixel.a
                sum.g += pixel.g / pixel.a
                sum.b += pixel.b / pixel.a
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return (sum.r / Double(count), sum.g / Double(count), sum.b / Double(count))
    }

    /// The leftmost and rightmost inked x, in points.
    var inkedColumns: ClosedRange<CGFloat>? {
        var low: Int?
        var high: Int?
        for x in 0..<width {
            for y in 0..<height where rgba(px: x, y).a > 0.5 {
                low = low ?? x
                high = x
                break
            }
        }
        guard let low, let high else { return nil }
        return CGFloat(low) / scale...CGFloat(high + 1) / scale
    }
}

/// Builds a style in place.
func styled(_ body: (inout Style) -> Void) -> Style {
    var style = Style()
    body(&style)
    return style
}

/// Records press callbacks in order.
@MainActor
final class EventLog {
    var events: [String] = []

    nonisolated init() {}

    func handler(_ name: String) -> PressHandler {
        { [weak self] in self?.events.append(name) }
    }
}
#endif
