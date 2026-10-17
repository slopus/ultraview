import Foundation
import Synchronization
import UltraLayout
#if canImport(UIKit)
import UIKit
#endif

/// A box in a flexbox layout, with a background, borders, a shadow, press
/// handling and children: the counterpart of a `View` in a declarative UI.
///
/// Create, configure and change nodes from any thread. A change only records
/// the new value and schedules a pass; the pass measures, lays out and draws
/// on background queues and hands the main thread a finished commit. Views
/// exist only for nodes that are on screen or close to it, and are created
/// by the main thread when it applies a commit.
///
/// To show a tree, give its root to a `NodeHostView`.
open class UltraNode: @unchecked Sendable {
    // @unchecked Sendable: the node's own properties live in `state`, a
    // Mutex, and the flags below are atomics. `shadow` is touched only on the
    // pipeline's layout queue, and the main-actor properties only on the
    // main thread.

    let state: Mutex<NodeState>
    /// This node's properties changed since the last pass synced them.
    let needsSync = Atomic<Bool>(true)
    /// Some descendant's properties changed since the last pass.
    let descendantsNeedSync = Atomic<Bool>(false)
    /// Bumped when the node's bitmap goes out of date; drawing in flight for
    /// an older value is thrown away.
    let displaySentinel = Atomic<UInt64>(0)
    private let publishedState = Atomic<UInt8>(0)
    let shadow = Shadow()

    #if canImport(UIKit)
    /// The node's view while it is mounted. Main thread only.
    @MainActor var mountedView: UIView?
    /// The children whose views are in `mountedView`, in order.
    @MainActor var mountedChildren: [UltraNode] = []
    /// The properties last applied to `mountedView`.
    @MainActor var appliedProps: ViewProps?
    /// The bitmap last applied to `mountedView`.
    @MainActor var appliedContents: Contents?
    #endif

    public init(style: Style = Style(), children: [UltraNode] = []) {
        state = Mutex(NodeState(style: style))
        if !children.isEmpty {
            setChildren(children)
        }
    }

    // MARK: Properties

    public var style: Style {
        get { state.withLock { $0.style } }
        set {
            let (changed, redraw) = state.withLock { state -> (Bool, Bool) in
                guard state.style != newValue else { return (false, false) }
                let redraw = state.style.boxDiffers(from: newValue)
                state.style = newValue
                return (true, redraw)
            }
            if changed {
                setNeedsSync(redraw: redraw)
            }
        }
    }

    /// Changes the style in place: `node.updateStyle { $0.opacity = 0.5 }`.
    public func updateStyle(_ body: (inout Style) -> Void) {
        var style = self.style
        body(&style)
        self.style = style
    }

    /// Called when a touch that started on the node ends on it.
    public var onPress: PressHandler? {
        get { state.withLock { $0.handlers.onPress } }
        set { setHandler(\.onPress, newValue) }
    }

    /// Called when a touch stays down on the node for half a second. A
    /// press that turned into a long press doesn't also call `onPress`.
    public var onLongPress: PressHandler? {
        get { state.withLock { $0.handlers.onLongPress } }
        set { setHandler(\.onLongPress, newValue) }
    }

    /// Called when a touch goes down on the node, or comes back over it.
    public var onPressIn: PressHandler? {
        get { state.withLock { $0.handlers.onPressIn } }
        set { setHandler(\.onPressIn, newValue) }
    }

    /// Called when a press ends, is cancelled, or moves off the node.
    public var onPressOut: PressHandler? {
        get { state.withLock { $0.handlers.onPressOut } }
        set { setHandler(\.onPressOut, newValue) }
    }

    /// The view's opacity while pressed, for press feedback. `nil` leaves
    /// the opacity alone.
    public var pressedOpacity: CGFloat? {
        get { state.withLock { $0.pressedOpacity } }
        set { update(\.pressedOpacity, newValue) }
    }

    public var accessibility: Accessibility {
        get { state.withLock { $0.accessibility } }
        set { update(\.accessibility, newValue) }
    }

