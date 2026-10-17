import Foundation
internal import yoga

/// How a measure function's size limit is meant, per axis.
public enum MeasureMode: Sendable, Equatable {
    /// No limit; the value passed is meaningless.
    case undefined
    /// The node gets exactly this size.
    case exactly
    /// The node may be at most this size.
    case atMost
}

/// Measures a leaf: `(width, widthMode, height, heightMode) -> size`.
public typealias MeasureFunction = (CGFloat, MeasureMode, CGFloat, MeasureMode) -> CGSize

/// One node of a flexbox tree, backed by a Yoga node.
///
/// Not `Sendable`: a tree belongs to one thread or task at a time. Build and
/// compute it off the main thread, then send the resulting values (frames)
/// to the main thread to apply.
public final class LayoutNode {
    let yogaNode: YGNodeRef
    public private(set) var children: [LayoutNode] = []
    public private(set) weak var parent: LayoutNode?

    public var style: LayoutStyle {
        didSet {
            if style != oldValue {
                apply(style)
                setHasPercentEdges(style.hasPercentEdges)
            }
        }
    }

    // Yoga resolves percentage padding, margins and insets against the
    // parent's size, but reuses a cached layout for a node whose own
    // available size didn't change, keeping the old values. These track the
    // nodes that have such edges, so a layout can find them and redo those
    // whose parent changed size.
    private var hasPercentEdges = false
    /// Nodes in this subtree, itself included, with percentage edges.
    private var percentEdgeNodes = 0
    /// The parent's content size the edges were last resolved against.
    private var percentBase: CGSize?

    /// Sizes a leaf from its content, for example text. A node with a measure
    /// function can't have children. Call `markDirty()` when the content
    /// changes.
    public var measureFunction: MeasureFunction? {
        didSet {
            installMeasureFunction()
        }
    }

    /// Marks a leaf as text. Yoga then rounds its size up rather than to the
    /// nearest pixel, so measured text never loses a pixel and wraps.
    public var isText = false {
        didSet {
            YGNodeSetNodeType(yogaNode, isText ? Yoga.nodeTypeText : Yoga.nodeTypeDefault)
        }
    }

    /// `nil` uses Yoga's defaults: frames rounded to whole points, no errata.
    public var config: LayoutConfig? {
        didSet {
            if config !== oldValue {
                YGNodeSetConfig(yogaNode, (config ?? Self.defaultConfig).yogaConfig)
            }
        }
    }

    private static let defaultConfig = LayoutConfig.shared(pointScaleFactor: 1, errata: .none)

    public init(style: LayoutStyle = LayoutStyle(), config: LayoutConfig? = nil, children: [LayoutNode] = []) {
        yogaNode = YGNodeNewWithConfig((config ?? Self.defaultConfig).yogaConfig)
        self.style = style
        self.config = config
        YGNodeSetContext(yogaNode, Unmanaged.passUnretained(self).toOpaque())
        apply(style)
        setHasPercentEdges(style.hasPercentEdges)
        for child in children {
            addChild(child)
        }
    }

    deinit {
        // Children are released after this, and freeing a Yoga node that has
        // already been detached from its owner is fine.
        YGNodeFree(yogaNode)
    }

    // MARK: Children

    /// Appends `child`. A node has at most one parent.
    public func addChild(_ child: LayoutNode) {
        insertChild(child, at: children.count)
    }

    public func insertChild(_ child: LayoutNode, at index: Int) {
        precondition(child.parent == nil && YGNodeGetOwner(child.yogaNode) == nil, "LayoutNode already has a parent")
        precondition(measureFunction == nil, "a node with a measure function can't have children")
        let index = min(max(index, 0), children.count)
        YGNodeInsertChild(yogaNode, child.yogaNode, index)
        children.insert(child, at: index)
        child.parent = self
        child.percentBase = nil
        addPercentEdgeNodes(child.percentEdgeNodes)
        if child.hasPercentEdges {
            // Its cached layout was resolved against another parent.
            child.markLayoutDirty()
        }
    }

    public func removeChild(_ child: LayoutNode) {
        guard let index = children.firstIndex(where: { $0 === child }) else { return }
        YGNodeRemoveChild(yogaNode, child.yogaNode)
        children.remove(at: index)
        child.parent = nil
        addPercentEdgeNodes(-child.percentEdgeNodes)
    }

    public func removeFromParent() {
        parent?.removeChild(self)
    }

    public func removeAllChildren() {
        YGNodeRemoveAllChildren(yogaNode)
        var removed = 0
        for child in children {
            child.parent = nil
            removed += child.percentEdgeNodes
        }
        children.removeAll()
        addPercentEdgeNodes(-removed)
    }

    // MARK: Computing

