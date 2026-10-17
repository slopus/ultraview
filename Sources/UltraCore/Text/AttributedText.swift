import Foundation
import UltraLayout

/// A flattened span tree: one string and the runs that style it. Built off
/// the main thread from a text node's spans; the input to measuring and
/// drawing.
public struct AttributedText: Sendable, Equatable {
    public struct Run: Sendable, Equatable {
        /// UTF-16 offsets into `string`.
        public var range: Range<Int>
        public var style: ResolvedTextStyle
        /// Index of the pressable span this run belongs to.
        public var link: Int?
    }

    public struct Paragraph: Sendable, Equatable {
        public var alignment: TextAlign = .auto
        /// After Dynamic Type scaling.
        public var lineHeight: CGFloat?
        /// 0 means no limit.
        public var numberOfLines = 0
        public var ellipsizeMode: EllipsizeMode = .tail
    }

    public var string: String
    public var runs: [Run]
    public var paragraph: Paragraph
    /// How many pressable spans there are.
    public var linkCount: Int

    /// UTF-16 length of `string`.
    public var length: Int { runs.last?.range.upperBound ?? 0 }

    /// The run covering a UTF-16 offset.
    public func run(at offset: Int) -> Run? {
        var low = 0
        var high = runs.count
        while low < high {
            let mid = (low + high) / 2
            if runs[mid].range.upperBound <= offset {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low < runs.count && runs[low].range.contains(offset) ? runs[low] : nil
    }
}

/// The inputs that turn spans into an `AttributedText`.
struct TextContent: Sendable {
    var spans: [TextSpan] = []
    var style = TextStyle()
    var numberOfLines = 0
    var ellipsizeMode: EllipsizeMode = .tail
    var allowFontScaling = true
    var maxFontSizeMultiplier: CGFloat?
    var suppressHighlighting = false
    /// Placed after the last line; see `UltraTextNode.trailingAccessory`.
    var accessory: UltraTextNode?
    var accessorySpacing: CGFloat = 0
    /// Bumped by every change, so the pipeline knows to re-measure.
    var version: UInt64 = 0

    static let defaultStyle = ResolvedTextStyle(
        color: Color.black.light,
        fontSize: 14,
        fontWeight: .regular,
        isItalic: false,
        fontFamily: nil,
        letterSpacing: 0,
        decorationLine: .none,
        decorationColor: nil,
        decorationStyle: .solid,
        backgroundColor: nil
    )

    /// The factor applied to font sizes and line heights for a system text
    /// size of `fontScale`.
    func fontMultiplier(for fontScale: CGFloat) -> CGFloat {
        guard allowFontScaling else { return 1 }
        if let limit = maxFontSizeMultiplier, limit >= 1 {
            return min(fontScale, limit)
        }
        return fontScale
    }

    /// Flattens the spans depth-first. Children inherit every attribute of
    /// their span; transforms apply per span, so a run's range is measured
    /// on the transformed text.
    func attributedText(fontScale: CGFloat, isDark: Bool) -> AttributedText {
        let multiplier = fontMultiplier(for: fontScale)
        var string = ""
        var runs: [AttributedText.Run] = []
        var offset = 0
        var linkCount = 0
        var lineHeight = style.lineHeight

        func visit(_ span: TextSpan, inherited: TextStyle, link: Int?) {
            let style = inherited.merging(span.style)
            if let spanLineHeight = span.style.lineHeight {
                lineHeight = max(lineHeight ?? 0, spanLineHeight)
            }
            var link = link
            if span.isLink {
                link = linkCount
                linkCount += 1
            }
            if !span.text.isEmpty {
                let text = (style.textTransform ?? .none).apply(to: span.text)
                let length = text.utf16.count
                let resolved = style.resolved(multiplier: multiplier, isDark: isDark)
                if let last = runs.last, last.style == resolved, last.link == link, last.range.upperBound == offset {
                    runs[runs.count - 1].range = last.range.lowerBound..<(offset + length)
                } else {
                    runs.append(.init(range: offset..<(offset + length), style: resolved, link: link))
                }
                string += text
                offset += length
            }
            for child in span.children {
                visit(child, inherited: style, link: link)
            }
        }

        for span in spans {
            visit(span, inherited: style, link: nil)
        }

        var paragraph = AttributedText.Paragraph()
        paragraph.alignment = style.textAlign ?? .auto
        paragraph.lineHeight = lineHeight.map { $0 * multiplier }
        paragraph.numberOfLines = max(0, numberOfLines)
        paragraph.ellipsizeMode = ellipsizeMode
        return AttributedText(string: string, runs: runs, paragraph: paragraph, linkCount: linkCount)
    }

    /// The pressable spans in the order their indices were given.
    var links: [TextSpan] {
        var links: [TextSpan] = []
        func visit(_ span: TextSpan) {
            if span.isLink {
                links.append(span)
            }
            span.children.forEach(visit)
        }
        spans.forEach(visit)
        return links
    }

    var plainText: String {
        var text = ""
        func visit(_ span: TextSpan) {
            text += span.text
            span.children.forEach(visit)
        }
        spans.forEach(visit)
        return text
    }
}

extension TextStyle {
    /// `self` with every field `other` sets replaced.
    func merging(_ other: TextStyle) -> TextStyle {
        TextStyle(
            color: other.color ?? color,
            fontSize: other.fontSize ?? fontSize,
            fontWeight: other.fontWeight ?? fontWeight,
            fontStyle: other.fontStyle ?? fontStyle,
            fontFamily: other.fontFamily ?? fontFamily,
            lineHeight: other.lineHeight ?? lineHeight,
            letterSpacing: other.letterSpacing ?? letterSpacing,
            textAlign: other.textAlign ?? textAlign,
            textDecorationLine: other.textDecorationLine ?? textDecorationLine,
            textDecorationColor: other.textDecorationColor ?? textDecorationColor,
            textDecorationStyle: other.textDecorationStyle ?? textDecorationStyle,
            textTransform: other.textTransform ?? textTransform,
            backgroundColor: other.backgroundColor ?? backgroundColor
        )
    }

    func resolved(multiplier: CGFloat, isDark: Bool) -> ResolvedTextStyle {
        let defaults = TextContent.defaultStyle
        return ResolvedTextStyle(
            color: color?.resolved(dark: isDark) ?? defaults.color,
            fontSize: (fontSize ?? defaults.fontSize) * multiplier,
            fontWeight: fontWeight ?? defaults.fontWeight,
            isItalic: fontStyle == .italic,
            fontFamily: fontFamily,
            letterSpacing: letterSpacing ?? defaults.letterSpacing,
            decorationLine: textDecorationLine ?? defaults.decorationLine,
            decorationColor: textDecorationColor?.resolved(dark: isDark),
            decorationStyle: textDecorationStyle ?? defaults.decorationStyle,
            backgroundColor: backgroundColor?.resolved(dark: isDark)
        )
    }
}
