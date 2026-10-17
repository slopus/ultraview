import Foundation
import UltraLayout

/// Where a text's trailing accessory goes, and how big the text box gets
/// to make room for it.
///
/// An accessory is a small box after the text's last line, like the time
/// in a chat bubble. When the last line leaves room for it, it sits on that
/// line against the trailing edge; otherwise it takes a line of its own
/// below the text. Either way the text node measures as the box that holds
/// both, so the accessory can be placed at its parent's bottom trailing
/// corner.
public struct TrailingAccessoryFit: Sendable, Equatable {
    public enum Placement: Sendable, Equatable {
        /// On the last line, against the trailing edge.
        case inline
        /// On its own line under the text.
        case below
    }

    public var placement: Placement
    /// The text and the accessory together, rounded up to the pixel grid.
    public var size: CGSize

    public init(placement: Placement, size: CGSize) {
        self.placement = placement
        self.size = size
    }

    /// Fits an accessory of `accessory` size after `layout`, with at least
    /// `spacing` between the last line's glyphs and the accessory, within
    /// `maxWidth` (`nil` for no limit).
    ///
    /// Only left-aligned text shares its last line: centered, right-aligned
    /// and right-to-left text puts the accessory below.
    public static func fit(
        _ layout: TextLayout,
        accessory: CGSize,
        spacing: CGFloat,
        maxWidth: CGFloat?,
        scale: CGFloat
    ) -> TrailingAccessoryFit {
        let limit = maxWidth ?? .infinity
        guard let last = layout.lines.last else {
            // No text: the accessory alone.
            return TrailingAccessoryFit(
                placement: .inline,
                size: CGSize(width: ceilToPixel(min(accessory.width, limit), scale: scale), height: ceilToPixel(accessory.height, scale: scale))
            )
        }
        let sharesLine = layout.alignment == .left && !last.isJustified
        // The last line starts at x 0 for left-aligned text.
        let inlineWidth = last.width + spacing + accessory.width
        if sharesLine, inlineWidth <= limit + 0.001 {
            let width = max(layout.size.width, inlineWidth)
            // A tall accessory, bottom-aligned with the last line, can reach
            // above it; it never pushes the text down.
            let height = max(layout.size.height, accessory.height)
            return TrailingAccessoryFit(
                placement: .inline,
                size: CGSize(width: ceilToPixel(min(width, limit), scale: scale), height: ceilToPixel(height, scale: scale))
            )
        }
        let width = max(layout.size.width, accessory.width)
        return TrailingAccessoryFit(
            placement: .below,
            size: CGSize(
                width: ceilToPixel(min(width, limit), scale: scale),
                height: ceilToPixel(layout.size.height + accessory.height, scale: scale)
            )
        )
    }
}

extension TextLayout {
    /// The x where the last line's glyphs end, in a box `width` wide; 0
    /// without lines. Trailing whitespace doesn't count.
    public func lastLineMaxX(inWidth width: CGFloat) -> CGFloat {
        guard let last = lines.indices.last else { return 0 }
        return originX(ofLine: last, inWidth: width) + lines[last].width
    }
}

extension Edges where Value == UltraLayout.Dimension {
    /// The point values per physical edge, more specific edges first; start
    /// and end count as left and right. Percentages and `auto` count as 0.
    var points: Insets {
        func value(_ candidates: UltraLayout.Dimension?...) -> CGFloat {
            for candidate in candidates {
                if case .points(let points)? = candidate { return points }
                if candidate != nil { return 0 }
            }
            return 0
        }
        return Insets(
            top: value(top, vertical, all),
            left: value(start, left, horizontal, all),
            bottom: value(bottom, vertical, all),
            right: value(end, right, horizontal, all)
        )
    }
}

extension Edges where Value == CGFloat {
    /// The value per physical edge, more specific edges first; start and end
    /// count as left and right.
    var resolved: Insets {
        Insets(
            top: top ?? vertical ?? all ?? 0,
            left: start ?? left ?? horizontal ?? all ?? 0,
            bottom: bottom ?? vertical ?? all ?? 0,
            right: end ?? right ?? horizontal ?? all ?? 0
        )
    }
}
