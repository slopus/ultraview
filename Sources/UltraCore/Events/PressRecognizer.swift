import Foundation

/// The press state machine behind `onPress`, `onLongPress`, `onPressIn` and
/// `onPressOut`. Touch handling feeds it events and performs what it returns.
///
/// - A touch down is a press-in.
/// - Moving out of the retention area is a press-out; moving back in is a
///   press-in again.
/// - Lifting the touch inside ends with a press-out, then a press, unless a
///   long press already fired and the node handles long presses.
/// - The long-press timer fires a long press if the touch is still inside.
public struct PressRecognizer: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        case pressIn
        case pressOut
        case press
        case longPress
    }

    public enum Phase: Sendable, Equatable {
        case idle
        case pressedInside
        case pressedOutside
    }

    /// How long a touch must stay down for a long press.
    public static let longPressDelay: TimeInterval = 0.5
    /// How far a touch may move beyond the bounds (plus hit slop) and still
    /// count as inside.
    public static let retentionOffset: CGFloat = 20

    public private(set) var phase: Phase = .idle
    public private(set) var didLongPress = false
    public var handlesLongPress: Bool

    public init(handlesLongPress: Bool) {
        self.handlesLongPress = handlesLongPress
    }

    public mutating func touchBegan() -> [Event] {
        phase = .pressedInside
        didLongPress = false
        return [.pressIn]
    }

    public mutating func touchMoved(inside: Bool) -> [Event] {
        switch (phase, inside) {
        case (.pressedInside, false):
            phase = .pressedOutside
            return [.pressOut]
        case (.pressedOutside, true):
            phase = .pressedInside
            return [.pressIn]
        default:
            return []
        }
    }

    public mutating func touchEnded(inside: Bool) -> [Event] {
        defer { phase = .idle }
        guard phase == .pressedInside else { return [] }
        guard inside else { return [.pressOut] }
        return didLongPress && handlesLongPress ? [.pressOut] : [.pressOut, .press]
    }

    public mutating func touchCancelled() -> [Event] {
        defer { phase = .idle }
        return phase == .pressedInside ? [.pressOut] : []
    }

    public mutating func longPressTimerFired() -> [Event] {
        guard phase == .pressedInside, handlesLongPress, !didLongPress else { return [] }
        didLongPress = true
        return [.longPress]
    }
}
