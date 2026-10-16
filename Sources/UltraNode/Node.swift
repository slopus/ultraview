import Foundation
import Synchronization
import UltraLayout

/// Placeholder for the node: the unit that is measured, laid out and rendered
/// off the main thread, and only applied to UIKit on it.
///
/// For now it only owns a flexbox style and children, and computes frames.
/// Like `LayoutNode`, a tree belongs to one thread or task at a time; what
/// crosses threads is the `LayoutResult` it produces.
open class Node {
    /// Counts layout passes. Stands in for the locks and atomics node state
    /// will use, so the `Synchronization` module is linked from the start.
    private let layoutPasses = Atomic<Int>(0)
    private let layoutNode: LayoutNode
    public private(set) var children: [Node] = []

    public var style: LayoutStyle {
        get { layoutNode.style }
        set { layoutNode.style = newValue }
    }

    public init(style: LayoutStyle = LayoutStyle(), children: [Node] = []) {
        layoutNode = LayoutNode(style: style)
        for child in children {
            addChild(child)
        }
    }

    public func addChild(_ child: Node) {
        layoutNode.addChild(child.layoutNode)
        children.append(child)
    }

    /// Lays out this subtree in a box of the given size and returns the
    /// frames. Pure computation: call it off the main thread.
    public func layout(width: CGFloat?, height: CGFloat?) -> LayoutResult {
        layoutPasses.add(1, ordering: .relaxed)
        layoutNode.calculateLayout(width: width, height: height)
        return layoutNode.result
    }

    /// How many times `layout(width:height:)` ran on this node.
    public var layoutPassCount: Int {
        layoutPasses.load(ordering: .relaxed)
    }
}
