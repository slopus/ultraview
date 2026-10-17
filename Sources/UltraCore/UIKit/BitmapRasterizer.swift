#if canImport(UIKit)
import CoreGraphics
import UIKit
import UltraLayout

/// Draws into a Core Graphics bitmap, off the main thread.
public struct BitmapRasterizer: Rasterizer {
    /// Larger bitmaps aren't drawn; the node shows its layer properties only.
    public var maxPixels = 4096 * 4096

    public init() {}

    public func rasterize(_ drawing: any Drawing, size: CGSize, scale: CGFloat, isCancelled: () -> Bool) -> Contents? {
        let width = Int((size.width * scale).rounded(.up))
        let height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0, width * height <= maxPixels,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }
        // Points, origin at the top-left, like a view.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        drawing.draw(in: context, bounds: CGRect(origin: .zero, size: size))
        guard !isCancelled(), let image = context.makeImage() else { return nil }
        return Contents(size: size, scale: scale, image: Bitmap(image))
    }
}

/// A finished bitmap.
final class Bitmap: @unchecked Sendable {
    // @unchecked Sendable: CGImage is immutable.
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}

extension Contents {
    /// The bitmap, when it came from `BitmapRasterizer`.
    public var cgImage: CGImage? {
        (image as? Bitmap)?.image
    }
}

extension BoxStyle {
    /// Fills the background inside the rounded outline, then each border
    /// side in its own color: the ring between the outer and inner outlines,
    /// cut into four trapezoids at the corners.
    func draw(in context: CGContext, bounds: CGRect) {
        let outer = Self.roundedPath(bounds, radii)
        if let background, !background.isClear {
            context.addPath(outer)
            context.setFillColor(background.cgColor)
            context.fillPath()
        }
        guard hasBorder else { return }

        let inner = CGRect(
            x: bounds.minX + widths.left,
            y: bounds.minY + widths.top,
            width: max(0, bounds.width - widths.left - widths.right),
            height: max(0, bounds.height - widths.top - widths.bottom)
        )
        let innerRadii = CornerRadii(
            topLeft: max(0, radii.topLeft - max(widths.left, widths.top)),
            topRight: max(0, radii.topRight - max(widths.right, widths.top)),
            bottomLeft: max(0, radii.bottomLeft - max(widths.left, widths.bottom)),
            bottomRight: max(0, radii.bottomRight - max(widths.right, widths.bottom))
        )
        let ring = CGMutablePath()
        ring.addPath(outer)
        if inner.width > 0, inner.height > 0 {
            ring.addPath(Self.roundedPath(inner, innerRadii))
        }

        let sides: [(Color.Components, [CGPoint])] = [
            (topColor, [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY), CGPoint(x: inner.maxX, y: inner.minY), CGPoint(x: inner.minX, y: inner.minY)]),
            (rightColor, [CGPoint(x: bounds.maxX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.maxY), CGPoint(x: inner.maxX, y: inner.maxY), CGPoint(x: inner.maxX, y: inner.minY)]),
            (bottomColor, [CGPoint(x: bounds.maxX, y: bounds.maxY), CGPoint(x: bounds.minX, y: bounds.maxY), CGPoint(x: inner.minX, y: inner.maxY), CGPoint(x: inner.maxX, y: inner.maxY)]),
            (leftColor, [CGPoint(x: bounds.minX, y: bounds.maxY), CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: inner.minX, y: inner.minY), CGPoint(x: inner.minX, y: inner.maxY)]),
        ]
        for (color, polygon) in sides where !color.isClear {
            context.saveGState()
            context.addLines(between: polygon)
            context.closePath()
            context.clip()
            context.addPath(ring)
            context.setFillColor(color.cgColor)
            context.fillPath(using: .evenOdd)
            context.restoreGState()
        }
    }

    static func roundedPath(_ rect: CGRect, _ radii: CornerRadii) -> CGPath {
        let limit = min(rect.width, rect.height) / 2
        let topLeft = min(radii.topLeft, limit)
        let topRight = min(radii.topRight, limit)
        let bottomLeft = min(radii.bottomLeft, limit)
        let bottomRight = min(radii.bottomRight, limit)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + topLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topRight, y: rect.minY))
        if topRight > 0 {
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + topRight), radius: topRight)
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRight))
        if bottomRight > 0 {
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - bottomRight, y: rect.maxY), radius: bottomRight)
        }
        path.addLine(to: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY))
        if bottomLeft > 0 {
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bottomLeft), radius: bottomLeft)
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeft))
        if topLeft > 0 {
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + topLeft, y: rect.minY), radius: topLeft)
        }
        path.closeSubpath()
        return path
    }
}
#endif
