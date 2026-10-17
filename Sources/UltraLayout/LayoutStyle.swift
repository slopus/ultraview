import Foundation

/// The flexbox properties of one layout node. A plain value: build it on any
/// thread and hand it to a `LayoutNode`.
///
/// The defaults are Yoga's: column direction, `flexShrink` 0, `alignContent`
/// flex-start, relative positioning. Optional values left `nil` are
/// undefined, so Yoga applies its own rule for them.
public struct LayoutStyle: Sendable, Equatable {
    public var direction: Direction = .inherit
    public var flexDirection: FlexDirection = .column
    public var justifyContent: Justify = .flexStart
    public var alignItems: Align = .stretch
    public var alignSelf: Align = .auto
    public var alignContent: Align = .flexStart
    public var flexWrap: Wrap = .noWrap
    /// Relative nodes take part in flex layout; absolute ones are placed by
    /// their insets (`top`, `left`, ...) inside the parent's padding box.
    public var position: PositionType = .relative
    public var display: Display = .flex
    public var overflow: Overflow = .visible
    public var boxSizing: BoxSizing = .borderBox

    /// Shorthand: a positive value grows (and, unlike the web, never sets a
    /// basis); a negative one shrinks down to the minimum size.
    public var flex: CGFloat?
    public var flexGrow: CGFloat?
    public var flexShrink: CGFloat?
    public var flexBasis: Dimension = .auto

    public var width: Dimension = .auto
    public var height: Dimension = .auto
    /// `.auto` means no limit for the four bounds below.
    public var minWidth: Dimension = .auto
    public var minHeight: Dimension = .auto
    public var maxWidth: Dimension = .auto
    public var maxHeight: Dimension = .auto
    /// Width divided by height.
    public var aspectRatio: CGFloat?

    /// Position offsets. `LayoutStyle+Edges.swift` adds `top`, `left`, ...
    public var insets = Edges<Dimension>()
    public var margins = Edges<Dimension>()
    public var paddings = Edges<Dimension>()
    /// Border widths take space in layout like padding does.
    public var borderWidths = Edges<CGFloat>()

    /// Space between children along both axes; `rowGap` and `columnGap`
    /// override it per axis.
    public var gap: CGFloat?
    public var rowGap: CGFloat?
    public var columnGap: CGFloat?

    public init() {}

    public enum Direction: Sendable, Equatable, CaseIterable {
        case inherit
        case leftToRight
        case rightToLeft
    }

    public enum FlexDirection: Sendable, Equatable, CaseIterable {
        case column
        case columnReverse
        case row
        case rowReverse
    }

    public enum Justify: Sendable, Equatable, CaseIterable {
        case flexStart
        case center
        case flexEnd
        case spaceBetween
        case spaceAround
        case spaceEvenly
    }

    /// Used by `alignItems`, `alignSelf` and `alignContent`. The three
    /// `space*` values only mean something for `alignContent`.
    public enum Align: Sendable, Equatable, CaseIterable {
        case auto
        case flexStart
        case center
        case flexEnd
        case stretch
        case baseline
        case spaceBetween
        case spaceAround
        case spaceEvenly
    }

    public enum Wrap: Sendable, Equatable, CaseIterable {
        case noWrap
        case wrap
        case wrapReverse
    }

    public enum PositionType: Sendable, Equatable, CaseIterable {
        case `static`
        case relative
        case absolute
    }

    public enum Display: Sendable, Equatable, CaseIterable {
        case flex
        /// The node and its subtree take no space and get zero frames.
        case none
        case contents
    }

    public enum Overflow: Sendable, Equatable, CaseIterable {
        case visible
        case hidden
        /// Children are measured without a limit along the main axis, which
        /// is what a scrolling container needs.
        case scroll
    }

    public enum BoxSizing: Sendable, Equatable, CaseIterable {
        case borderBox
        case contentBox
    }
}

/// A length: automatic, in points, or a percentage of the parent.
/// Integer and float literals are points: `style.width = 120`.
public enum Dimension: Sendable, Equatable, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
    case auto
    case points(CGFloat)
    /// Percent of the parent's size, 0...100.
    case percent(CGFloat)

    public init(integerLiteral value: Int) {
        self = .points(CGFloat(value))
    }

    public init(floatLiteral value: Double) {
        self = .points(CGFloat(value))
    }
}

/// One value per edge. Like Yoga's own edges, more specific edges win:
/// `top` over `vertical` over `all`, and `start`/`end` over `left`/`right`
/// (resolved with the layout direction).
public struct Edges<Value: Sendable & Equatable>: Sendable, Equatable {
    public var all: Value?
    public var horizontal: Value?
    public var vertical: Value?
    public var top: Value?
    public var left: Value?
    public var bottom: Value?
    public var right: Value?
    public var start: Value?
    public var end: Value?

    public init(
        all: Value? = nil,
        horizontal: Value? = nil,
        vertical: Value? = nil,
        top: Value? = nil,
        left: Value? = nil,
        bottom: Value? = nil,
        right: Value? = nil,
        start: Value? = nil,
        end: Value? = nil
    ) {
        self.all = all
        self.horizontal = horizontal
        self.vertical = vertical
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
        self.start = start
        self.end = end
    }
}

/// Four physical insets, for resolved layout values, hit slop and content
/// insets.
public struct Insets: Sendable, Equatable, Hashable {
    public var top: CGFloat
    public var left: CGFloat
    public var bottom: CGFloat
    public var right: CGFloat

    public init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public init(all value: CGFloat) {
        self.init(top: value, left: value, bottom: value, right: value)
    }

    public static let zero = Insets()
}
