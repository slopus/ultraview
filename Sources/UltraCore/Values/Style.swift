import Foundation
import UltraLayout

/// How a node looks and is laid out. A plain value: build it anywhere,
/// assign it to a node from any thread.
///
/// Every flexbox property of `LayoutStyle` is available directly:
///
/// ```swift
/// var style = Style()
/// style.flexDirection = .row
/// style.paddingHorizontal = 16
/// style.backgroundColor = .white
/// style.borderRadius = 12
/// ```
@dynamicMemberLookup
public struct Style: Sendable, Equatable {
    /// The flexbox part, handed to Yoga.
    public var layout = LayoutStyle()

    public var backgroundColor: Color?

    /// Border colors: `borderColor` for every side, the others per side.
    /// Widths live in the layout part (`borderWidth`, `borderTopWidth`, ...)
    /// because they take space. The default color is black.
    public var borderColor: Color?
    public var borderTopColor: Color?
    public var borderLeftColor: Color?
    public var borderBottomColor: Color?
    public var borderRightColor: Color?
    public var borderStartColor: Color?
    public var borderEndColor: Color?

    /// Corner radii: `borderRadius` for every corner, the others per corner.
    /// A radius is clamped to half the shorter side.
    public var borderRadius: CGFloat?
    public var borderTopLeftRadius: CGFloat?
    public var borderTopRightRadius: CGFloat?
    public var borderBottomLeftRadius: CGFloat?
    public var borderBottomRightRadius: CGFloat?

    public var opacity: CGFloat = 1
    /// Applied around the view's center; the last entry acts first.
    public var transform: [Transform] = []

    /// The shadow shows when `shadowColor` is set and `shadowOpacity` > 0.
    public var shadowColor: Color?
    public var shadowOffset = CGSize.zero
    public var shadowOpacity: CGFloat = 0
    public var shadowRadius: CGFloat = 3

    /// Which views in this subtree can be the target of touches.
    public var pointerEvents: PointerEvents = .auto
    /// Extends the touchable area beyond the bounds, per side.
    public var hitSlop: Insets = .zero

    public init() {}

    public subscript<Value>(dynamicMember keyPath: WritableKeyPath<LayoutStyle, Value>) -> Value {
        get { layout[keyPath: keyPath] }
        set { layout[keyPath: keyPath] = newValue }
    }

    /// Whether going from `self` to `other` changes what a bitmap of the
    /// node's box (background, borders, corners) would show.
    func boxDiffers(from other: Style) -> Bool {
        backgroundColor != other.backgroundColor
            || borderColor != other.borderColor
            || borderTopColor != other.borderTopColor
            || borderLeftColor != other.borderLeftColor
            || borderBottomColor != other.borderBottomColor
            || borderRightColor != other.borderRightColor
            || borderStartColor != other.borderStartColor
            || borderEndColor != other.borderEndColor
            || borderRadius != other.borderRadius
            || borderTopLeftRadius != other.borderTopLeftRadius
            || borderTopRightRadius != other.borderTopRightRadius
            || borderBottomLeftRadius != other.borderBottomLeftRadius
            || borderBottomRightRadius != other.borderBottomRightRadius
            || layout.borderWidths != other.layout.borderWidths
    }
}

/// Which views in a subtree receive touches.
public enum PointerEvents: Sendable, Equatable {
    /// The node and its children.
    case auto
    /// Neither the node nor its children.
    case none
    /// Only the children, never the node itself.
    case boxNone
    /// Only the node, never its children.
    case boxOnly
}

/// What assistive technologies are told about a node.
public struct Accessibility: Sendable, Equatable {
    public var label: String?
    public var hint: String?
    public var role: AccessibilityRole?
    /// Hides the node and its subtree.
    public var hidden = false
    /// Makes the node one element even without a label or role.
    public var isElement: Bool?

    public init(
        label: String? = nil,
        hint: String? = nil,
        role: AccessibilityRole? = nil,
        hidden: Bool = false,
        isElement: Bool? = nil
    ) {
        self.label = label
        self.hint = hint
        self.role = role
        self.hidden = hidden
        self.isElement = isElement
    }
}

public enum AccessibilityRole: Sendable, Equatable {
    case none
    case button
    case link
    case header
    case image
    case text
    case search
    case adjustable
    case summary
    case tab
    case toggleButton
}
