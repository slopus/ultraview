import Foundation
internal import yoga

/// One node of a flexbox tree, backed by a Yoga node.
///
/// Not `Sendable`: a tree belongs to one thread or task at a time. Build and
/// compute it off the main thread, then send the resulting `LayoutResult`
/// (a value) to the main thread to apply.
public final class LayoutNode {
    let yogaNode: YGNodeRef
    public private(set) var children: [LayoutNode] = []

    public var style: LayoutStyle {
        didSet {
            if style != oldValue {
                apply(style)
            }
        }
    }

    public init(style: LayoutStyle = LayoutStyle(), children: [LayoutNode] = []) {
        yogaNode = YGNodeNew()
        self.style = style
        apply(style)
        for child in children {
            addChild(child)
        }
    }

    deinit {
        // Children are released after this, and freeing a Yoga node that has
        // already been detached from its owner is fine.
        YGNodeFree(yogaNode)
    }

    /// Appends `child`. A node has at most one parent.
    public func addChild(_ child: LayoutNode) {
        precondition(YGNodeGetOwner(child.yogaNode) == nil, "LayoutNode already has a parent")
        YGNodeInsertChild(yogaNode, child.yogaNode, children.count)
        children.append(child)
    }

    public func removeAllChildren() {
        YGNodeRemoveAllChildren(yogaNode)
        children.removeAll()
    }

    /// Computes the layout of this subtree. `nil` leaves that axis unbounded.
    public func calculateLayout(
        width: CGFloat? = nil,
        height: CGFloat? = nil,
        direction: LayoutStyle.Direction = .leftToRight
    ) {
        YGNodeCalculateLayout(
            yogaNode,
            width.map(Float.init) ?? .nan,
            height.map(Float.init) ?? .nan,
            direction.yoga
        )
    }

    /// The frame from the last `calculateLayout`, relative to the parent.
    public var frame: CGRect {
        CGRect(
            x: CGFloat(YGNodeLayoutGetLeft(yogaNode)),
            y: CGFloat(YGNodeLayoutGetTop(yogaNode)),
            width: CGFloat(YGNodeLayoutGetWidth(yogaNode)),
            height: CGFloat(YGNodeLayoutGetHeight(yogaNode))
        )
    }

    /// The frames of this subtree from the last `calculateLayout`.
    public var result: LayoutResult {
        LayoutResult(frame: frame, children: children.map(\.result))
    }

    private func apply(_ style: LayoutStyle) {
        let node = yogaNode
        YGNodeStyleSetDirection(node, style.direction.yoga)
        YGNodeStyleSetFlexDirection(node, style.flexDirection.yoga)
        YGNodeStyleSetJustifyContent(node, style.justifyContent.yoga)
        YGNodeStyleSetAlignItems(node, style.alignItems.yoga)
        YGNodeStyleSetAlignSelf(node, style.alignSelf.yoga)
        YGNodeStyleSetFlexGrow(node, Float(style.flexGrow))
        YGNodeStyleSetFlexShrink(node, Float(style.flexShrink))

        switch style.width {
        case .auto: YGNodeStyleSetWidthAuto(node)
        case .points(let value): YGNodeStyleSetWidth(node, Float(value))
        case .percent(let value): YGNodeStyleSetWidthPercent(node, Float(value))
        }
        switch style.height {
        case .auto: YGNodeStyleSetHeightAuto(node)
        case .points(let value): YGNodeStyleSetHeight(node, Float(value))
        case .percent(let value): YGNodeStyleSetHeightPercent(node, Float(value))
        }

        for (edge, value) in style.padding.yogaEdges {
            YGNodeStyleSetPadding(node, edge, Float(value))
        }
        for (edge, value) in style.margin.yogaEdges {
            YGNodeStyleSetMargin(node, edge, Float(value))
        }
        YGNodeStyleSetGap(node, Yoga.gutterAll, Float(style.gap))
    }
}

/// The frames of a computed layout tree: a value, safe to send between
/// threads. `frame` is relative to the parent; `children` follow the order of
/// the nodes' children.
public struct LayoutResult: Sendable, Equatable {
    public var frame: CGRect
    public var children: [LayoutResult]

    public init(frame: CGRect, children: [LayoutResult] = []) {
        self.frame = frame
        self.children = children
    }
}