    /// Custom content, drawn into the node's bitmap off the main thread
    /// above its background. Setting it, even to an equal value, redraws.
    public var drawing: (any Drawing)? {
        get { state.withLock { $0.drawing } }
        set {
            state.withLock { state in
                state.drawing = newValue
                state.drawingVersion += 1
            }
            setNeedsSync(redraw: true)
        }
    }

    /// Matches this node with its counterpart in another revision of the
    /// tree, so a layout transition animates it from where that one was
    /// (see `NodeHostView.animateTransition(from:timing:)`). Unique within
    /// a tree; the roots match without one.
    public var transitionKey: String? {
        get { state.withLock { $0.transitionKey } }
        set { update(\.transitionKey, newValue) }
    }

    /// A name for debugging.
    public var debugName: String? {
        get { state.withLock { $0.debugName } }
        set { state.withLock { $0.debugName = newValue } }
    }

    /// How close the node is to the screen, as of the last pass.
    public var interfaceState: InterfaceState {
        InterfaceState(rawValue: publishedState.load(ordering: .relaxed))
    }

    func publish(_ interfaceState: InterfaceState) {
        publishedState.store(interfaceState.rawValue, ordering: .relaxed)
    }

    private func setHandler(_ keyPath: WritableKeyPath<PressHandlers, PressHandler?>, _ handler: PressHandler?) {
        let pressabilityChanged = state.withLock { state -> Bool in
            let wasEmpty = state.handlers.isEmpty
            state.handlers[keyPath: keyPath] = handler
            return wasEmpty != state.handlers.isEmpty
        }
        if pressabilityChanged {
            setNeedsSync()
        }
    }

    private func update<Value: Equatable & Sendable>(_ keyPath: WritableKeyPath<NodeState, Value>, _ value: Value) {
        let changed = state.withLock { state -> Bool in
            guard state[keyPath: keyPath] != value else { return false }
            state[keyPath: keyPath] = value
            return true
        }
        if changed {
            setNeedsSync()
        }
    }

    // MARK: Children

    public var children: [UltraNode] {
        state.withLock { $0.children }
    }

    public var parent: UltraNode? {
        state.withLock { $0.parent }
    }

    public func addChild(_ child: UltraNode) {
        insertChild(child, at: .max)
    }

    /// Inserts `child` at `index` (clamped), moving it from its old parent.
    public func insertChild(_ child: UltraNode, at index: Int) {
        insertChildNode(child, at: index)
    }

    public func removeChild(_ child: UltraNode) {
        removeChildNode(child)
    }

    /// Replaces all children at once: one change, one pass.
    public func setChildren(_ children: [UltraNode]) {
        setChildNodes(children)
    }

    public func removeFromParent() {
        parent?.removeChildNode(self)
    }

    /// Whether the node may have children. Text can't.
    var acceptsChildren: Bool { true }

    final func insertChildNode(_ child: UltraNode, at index: Int) {
        precondition(child !== self, "a node can't be its own child")
        precondition(acceptsChildren, "\(type(of: self)) can't have children")
        let oldParent = HierarchyLock.shared.withLock { () -> UltraNode? in
            precondition(!isDescendant(of: child), "a node can't be a child of its own descendant")
            let oldParent = child.state.withLock { state -> UltraNode? in
                let oldParent = state.parent
                state.parent = self
                return oldParent
            }
            oldParent?.state.withLock { $0.children.removeAll { $0 === child } }
            state.withLock { state in
                state.children.insert(child, at: min(max(index, 0), state.children.count))
            }
            return oldParent
        }
        if let oldParent, oldParent !== self {
            oldParent.setNeedsSync()
        }
        child.needsSync.store(true, ordering: .sequentiallyConsistent)
        setNeedsSync()
    }

    final func removeChildNode(_ child: UltraNode) {
        let removed = HierarchyLock.shared.withLock { () -> Bool in
            guard child.state.withLock({ $0.parent }) === self else { return false }
            state.withLock { $0.children.removeAll { $0 === child } }
            child.state.withLock { $0.parent = nil }
            return true
        }
        if removed {
            child.cancelDisplayInSubtree()
            setNeedsSync()
        }
    }