    /// Computes the layout of this subtree. `nil` leaves that axis unbounded.
    public func calculateLayout(
        width: CGFloat? = nil,
        height: CGFloat? = nil,
        direction: LayoutStyle.Direction = .leftToRight
    ) {
        YGNodeCalculateLayout(yogaNode, Yoga.float(width), Yoga.float(height), direction.yoga)
        // Redo the nodes whose percentage edges went stale. Their new
        // edges can resize their parents, so repeat, a few times at most.
        for _ in 0..<3 where percentEdgeNodes > 0 && invalidateStalePercentEdges() {
            YGNodeCalculateLayout(yogaNode, Yoga.float(width), Yoga.float(height), direction.yoga)
        }
    }

    /// Tells Yoga the measured content changed. Only for nodes with a measure
    /// function; other nodes are dirtied by their style and children.
    public func markDirty() {
        precondition(measureFunction != nil, "only nodes with a measure function can be marked dirty")
        YGNodeMarkDirty(yogaNode)
    }

    public var isDirty: Bool {
        YGNodeIsDirty(yogaNode)
    }

    /// Set by Yoga on every node whose layout was recomputed. Clear it after
    /// reading the frame; a subtree whose root doesn't have it set wasn't
    /// touched by the last calculation.
    public var hasNewLayout: Bool {
        get { YGNodeGetHasNewLayout(yogaNode) }
        set { YGNodeSetHasNewLayout(yogaNode, newValue) }
    }

    // MARK: Percentage edges

    private func setHasPercentEdges(_ value: Bool) {
        guard value != hasPercentEdges else { return }
        hasPercentEdges = value
        percentBase = nil
        addPercentEdgeNodes(value ? 1 : -1)
    }

    private func addPercentEdgeNodes(_ count: Int) {
        guard count != 0 else { return }
        var node: LayoutNode? = self
        while let current = node {
            current.percentEdgeNodes += count
            node = current.parent
        }
    }

    /// Marks dirty the nodes whose parent's content size changed since
    /// their percentage edges were resolved. Returns whether it marked any.
    private func invalidateStalePercentEdges() -> Bool {
        var marked = false
        if hasPercentEdges, let parent {
            let base = parent.contentSize
            if let old = percentBase, old != base {
                markLayoutDirty()
                marked = true
            }
            percentBase = base
        }
        for child in children where child.percentEdgeNodes > 0 {
            if child.invalidateStalePercentEdges() {
                marked = true
            }
        }
        return marked
    }

    /// The size inside the padding and border, which children's
    /// percentages resolve against.
    private var contentSize: CGSize {
        let size = frame.size
        let padding = resolvedPadding
        let border = resolvedBorder
        return CGSize(
            width: size.width - padding.left - padding.right - border.left - border.right,
            height: size.height - padding.top - padding.bottom - border.top - border.bottom
        )
    }

    /// Makes Yoga lay this node out again. Its C API only dirties nodes
    /// with a measure function directly; any other node is dirtied by a
    /// style change, so one is made and undone.
    private func markLayoutDirty() {
        if measureFunction != nil {
            YGNodeMarkDirty(yogaNode)
            return
        }
        let ratio = YGNodeStyleGetAspectRatio(yogaNode)
        YGNodeStyleSetAspectRatio(yogaNode, ratio.isNaN ? 1 : .nan)
        YGNodeStyleSetAspectRatio(yogaNode, ratio)
    }

    // MARK: Results

    /// The frame from the last `calculateLayout`, relative to the parent.
    public var frame: CGRect {
        CGRect(
            x: CGFloat(YGNodeLayoutGetLeft(yogaNode)),
            y: CGFloat(YGNodeLayoutGetTop(yogaNode)),
            width: CGFloat(YGNodeLayoutGetWidth(yogaNode)),
            height: CGFloat(YGNodeLayoutGetHeight(yogaNode))
        )
    }

    /// Border widths per physical edge, with `start`/`end` resolved.
    public var resolvedBorder: Insets {
        Insets(
            top: CGFloat(YGNodeLayoutGetBorder(yogaNode, Yoga.edgeTop)),
            left: CGFloat(YGNodeLayoutGetBorder(yogaNode, Yoga.edgeLeft)),
            bottom: CGFloat(YGNodeLayoutGetBorder(yogaNode, Yoga.edgeBottom)),
            right: CGFloat(YGNodeLayoutGetBorder(yogaNode, Yoga.edgeRight))
        )
    }

    /// Padding per physical edge, with `start`/`end` and percentages resolved.
    public var resolvedPadding: Insets {
        Insets(
            top: CGFloat(YGNodeLayoutGetPadding(yogaNode, Yoga.edgeTop)),
            left: CGFloat(YGNodeLayoutGetPadding(yogaNode, Yoga.edgeLeft)),
            bottom: CGFloat(YGNodeLayoutGetPadding(yogaNode, Yoga.edgeBottom)),
            right: CGFloat(YGNodeLayoutGetPadding(yogaNode, Yoga.edgeRight))
        )
    }

    /// The direction this node was laid out in.
    public var resolvedDirection: LayoutStyle.Direction {
        rawYogaValue(YGNodeLayoutGetDirection(yogaNode)) == 2 ? .rightToLeft : .leftToRight
    }

    /// The frames of this subtree from the last `calculateLayout`.
    public var result: LayoutResult {
        LayoutResult(frame: frame, children: children.map(\.result))
    }

