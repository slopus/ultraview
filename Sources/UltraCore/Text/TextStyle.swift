import Foundation
import UltraLayout

/// Text attributes. Every field is optional: a span inherits what it leaves
/// unset from the span around it, and the outermost text from the defaults
/// (black, 14 points, regular weight).
public struct TextStyle: Sendable, Equatable {
    public var color: Color?
    public var fontSize: CGFloat?
    public var fontWeight: FontWeight?
    public var fontStyle: FontStyle?
    /// A family name ("Avenir Next") or PostScript name; `nil` is the system
    /// font.
    public var fontFamily: String?
    /// The height of every line box, in points. With several spans setting
    /// it, the tallest wins.
    public var lineHeight: CGFloat?
    /// Extra space after each character, in points.
    public var letterSpacing: CGFloat?
    /// Paragraph alignment. Only the outermost style's value is used.
    public var textAlign: TextAlign?
    public var textDecorationLine: TextDecorationLine?
    public var textDecorationColor: Color?
    public var textDecorationStyle: TextDecorationStyle?
    public var textTransform: TextTransform?
    /// Highlights the span's glyphs; unlike the node's own background, it
    /// covers only the characters.
    public var backgroundColor: Color?

    public init(
        color: Color? = nil,
        fontSize: CGFloat? = nil,
        fontWeight: FontWeight? = nil,
        fontStyle: FontStyle? = nil,
        fontFamily: String? = nil,
        lineHeight: CGFloat? = nil,
        letterSpacing: CGFloat? = nil,
        textAlign: TextAlign? = nil,
        textDecorationLine: TextDecorationLine? = nil,
        textDecorationColor: Color? = nil,
        textDecorationStyle: TextDecorationStyle? = nil,
        textTransform: TextTransform? = nil,
        backgroundColor: Color? = nil
    ) {
        self.color = color
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.fontStyle = fontStyle
        self.fontFamily = fontFamily
        self.lineHeight = lineHeight
        self.letterSpacing = letterSpacing
        self.textAlign = textAlign
        self.textDecorationLine = textDecorationLine
        self.textDecorationColor = textDecorationColor
        self.textDecorationStyle = textDecorationStyle
        self.textTransform = textTransform
        self.backgroundColor = backgroundColor
    }
}

public enum FontWeight: Int, Sendable, Hashable, CaseIterable {
    case ultraLight = 100
    case thin = 200
    case light = 300
    case regular = 400
    case medium = 500
    case semibold = 600
    case bold = 700
    case heavy = 800
    case black = 900
}

public enum FontStyle: Sendable, Hashable {
    case normal
    case italic
}

public enum TextAlign: Sendable, Hashable {
    /// Left for left-to-right text, right for right-to-left text, decided by
    /// the text's first strong character.
    case auto
    case left
    case right
    case center
    /// Stretches every line but the last of each paragraph to the full width.
    case justify
}

public enum TextDecorationLine: Sendable, Hashable {
    case none
    case underline
    case lineThrough
    case underlineLineThrough

    var hasUnderline: Bool { self == .underline || self == .underlineLineThrough }
    var hasLineThrough: Bool { self == .lineThrough || self == .underlineLineThrough }
}

public enum TextDecorationStyle: Sendable, Hashable {
    case solid
    case double
    case dotted
    case dashed
}

public enum TextTransform: Sendable, Hashable {
    case none
    case uppercase
    case lowercase
    case capitalize

    func apply(to text: String) -> String {
        switch self {
        case .none: text
        case .uppercase: text.uppercased()
        case .lowercase: text.lowercased()
        case .capitalize: text.capitalized
        }
    }
}

/// How text that doesn't fit in `numberOfLines` is cut.
public enum EllipsizeMode: Sendable, Hashable {
    /// "…end of the text"
    case head
    /// "Start of…the text"
    case middle
    /// "Start of the te…"
    case tail
    /// Cut off at the edge, no ellipsis.
    case clip
}

/// A piece of text with its own style, nested like markup: children inherit
/// the span's style and add their own. A span with a press handler is a
/// link: it highlights while pressed and calls the handler on release.
public struct TextSpan: Sendable {
    public var text: String
    public var style: TextStyle
    public var children: [TextSpan]
    public var onPress: PressHandler?
    public var onLongPress: PressHandler?

    public init(
        _ text: String = "",
        style: TextStyle = TextStyle(),
        onPress: PressHandler? = nil,
        onLongPress: PressHandler? = nil,
        children: [TextSpan] = []
    ) {
        self.text = text
        self.style = style
        self.children = children
        self.onPress = onPress
        self.onLongPress = onLongPress
    }

    var isLink: Bool { onPress != nil || onLongPress != nil }
}

/// Text attributes with nothing left to inherit, for one run of characters.
public struct ResolvedTextStyle: Sendable, Hashable {
    public var color: Color.Components
    /// After Dynamic Type scaling.
    public var fontSize: CGFloat
    public var fontWeight: FontWeight
    public var isItalic: Bool
    public var fontFamily: String?
    public var letterSpacing: CGFloat
    public var decorationLine: TextDecorationLine
    public var decorationColor: Color.Components?
    public var decorationStyle: TextDecorationStyle
    public var backgroundColor: Color.Components?
}
