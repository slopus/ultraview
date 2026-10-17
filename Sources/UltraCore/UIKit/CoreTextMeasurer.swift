#if canImport(UIKit)
import CoreText
import Synchronization
import UIKit
import UltraLayout

/// Lays text out with Core Text, off the main thread.
///
/// Lines are broken by a typesetter, one at a time, so line boxes, line
/// heights and truncation are under our control: a line box is the tallest
/// run's ascent, descent and leading, or `lineHeight` with the glyphs
/// centered in it. The last allowed line is truncated with an ellipsis in
/// the style of the text it replaces.
public struct CoreTextMeasurer: TextMeasurer {
    public init() {}

    public func layout(_ text: AttributedText, maxWidth: CGFloat?, scale: CGFloat) -> TextLayout {
        let length = text.length
        guard length > 0 else {
            return TextLayout(text: text, maxWidth: maxWidth, size: .zero, lines: [], alignment: .left, isTruncated: false, didWrap: false)
        }
        let attributed = Self.attributedString(for: text)
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let units = Array(text.string.utf16)
        let limit = maxWidth ?? 1_000_000
        let paragraph = text.paragraph
        let maxLines = paragraph.numberOfLines > 0 ? paragraph.numberOfLines : Int.max

        // Break lines.
        var ctLines: [CTLine] = []
        var ranges: [Range<Int>] = []
        var endsParagraph: [Bool] = []
        var start = 0
        var didWrap = false
        while start < length, ctLines.count < maxLines {
            var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(limit))
            if count <= 0 {
                count = length - start
            }
            let end = start + count
            let hardBreak = end == length || Self.isLineBreak(units[end - 1])
            if !hardBreak {
                didWrap = true
            }
            ctLines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
            ranges.append(start..<end)
            endsParagraph.append(hardBreak)
            start = end
        }

        // Cut what didn't fit.
        let isTruncated = start < length
        if isTruncated, let lastRange = ranges.last {
            var paragraphEnd = lastRange.lowerBound
            while paragraphEnd < length, !Self.isLineBreak(units[paragraphEnd]) {
                paragraphEnd += 1
            }
            let source = NSMutableAttributedString(
                attributedString: (attributed as NSAttributedString).attributedSubstring(
                    from: NSRange(location: lastRange.lowerBound, length: paragraphEnd - lastRange.lowerBound)
                )
            )
            let styleIndex = max(lastRange.lowerBound, min(paragraphEnd, length) - 1)
            let style = text.run(at: styleIndex)?.style ?? text.runs[0].style
            if paragraph.ellipsizeMode == .clip {
                ctLines[ctLines.count - 1] = CTLineCreateWithAttributedString(source)
            } else {
                let ellipsis = NSAttributedString(string: "\u{2026}", attributes: Self.attributes(for: style))
                let token = CTLineCreateWithAttributedString(ellipsis)
                if paragraph.ellipsizeMode == .tail {
                    // Like a label: the words that fit beside the ellipsis,
                    // broken where a line would break, then the ellipsis.
                    // Only a word too long for the line is cut mid-word.
                    let start = lastRange.lowerBound
                    let room = limit - CGFloat(CTLineGetTypographicBounds(token, nil, nil, nil))
                    var end = start + max(0, CTTypesetterSuggestLineBreak(typesetter, start, Double(max(0, room))))
                    end = min(end, paragraphEnd)
                    while end > start, Self.isWhitespace(units[end - 1]) {
                        end -= 1
                    }
                    if end > start {
                        source.deleteCharacters(in: NSRange(location: end - start, length: source.length - (end - start)))
                        source.append(ellipsis)
                    } else if paragraphEnd < length {
                        source.append(ellipsis)
                    }
                }
                let full = CTLineCreateWithAttributedString(source)
                let type: CTLineTruncationType = switch paragraph.ellipsizeMode {
                case .head: .start
                case .middle: .middle
                default: .end
                }
                ctLines[ctLines.count - 1] = CTLineCreateTruncatedLine(full, Double(limit), type, token) ?? full
            }
            endsParagraph[endsParagraph.count - 1] = true
        }

        // Alignment, from the first line's direction for `auto`.
        let isRightToLeft = ctLines.first.map(Self.startsRightToLeft) ?? false
        let alignment: TextLayout.Alignment = switch paragraph.alignment {
        case .auto, .justify: isRightToLeft ? .right : .left
        case .left: .left
        case .right: .right
        case .center: .center
        }
        if paragraph.alignment == .justify, maxWidth != nil {
            for index in ctLines.indices where !endsParagraph[index] {
                if let justified = CTLineCreateJustifiedLine(ctLines[index], 1, Double(limit)) {
                    ctLines[index] = justified
                }
            }
        }