    // MARK: Style

    private func installMeasureFunction() {
        guard measureFunction != nil else {
            YGNodeSetMeasureFunc(yogaNode, nil)
            return
        }
        precondition(children.isEmpty, "a node with a measure function can't have children")
        // A C function pointer can't capture, so the node is found again
        // through the context pointer set in `init`.
        YGNodeSetMeasureFunc(yogaNode) { node, width, widthMode, height, heightMode in
            guard let context = YGNodeGetContext(node) else {
                return YGSize(width: 0, height: 0)
            }
            let owner = Unmanaged<LayoutNode>.fromOpaque(context).takeUnretainedValue()
            let size = owner.measureFunction?(
                CGFloat(width),
                MeasureMode(yoga: widthMode),
                CGFloat(height),
                MeasureMode(yoga: heightMode)
            ) ?? .zero
            return YGSize(width: Float(size.width), height: Float(size.height))
        }
    }

    private func apply(_ style: LayoutStyle) {
        let node = yogaNode
        YGNodeStyleSetDirection(node, style.direction.yoga)
        YGNodeStyleSetFlexDirection(node, style.flexDirection.yoga)
        YGNodeStyleSetJustifyContent(node, style.justifyContent.yoga)
        YGNodeStyleSetAlignItems(node, style.alignItems.yoga)
        YGNodeStyleSetAlignSelf(node, style.alignSelf.yoga)
        YGNodeStyleSetAlignContent(node, style.alignContent.yoga)
        YGNodeStyleSetFlexWrap(node, style.flexWrap.yoga)
        YGNodeStyleSetPositionType(node, style.position.yoga)
        YGNodeStyleSetDisplay(node, style.display.yoga)
        YGNodeStyleSetOverflow(node, style.overflow.yoga)
        YGNodeStyleSetBoxSizing(node, style.boxSizing.yoga)

        YGNodeStyleSetFlex(node, Yoga.float(style.flex))
        YGNodeStyleSetFlexGrow(node, Yoga.float(style.flexGrow))
        YGNodeStyleSetFlexShrink(node, Yoga.float(style.flexShrink))
        switch style.flexBasis {
        case .auto: YGNodeStyleSetFlexBasisAuto(node)
        case .points(let value): YGNodeStyleSetFlexBasis(node, Float(value))
        case .percent(let value): YGNodeStyleSetFlexBasisPercent(node, Float(value))
        }

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
        setBound(style.minWidth, YGNodeStyleSetMinWidth, YGNodeStyleSetMinWidthPercent)
        setBound(style.minHeight, YGNodeStyleSetMinHeight, YGNodeStyleSetMinHeightPercent)
        setBound(style.maxWidth, YGNodeStyleSetMaxWidth, YGNodeStyleSetMaxWidthPercent)
        setBound(style.maxHeight, YGNodeStyleSetMaxHeight, YGNodeStyleSetMaxHeightPercent)
        YGNodeStyleSetAspectRatio(node, Yoga.float(style.aspectRatio))

        for (edge, value) in style.insets.yogaEdges {
            switch value {
            case nil: YGNodeStyleSetPosition(node, edge, .nan)
            case .auto: YGNodeStyleSetPositionAuto(node, edge)
            case .points(let value): YGNodeStyleSetPosition(node, edge, Float(value))
            case .percent(let value): YGNodeStyleSetPositionPercent(node, edge, Float(value))
            }
        }
        for (edge, value) in style.margins.yogaEdges {
            switch value {
            case nil: YGNodeStyleSetMargin(node, edge, .nan)
            case .auto: YGNodeStyleSetMarginAuto(node, edge)
            case .points(let value): YGNodeStyleSetMargin(node, edge, Float(value))
            case .percent(let value): YGNodeStyleSetMarginPercent(node, edge, Float(value))
            }
        }
        for (edge, value) in style.paddings.yogaEdges {
            switch value {
            case nil, .auto: YGNodeStyleSetPadding(node, edge, .nan)
            case .points(let value): YGNodeStyleSetPadding(node, edge, Float(value))
            case .percent(let value): YGNodeStyleSetPaddingPercent(node, edge, Float(value))
            }
        }
        for (edge, value) in style.borderWidths.yogaEdges {
            YGNodeStyleSetBorder(node, edge, Yoga.float(value))
        }

        YGNodeStyleSetGap(node, Yoga.gutterAll, Yoga.float(style.gap))
        YGNodeStyleSetGap(node, Yoga.gutterRow, Yoga.float(style.rowGap))
        YGNodeStyleSetGap(node, Yoga.gutterColumn, Yoga.float(style.columnGap))
    }

    private func setBound(
        _ value: Dimension,
        _ setPoints: (YGNodeRef, Float) -> Void,
        _ setPercent: (YGNodeRef, Float) -> Void
    ) {
        switch value {
        case .auto: setPoints(yogaNode, .nan)
        case .points(let points): setPoints(yogaNode, Float(points))
        case .percent(let percent): setPercent(yogaNode, Float(percent))
        }
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
