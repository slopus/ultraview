import Foundation
import UltraLayout

/// How close a node is to being seen. Each state implies the ones before it.
///
/// - `preload`: the node has a view (it is mounted).
/// - `display`: the node's bitmap is drawn and kept.
/// - `visible`: some of the node is on screen.
///
/// Nodes outside a scroll node are all three while their host is in a
/// window, and none otherwise. Inside a scroll node, each child gets the
/// states its distance from the viewport allows (see `RangeTuning`).
public struct InterfaceState: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let preload = InterfaceState(rawValue: 1 << 0)
    public static let display = InterfaceState(rawValue: 1 << 1)
    public static let visible = InterfaceState(rawValue: 1 << 2)
    public static let all: InterfaceState = [.preload, .display, .visible]
}

/// How far ahead of the viewport a scroll node prepares its children, in
/// viewport lengths along the scroll axis, on each side.
public struct RangeTuning: Sendable, Equatable {
    /// Children within this distance keep a view.
    public var preloadScreens: CGFloat
    /// Children within this distance are drawn and keep their bitmaps.
    public var displayScreens: CGFloat

    public init(preloadScreens: CGFloat = 3, displayScreens: CGFloat = 1.5) {
        self.preloadScreens = max(preloadScreens, displayScreens)
        self.displayScreens = displayScreens
    }

    public static let `default` = RangeTuning()

    /// The state for a child at `frame`, given the visible part of the
    /// content. Only the scroll axis counts.
    public func state(for frame: CGRect, viewport: CGRect, horizontal: Bool) -> InterfaceState {
        let low = horizontal ? viewport.minX : viewport.minY
        let high = horizontal ? viewport.maxX : viewport.maxY
        let start = horizontal ? frame.minX : frame.minY
        let end = horizontal ? frame.maxX : frame.maxY
        let length = high - low

        func overlaps(extendedBy screens: CGFloat) -> Bool {
            let margin = length * screens
            return start < high + margin && end > low - margin
                || (start == end && start >= low - margin && start <= high + margin)
        }

        var state: InterfaceState = []
        if overlaps(extendedBy: preloadScreens) { state.insert(.preload) }
        if overlaps(extendedBy: displayScreens) { state.insert(.display) }
        if overlaps(extendedBy: 0) { state.insert(.visible) }
        return state
    }
}