        // Line boxes.
        var lines: [TextLayout.Line] = []
        var links: [TextLayout.LinkSegment] = []
        var top: CGFloat = 0
        var widest: CGFloat = 0
        for (index, line) in ctLines.enumerated() {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let typographicWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let justified = paragraph.alignment == .justify && maxWidth != nil && !endsParagraph[index]
            let width = justified ? limit : max(0, typographicWidth - CGFloat(CTLineGetTrailingWhitespaceWidth(line)))
            // A wrapped line's box keeps the space it broke at, as a label
            // measures it; alignment uses the width without it.
            let boxWidth = endsParagraph[index] ? width : min(typographicWidth, limit)
            let height: CGFloat
            let baseline: CGFloat
            if let lineHeight = paragraph.lineHeight {
                height = lineHeight
                baseline = top + (lineHeight - (ascent + descent)) / 2 + ascent
            } else {
                height = ascent + descent + leading
                baseline = top + ascent
            }
            lines.append(.init(range: ranges[index], top: top, height: height, baseline: baseline, width: width, isJustified: justified))
            widest = max(widest, boxWidth)
            top += height

            if text.linkCount > 0 {
                for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                    guard let link = Self.textRun(of: run, in: text)?.link else { continue }
                    var position = CGPoint.zero
                    CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
                    let runWidth = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil))
                    if let last = links.last, last.link == link, last.line == index, abs(last.maxX - position.x) < 0.5 {
                        links[links.count - 1].maxX = position.x + runWidth
                    } else {
                        links.append(.init(link: link, line: index, minX: position.x, maxX: position.x + runWidth))
                    }
                }
            }
        }

        return TextLayout(
            text: text,
            maxWidth: maxWidth,
            size: CGSize(width: ceilToPixel(min(widest, limit), scale: scale), height: ceilToPixel(top, scale: scale)),
            lines: lines,
            alignment: alignment,
            isTruncated: isTruncated,
            didWrap: didWrap,
            links: links,
            storage: CoreTextLines(ctLines)
        )
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0xA0 || isLineBreak(unit)
    }

    private static func isLineBreak(_ unit: UInt16) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029
    }

    private static func startsRightToLeft(_ line: CTLine) -> Bool {
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        guard let first = runs.min(by: { CTRunGetStringRange($0).location < CTRunGetStringRange($1).location }) else {
            return false
        }
        return CTRunGetStatus(first).contains(.rightToLeft)
    }

    /// Marks each character with the index of its run in `AttributedText`.
    /// Core Text groups glyphs into runs by font and color only; the mark
    /// keeps spans that differ in other ways (backgrounds, decorations,
    /// links) in separate glyph runs, and lets truncated lines, whose string
    /// indices start over, find their spans.
    static let runIndexKey = NSAttributedString.Key("UltraTextRunIndex")

    static func attributedString(for text: AttributedText) -> CFAttributedString {
        let result = NSMutableAttributedString(string: text.string)
        for (index, run) in text.runs.enumerated() {
            var attributes = attributes(for: run.style)
            attributes[runIndexKey] = index
            result.addAttributes(attributes, range: NSRange(location: run.range.lowerBound, length: run.range.count))
        }
        return result
    }

    /// The `AttributedText` run a glyph run was laid out from; `nil` for an
    /// ellipsis.
    static func textRun(of run: CTRun, in text: AttributedText) -> AttributedText.Run? {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard let index = attributes[runIndexKey.rawValue] as? Int, text.runs.indices.contains(index) else { return nil }
        return text.runs[index]
    }

    static func attributes(for style: ResolvedTextStyle) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): FontCache.shared.font(for: style),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): style.color.cgColor,
        ]
        if style.letterSpacing != 0 {
            attributes[NSAttributedString.Key(kCTKernAttributeName as String)] = style.letterSpacing
        }
        return attributes
    }
}

/// The Core Text lines of one layout.
final class CoreTextLines: @unchecked Sendable {
    // @unchecked Sendable: never changed after `init`. Core Text lines are
    // immutable and may be read and drawn from any thread.
    let lines: [CTLine]

    init(_ lines: [CTLine]) {
        self.lines = lines
    }
}

/// Fonts by style, created once. UIFont is documented thread-safe.
final class FontCache: Sendable {
    static let shared = FontCache()

    private struct Key: Hashable {
        var size: CGFloat
        var weight: FontWeight
        var isItalic: Bool
        var family: String?
    }

    private final class Box: @unchecked Sendable {
        // @unchecked Sendable: UIFont is immutable and thread-safe.
        let font: UIFont
        init(_ font: UIFont) { self.font = font }
    }

    private let fonts = Mutex<[Key: Box]>([:])

