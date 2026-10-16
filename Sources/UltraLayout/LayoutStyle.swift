import Foundation

/// The flexbox properties of one layout node. A plain value: build it on any
/// thread and hand it to a `LayoutNode`.
public struct LayoutStyle: Sendable, Equatable {
    public var direction: Direction = .inherit
    public var flexDirection: FlexDirection = .column
    public var justifyContent: Justify = .flexStart
    public var alignItems: Align = .stretch
    public var alignSelf: Align = .auto
    public var flexGrow: CGFloat = 0
    public var flexShrink: CGFloat = 0
    public var width: Dimension = .auto
    public var height: Dimension = .auto
    public var padding: LayoutInsets = .zero
    public var margin: LayoutInsets = .zero
    /// Space between adjacent children, along both axes.
    public var gap: CGFloat = 0

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

    public enum Align: Sendable, Equatable, CaseIterable {
        case auto
        case flexStart
        case center
        case flexEnd
        case stretch
        case baseline
    }

    public enum Dimension: Sendable, Equatable {
        case auto
        case points(CGFloat)
        /// Percent of the parent's size, 0...100.
        case percent(CGFloat)
    }
}

public struct LayoutInsets: Sendable, Equatable {
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

    public static let zero = LayoutInsets()
}
