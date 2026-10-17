import Foundation
import Synchronization
import UltraLayout
#if canImport(UIKit)
import CoreGraphics
#endif

/// Something a node draws into its bitmap. Values are captured off the main
/// thread and drawn on the display queue, so a drawing holds everything it
/// needs and touches nothing shared.
public protocol Drawing: Sendable {
    #if canImport(UIKit)
    /// Draws into `context`, whose origin is the top-left corner and whose
    /// unit is a point.
    func draw(in context: CGContext, bounds: CGRect)
    #endif
}

/// A finished bitmap for a node's layer.
public struct Contents: Sendable {
    /// Unique per bitmap.
    public let id: UInt64
    public let size: CGSize
    public let scale: CGFloat
    /// The image: a `CGImage` on Apple platforms. Tests on other platforms
    /// put any token here.
    public let image: any Sendable

    public init(size: CGSize, scale: CGFloat, image: any Sendable) {
        id = IDs.contents.next()
        self.size = size
        self.scale = scale
        self.image = image
    }
}

/// Turns drawings into bitmaps. Called on the display queue, many at a time.
public protocol Rasterizer: Sendable {
    /// Returns `nil` when there is nothing to show or `isCancelled` became
    /// true while drawing.
    func rasterize(_ drawing: any Drawing, size: CGSize, scale: CGFloat, isCancelled: () -> Bool) -> Contents?
}

/// Increasing identifiers shared across threads.
final class IDGenerator: Sendable {
    private let value = Atomic<UInt64>(0)

    func next() -> UInt64 {
        value.add(1, ordering: .relaxed).newValue
    }
}

enum IDs {
    static let contents = IDGenerator()
    static let textLayout = IDGenerator()
}

/// A node's box: background, borders per side and corner radii, resolved for
/// one frame and appearance.
struct BoxStyle: Sendable, Equatable {
    var background: Color.Components?
    var radii: CornerRadii
    var widths: Insets
    var topColor: Color.Components
    var leftColor: Color.Components
    var bottomColor: Color.Components
    var rightColor: Color.Components

    init(style: Style, borderWidths: Insets, size: CGSize, isDark: Bool, isRightToLeft: Bool) {
        background = style.backgroundColor?.resolved(dark: isDark)
        widths = borderWidths

        let limit = max(0, min(size.width, size.height) / 2)
        let base = style.borderRadius ?? 0
        radii = CornerRadii(
            topLeft: min(style.borderTopLeftRadius ?? base, limit),
            topRight: min(style.borderTopRightRadius ?? base, limit),
            bottomLeft: min(style.borderBottomLeftRadius ?? base, limit),
            bottomRight: min(style.borderBottomRightRadius ?? base, limit)
        )

        let fallbackColor = style.borderColor ?? .black
        let startColor = isRightToLeft ? style.borderEndColor : style.borderStartColor
        let endColor = isRightToLeft ? style.borderStartColor : style.borderEndColor
        topColor = (style.borderTopColor ?? fallbackColor).resolved(dark: isDark)
        bottomColor = (style.borderBottomColor ?? fallbackColor).resolved(dark: isDark)
        leftColor = (startColor ?? style.borderLeftColor ?? fallbackColor).resolved(dark: isDark)
        rightColor = (endColor ?? style.borderRightColor ?? fallbackColor).resolved(dark: isDark)
    }

    var hasBorder: Bool {
        widths.top > 0 || widths.left > 0 || widths.bottom > 0 || widths.right > 0
    }

    var isEmpty: Bool {
        (background?.isClear ?? true) && !hasBorder
    }

    /// Whether a layer's own background, border and corner properties can
    /// show this box: one border width and color, and one radius for the
    /// rounded corners.
    var isLayerRepresentable: Bool {
        if hasBorder {
            let uniformWidth = widths.top == widths.left && widths.top == widths.bottom && widths.top == widths.right
            let uniformColor = topColor == leftColor && topColor == bottomColor && topColor == rightColor
            guard uniformWidth && uniformColor else { return false }
        }
        return radii.uniformRadius != nil
    }
}

public struct CornerRadii: Sendable, Equatable {
    public var topLeft: CGFloat
    public var topRight: CGFloat
    public var bottomLeft: CGFloat
    public var bottomRight: CGFloat

    /// The radius shared by every rounded corner, or `nil` when rounded
    /// corners differ. 0 when no corner is rounded.
    var uniformRadius: CGFloat? {
        let rounded = [topLeft, topRight, bottomLeft, bottomRight].filter { $0 > 0 }
        guard let first = rounded.first else { return 0 }
        return rounded.allSatisfy { $0 == first } ? first : nil
    }

    var mask: CornerMask {
        var mask: CornerMask = []
        if topLeft > 0 { mask.insert(.topLeft) }
        if topRight > 0 { mask.insert(.topRight) }
        if bottomLeft > 0 { mask.insert(.bottomLeft) }
        if bottomRight > 0 { mask.insert(.bottomRight) }
        return mask.isEmpty ? .all : mask
    }
}

/// What a node's bitmap shows: its box, when a layer can't show it, under
/// its content (text or a custom drawing).
struct NodeDrawing: Drawing {
    var box: BoxStyle?
    var content: (any Drawing)?

    #if canImport(UIKit)
    func draw(in context: CGContext, bounds: CGRect) {
        if let box {
            box.draw(in: context, bounds: bounds)
        }
        if let content {
            context.saveGState()
            content.draw(in: context, bounds: bounds)
            context.restoreGState()
        }
    }
    #endif
}

/// Identifies what a node's bitmap shows, so the pipeline redraws only when
/// it changes.
struct DrawingKey: Sendable, Equatable {
    enum Content: Sendable, Equatable {
        case none
        /// A custom drawing, by the node's drawing version.
        case custom(UInt64)
        /// Text, by layout.
        case text(UInt64)
    }

    var size: CGSize
    var scale: CGFloat
    var box: BoxStyle?
    var content: Content
}
