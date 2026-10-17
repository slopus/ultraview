import Foundation
import Synchronization
import UltraLayout

/// Called on the main thread when a press gesture reaches a stage.
public typealias PressHandler = @MainActor @Sendable () -> Void

/// A node's properties as set by its owner, from any thread. The pipeline
/// copies it under the node's lock at the start of a pass and works from the
/// copy.
struct NodeState: Sendable {
    var style: Style
    var children: [UltraNode] = []
    weak var parent: UltraNode?
    /// Set on a tree's root while a host shows it.
    weak var renderer: Renderer?
    var handlers = PressHandlers()
    var pressedOpacity: CGFloat?
    var accessibility = Accessibility()
    var drawing: (any Drawing)?
    var drawingVersion: UInt64 = 0
    var text: TextContent?
    var scroll: ScrollConfiguration?
    /// For a scroll node's content container: lay children out in a row.
    var isHorizontalContent = false
    var debugName: String?

    init(style: Style) {
        self.style = style
    }
}

struct PressHandlers: Sendable {
    var onPress: PressHandler?
    var onLongPress: PressHandler?
    var onPressIn: PressHandler?
    var onPressOut: PressHandler?

    var isEmpty: Bool {
        onPress == nil && onLongPress == nil && onPressIn == nil && onPressOut == nil
    }
}

/// Serializes changes to the tree's structure, so a node never ends up with
/// two parents when threads move it at the same time. Held only while
/// rewiring parent and children fields; node locks are taken inside it,
/// never the other way around.
final class HierarchyLock: Sendable {
    static let shared = HierarchyLock()
    private let mutex = Mutex<Void>(())

    func withLock<Result: Sendable>(_ body: () -> Result) -> Result {
        mutex.withLock { _ in body() }
    }
}