    func font(for style: ResolvedTextStyle) -> UIFont {
        let key = Key(size: style.fontSize, weight: style.fontWeight, isItalic: style.isItalic, family: style.fontFamily)
        if let box = fonts.withLock({ $0[key] }) {
            return box.font
        }
        let font = Self.makeFont(key)
        fonts.withLock { $0[key] = Box(font) }
        return font
    }

    private static func makeFont(_ key: Key) -> UIFont {
        var font: UIFont
        if let family = key.family {
            if let named = UIFont(name: family, size: key.size), key.weight == .regular {
                font = named
            } else {
                var descriptor = UIFontDescriptor(fontAttributes: [
                    .family: family,
                    .traits: [UIFontDescriptor.TraitKey.weight: key.weight.uiFontWeight.rawValue],
                ])
                if key.weight.rawValue >= FontWeight.semibold.rawValue {
                    descriptor = descriptor.withSymbolicTraits(.traitBold) ?? descriptor
                }
                font = UIFont(descriptor: descriptor, size: key.size)
            }
        } else {
            font = UIFont.systemFont(ofSize: key.size, weight: key.weight.uiFontWeight)
        }
        if key.isItalic,
           let italic = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)) {
            font = UIFont(descriptor: italic, size: key.size)
        }
        return font
    }
}

extension FontWeight {
    var uiFontWeight: UIFont.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        }
    }
}

extension Color.Components {
    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

extension TextDrawing {
    func draw(in context: CGContext, bounds box: CGRect) {
        guard let storage = layout.storage as? CoreTextLines else { return }
        let bounds = CGRect(
            x: box.minX + inset.left,
            y: box.minY + inset.top,
            width: max(0, box.width - inset.left - inset.right),
            height: max(0, box.height - inset.top - inset.bottom)
        )
        let text = layout.text
        context.clip(to: bounds)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (index, line) in layout.lines.enumerated() where index < storage.lines.count {
            let ctLine = storage.lines[index]
            let x = bounds.minX + layout.originX(ofLine: index, inWidth: bounds.width)
            let baseline = bounds.minY + line.baseline
            let runs = CTLineGetGlyphRuns(ctLine) as! [CTRun]

            // Span backgrounds go under the glyphs.
            for run in runs {
                guard let color = CoreTextMeasurer.textRun(of: run, in: text)?.style.backgroundColor else { continue }
                let (runX, runWidth) = Self.extent(of: run)
                context.setFillColor(color.cgColor)
                context.fill(CGRect(x: x + runX, y: bounds.minY + line.top, width: runWidth, height: line.height))
            }

            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(ctLine, context)

            for run in runs {
                guard let style = CoreTextMeasurer.textRun(of: run, in: text)?.style, style.decorationLine != .none else { continue }
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard let fontValue = attributes[kCTFontAttributeName as String] else { continue }
                let font = fontValue as! CTFont
                let (runX, runWidth) = Self.extent(of: run)
                let thickness = max(CTFontGetUnderlineThickness(font), 1 / max(context.ctm.a, 1))
                let color = (style.decorationColor ?? style.color).cgColor
                if style.decorationLine.hasUnderline {
                    let y = baseline - CTFontGetUnderlinePosition(font) + thickness / 2
                    Self.strokeDecoration(in: context, from: x + runX, to: x + runX + runWidth, y: y, thickness: thickness, style: style.decorationStyle, color: color)
                }
                if style.decorationLine.hasLineThrough {
                    let y = baseline - CTFontGetXHeight(font) / 2
                    Self.strokeDecoration(in: context, from: x + runX, to: x + runX + runWidth, y: y, thickness: thickness, style: style.decorationStyle, color: color)
                }
            }
        }
    }

    private static func extent(of run: CTRun) -> (x: CGFloat, width: CGFloat) {
        var position = CGPoint.zero
        CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
        let width = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil))
        return (position.x, width)
    }

    private static func strokeDecoration(
        in context: CGContext,
        from startX: CGFloat,
        to endX: CGFloat,
        y: CGFloat,
        thickness: CGFloat,
        style: TextDecorationStyle,
        color: CGColor
    ) {
        context.saveGState()
        context.setStrokeColor(color)
        context.setLineWidth(thickness)
        switch style {
        case .solid, .double:
            context.setLineDash(phase: 0, lengths: [])
        case .dotted:
            context.setLineCap(.round)
            context.setLineDash(phase: 0, lengths: [0, thickness * 2])
        case .dashed:
            context.setLineDash(phase: 0, lengths: [thickness * 3, thickness * 2])
        }
        let offsets: [CGFloat] = style == .double ? [-thickness, thickness] : [0]
        for offset in offsets {
            context.move(to: CGPoint(x: startX, y: y + offset))
            context.addLine(to: CGPoint(x: endX, y: y + offset))
        }
        context.strokePath()
        context.restoreGState()
    }
}
#endif
