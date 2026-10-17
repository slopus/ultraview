import Foundation
import UltraLayout

/// Text broken into lines for one width limit. Produced by a `TextMeasurer`
/// off the main thread; the same value sizes the node in Yoga and is drawn
/// into its bitmap, so text is laid out once per width.
public struct TextLayout: Sendable {
    public struct Line: Sendable, Equatable {
        /// UTF-16 range of the source string on this line.
        public var range: Range<Int>
        /// Top of the line box.
        public var top: CGFloat
        public var height: CGFloat
        /// Baseline, from the top of the layout.
        public var baseline: CGFloat
        /// Width of the glyphs, without trailing whitespace.
        public var width: CGFloat
        /// Justified lines span the whole width limit.
        public var isJustified = false

        public init(range: Range<Int>, top: CGFloat, height: CGFloat, baseline: CGFloat, width: CGFloat, isJustified: Bool = false) {
            self.range = range
            self.top = top
            self.height = height
            self.baseline = baseline
            self.width = width
            self.isJustified = isJustified
        }
    }

    /// Part of a pressable span on one line.
    public struct LinkSegment: Sendable, Equatable {
        public var link: Int
        public var line: Int
        /// From the start of the line's glyphs.
        public var minX: CGFloat
        public var maxX: CGFloat

        public init(link: Int, line: Int, minX: CGFloat, maxX: CGFloat) {
            self.link = link
            self.line = line
            self.minX = minX
            self.maxX = maxX
        }
    }

    public enum Alignment: Sendable, Equatable {
        case left
        case center
        case right
    }

    /// Unique per layout: drawing and caching key on it.
    public let id: UInt64
    public var text: AttributedText
    /// The width limit it was laid out for; `nil` for none.
    public var maxWidth: CGFloat?
    /// Rounded up to the pixel grid.
    public var size: CGSize
    public var lines: [Line]
    /// Lines that don't fill the width are placed this way.
    public var alignment: Alignment
    /// Some text didn't fit in `numberOfLines`.
    public var isTruncated: Bool
    /// Some line ended because of the width limit, not a line break.
    public var didWrap: Bool
    public var links: [LinkSegment]
    /// The measurer's own representation (Core Text lines on Apple
    /// platforms), used when drawing.
    public var storage: (any Sendable)?

    public init(
        text: AttributedText,
        maxWidth: CGFloat?,
        size: CGSize,
        lines: [Line],
        alignment: Alignment,
        isTruncated: Bool,
        didWrap: Bool,
        links: [LinkSegment] = [],
        storage: (any Sendable)? = nil
    ) {
        id = IDs.textLayout.next()
        self.text = text
        self.maxWidth = maxWidth
        self.size = size
        self.lines = lines
        self.alignment = alignment
        self.isTruncated = isTruncated
        self.didWrap = didWrap
        self.links = links
        self.storage = storage
    }

    /// Whether this layout breaks lines exactly as a fresh layout for
    /// `width` would, so it can stand in for it. Greedy line breaking gives
    /// the same lines for any limit between the widest line and the limit
    /// used, unless the text was cut short or justified.
    public func fits(width: CGFloat?) -> Bool {
        if width == maxWidth {
            return true
        }
        if isTruncated, let width, let compatibility = storage as? any TextLayoutWidthCompatibility,
           compatibility.fits(width: width) {
            return true
        }
        guard !isTruncated, !lines.contains(where: \.isJustified) else { return false }
        guard let width else {
            return !didWrap
        }
        let limit = maxWidth ?? .infinity
        return width <= limit && size.width <= width + 0.001
    }

    /// Where line `index` starts in a box `width` wide.
    public func originX(ofLine index: Int, inWidth width: CGFloat) -> CGFloat {
        let line = lines[index]
        if line.isJustified {
            return 0
        }
        switch alignment {
        case .left: return 0
        case .center: return max(0, (width - line.width) / 2)
        case .right: return max(0, width - line.width)
        }
    }

    /// The rectangles of each pressable span, for a box `width` wide.
    public func linkRegions(inWidth width: CGFloat) -> [TextLinkRegion] {
        var rects: [Int: [CGRect]] = [:]
        for segment in links {
            let line = lines[segment.line]
            let x = originX(ofLine: segment.line, inWidth: width)
            rects[segment.link, default: []].append(CGRect(
                x: x + segment.minX,
                y: line.top,
                width: segment.maxX - segment.minX,
                height: line.height
            ))
        }
        return rects.keys.sorted().map { TextLinkRegion(index: $0, rects: rects[$0]!) }
    }
}

