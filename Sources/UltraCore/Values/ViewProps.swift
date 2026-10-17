import Foundation
import UltraLayout

/// Everything the main thread sets on a node's view, resolved off the main
/// thread from the node's style: colors for the current appearance, radii
/// clamped to the frame, borders per side reduced to what a layer can show.
/// Applying it only assigns properties.
public struct ViewProps: Sendable, Equatable {
    /// `nil` when the background is drawn into the contents bitmap instead.
    public var backgroundColor: Color.Components?
    public var cornerRadius: CGFloat = 0
    public var maskedCorners: CornerMask = .all
    public var borderWidth: CGFloat = 0
    public var borderColor: Color.Components?
    public var opacity: CGFloat = 1
    public var transform: Transform3D = .identity
    public var clipsToBounds = false
    public var shadow: ShadowProps?
    public var isHidden = false
    public var pointerEvents: PointerEvents = .auto
    public var hitSlop: Insets = .zero
    /// Whether the node has press handlers and handles its own touches.
    public var isPressable = false
    /// The view's opacity while pressed.
    public var pressedOpacity: CGFloat?
    public var accessibility = AccessibilityProps()
    public var text: TextViewProps?
    public var scroll: ScrollViewProps?

    public init() {}
}

public struct CornerMask: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let topLeft = CornerMask(rawValue: 1 << 0)
    public static let topRight = CornerMask(rawValue: 1 << 1)
    public static let bottomLeft = CornerMask(rawValue: 1 << 2)
    public static let bottomRight = CornerMask(rawValue: 1 << 3)
    public static let all: CornerMask = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}

public struct ShadowProps: Sendable, Equatable {
    public var color: Color.Components
    public var opacity: CGFloat
    public var offset: CGSize
    public var radius: CGFloat
    /// A rounded rect the shadow follows, when the node has an opaque box.
    /// Without it the shadow follows the layer's contents, which is slower.
    public var path: RoundedRect?
}

public struct RoundedRect: Sendable, Equatable {
    public var rect: CGRect
    public var cornerRadius: CGFloat
}

public struct AccessibilityProps: Sendable, Equatable {
    public var isElement = false
    public var label: String?
    public var hint: String?
    public var role: AccessibilityRole?
    public var hidden = false
}

/// Text-specific view state: where the pressable spans are, in the view's
/// coordinates.
public struct TextViewProps: Sendable, Equatable {
    /// Identifies the text these regions belong to; a tap is ignored when the
    /// node's text has changed since.
    public var version: UInt64
    public var links: [TextLinkRegion]
    /// Draw a highlight over a pressed span.
    public var highlightsPress: Bool
}

public struct TextLinkRegion: Sendable, Equatable {
    /// Index into the node's pressable spans, in document order.
    public var index: Int
    public var rects: [CGRect]
}

public struct ScrollViewProps: Sendable, Equatable {
    public var contentSize: CGSize
    public var contentInset: Insets
    public var horizontal: Bool
    public var showsVerticalScrollIndicator: Bool
    public var showsHorizontalScrollIndicator: Bool
    public var pagingEnabled: Bool
    public var bounces: Bool
    public var scrollEnabled: Bool
    public var keyboardDismissMode: KeyboardDismissMode
}

public enum KeyboardDismissMode: Sendable, Equatable {
    case none
    case onDrag
    case interactive
}