    final func setChildNodes(_ children: [UltraNode]) {
        precondition(acceptsChildren || children.isEmpty, "\(type(of: self)) can't have children")
        let (removed, otherParents) = HierarchyLock.shared.withLock { () -> ([UltraNode], [UltraNode]) in
            let kept = Set(children.map(ObjectIdentifier.init))
            let old = state.withLock { $0.children }
            let removed = old.filter { !kept.contains(ObjectIdentifier($0)) }
            for child in removed {
                child.state.withLock { $0.parent = nil }
            }
            var otherParents: [UltraNode] = []
            for child in children {
                precondition(child !== self && !isDescendant(of: child), "a node can't be a child of itself or its descendant")
                let oldParent = child.state.withLock { state -> UltraNode? in
                    let oldParent = state.parent
                    state.parent = self
                    return oldParent
                }
                if let oldParent, oldParent !== self {
                    oldParent.state.withLock { $0.children.removeAll { $0 === child } }
                    otherParents.append(oldParent)
                }
            }
            state.withLock { $0.children = children }
            return (removed, otherParents)
        }
        for child in removed {
            child.cancelDisplayInSubtree()
        }
        for parent in otherParents {
            parent.setNeedsSync()
        }
        for child in children {
            child.needsSync.store(true, ordering: .sequentiallyConsistent)
        }
        setNeedsSync()
    }

    private func isDescendant(of node: UltraNode) -> Bool {
        var current = state.withLock { $0.parent }
        while let ancestor = current {
            if ancestor === node {
                return true
            }
            current = ancestor.state.withLock { $0.parent }
        }
        return false
    }

    /// Throws away drawing in flight for a subtree that is leaving.
    private func cancelDisplayInSubtree() {
        displaySentinel.add(1, ordering: .relaxed)
        for child in children {
            child.cancelDisplayInSubtree()
        }
    }

    // MARK: Scheduling

    /// Records that this node changed and makes sure a pass will see it:
    /// marks the path to the root and, at a hosted root, schedules a pass.
    /// A walk stops early at an ancestor already marked, because a pass is
    /// then already due to visit it.
    final func setNeedsSync(redraw: Bool = false) {
        if redraw {
            displaySentinel.add(1, ordering: .relaxed)
        }
        needsSync.store(true, ordering: .sequentiallyConsistent)
        var node = self
        while true {
            let (parent, renderer) = node.state.withLock { ($0.parent, $0.renderer) }
            guard let parent else {
                renderer?.setNeedsPass()
                return
            }
            if parent.descendantsNeedSync.exchange(true, ordering: .sequentiallyConsistent) {
                return
            }
            node = parent
        }
    }

    // MARK: Pipeline hooks (layout queue)

    /// The flexbox style Yoga gets; subclasses adjust it.
    func effectiveLayoutStyle(_ state: NodeState) -> LayoutStyle {
        state.style.layout
    }

    /// Syncs subclass content from a new snapshot. Called on the layout
    /// queue whenever the node's state is synced.
    func syncContent(previous: NodeState?, current: NodeState, pass: Pass) {}

    /// Brings content that depends on the frame up to date (text picks the
    /// layout for its width). Called on the layout queue before building
    /// props and drawings.
    func updateContentForFrame(pass: Pass) {}

    /// Adds subclass-specific view properties.
    func contributeProps(_ props: inout ViewProps, state: NodeState, pass: Pass) {}

    /// What the node draws above its box, if anything.
    func contentDrawing(state: NodeState) -> (drawing: any Drawing, key: DrawingKey.Content)? {
        guard let drawing = state.drawing else { return nil }
        return (drawing, .custom(state.drawingVersion))
    }

    // MARK: Views (main thread)

    #if canImport(UIKit)
    /// The node's view while it is mounted.
    @MainActor public var view: UIView? { mountedView }

    /// Creates the node's view. Called on the main thread when the node is
    /// mounted.
    @MainActor func makeView() -> UIView {
        NodeView(node: self)
    }

    /// Called after an entry for this node was applied.
    @MainActor func didApply(_ entry: CommitEntry) {}
    #endif
}

extension UltraNode: CustomStringConvertible {
    public var description: String {
        let name = debugName.map { " \"\($0)\"" } ?? ""
        return "<\(type(of: self))\(name) \(ObjectIdentifier(self))>"
    }
}