/// A platform measurer can certify an otherwise conservative width-cache miss.
protocol TextLayoutWidthCompatibility: Sendable {
    func fits(width: CGFloat) -> Bool
}

/// Lays out text. Custom measurers are called on the layout queue; the
/// built-in platform measurer may also prepare independent nodes on workers.
public protocol TextMeasurer: Sendable {
    func layout(_ text: AttributedText, maxWidth: CGFloat?, scale: CGFloat) -> TextLayout
}

/// Rounds up to the pixel grid.
func ceilToPixel(_ value: CGFloat, scale: CGFloat) -> CGFloat {
    guard scale > 0 else { return value.rounded(.up) }
    return (value * scale - 0.0001).rounded(.up) / scale
}

/// A measurer for platforms without Core Text: fixed-width characters,
/// greedy word wrap, no truncation glyph. Good enough to exercise layout.
public struct ApproximateTextMeasurer: TextMeasurer {
    /// Character width as a fraction of the font size.
    public var characterWidth: CGFloat

    public init(characterWidth: CGFloat = 0.5) {
        self.characterWidth = characterWidth
    }

    public func layout(_ text: AttributedText, maxWidth: CGFloat?, scale: CGFloat) -> TextLayout {
        let units = Array(text.string.utf16)
        let limit = maxWidth ?? .infinity
        let maxLines = text.paragraph.numberOfLines > 0 ? text.paragraph.numberOfLines : Int.max

        func width(of index: Int) -> CGFloat {
            let style = text.run(at: index)?.style ?? TextContent.defaultStyle
            return style.fontSize * characterWidth + style.letterSpacing
        }

        func height(of range: Range<Int>) -> CGFloat {
            if let lineHeight = text.paragraph.lineHeight { return lineHeight }
            let sizes = range.compactMap { text.run(at: $0)?.style.fontSize }
            return (sizes.max() ?? text.runs.first?.style.fontSize ?? 14) * 1.2
        }

        var lines: [TextLayout.Line] = []
        var start = 0
        var top: CGFloat = 0
        var didWrap = false
        while start < units.count, lines.count < maxLines {
            var end = start
            var lineWidth: CGFloat = 0
            var lastBreak: Int?
            var hardBreak = false
            while end < units.count {
                if units[end] == 10 {
                    hardBreak = true
                    break
                }
                let next = width(of: end)
                if lineWidth + next > limit, end > start {
                    didWrap = true
                    if let lastBreak {
                        end = lastBreak
                    }
                    break
                }
                lineWidth += next
                end += 1
                if units[end - 1] == 32 {
                    lastBreak = end
                }
            }
            let range = start..<end
            var glyphWidth: CGFloat = 0
            for index in range where units[index] != 32 || index < range.upperBound - 1 {
                glyphWidth += width(of: index)
            }
            let lineHeight = height(of: range.isEmpty ? start..<min(start + 1, units.count) : range)
            lines.append(.init(range: range, top: top, height: lineHeight, baseline: top + lineHeight * 0.8, width: glyphWidth))
            top += lineHeight
            start = hardBreak ? end + 1 : end
        }
        let widest = lines.map(\.width).max() ?? 0
        let alignment: TextLayout.Alignment = switch text.paragraph.alignment {
        case .center: .center
        case .right: .right
        default: .left
        }
        var links: [TextLayout.LinkSegment] = []
        for (index, line) in lines.enumerated() {
            var x: CGFloat = 0
            for offset in line.range {
                let w = width(of: offset)
                if let link = text.run(at: offset)?.link {
                    if let last = links.last, last.link == link, last.line == index, last.maxX == x {
                        links[links.count - 1].maxX = x + w
                    } else {
                        links.append(.init(link: link, line: index, minX: x, maxX: x + w))
                    }
                }
                x += w
            }
        }
        return TextLayout(
            text: text,
            maxWidth: maxWidth,
            size: CGSize(width: ceilToPixel(min(widest, limit), scale: scale), height: ceilToPixel(top, scale: scale)),
            lines: lines,
            alignment: alignment,
            isTruncated: start < units.count,
            didWrap: didWrap,
            links: links
        )
    }
}
