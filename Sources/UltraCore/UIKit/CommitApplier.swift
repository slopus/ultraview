#if canImport(UIKit)
import QuartzCore
import UIKit
import UltraLayout

/// Applies commits to views on the main thread. The work is proportional to
/// the entries applied: it assigns frames, properties and contents, creates
/// or removes views, and reorders subviews. It never measures, lays out or
/// draws.
@MainActor
enum CommitApplier {
    /// Applies a turn in one Core Animation transaction without implicit
    /// animations: all of `turn.now`, then entries from `turn.later` until
    /// `deadline`, at least `minimum` of them. Returns how many of
    /// `turn.later` it applied. `rootContainer` receives the root node's
    /// view.
    static func apply(
        _ turn: CommitQueue.Turn,
        in rootContainer: UIView,
        until deadline: CFTimeInterval,
        minimum: Int
    ) -> Int {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let entries = turn.now
        for entry in entries where entry.kind == .unmount {
            entry.node.unmountView()
        }
        let mounts = entries.filter { $0.kind == .mount }.sorted { $0.depth < $1.depth }
        for entry in mounts {
            entry.node.ensureView()
        }
        for entry in entries where entry.kind != .unmount {
            entry.node.apply(entry)
        }
        for entry in mounts {
            entry.node.placeView(parent: entry.parent, rootContainer: rootContainer)
        }

        var applied = 0
        for entry in turn.later {
            guard applied < minimum || CACurrentMediaTime() < deadline else { break }
            if entry.kind == .unmount {
                entry.node.unmountView()
            } else {
                entry.node.ensureView()
                entry.node.apply(entry)
                entry.node.placeView(parent: entry.parent, rootContainer: rootContainer)
            }
            applied += 1
        }
        return applied
    }
}

extension UltraNode {
    @MainActor
    func ensureView() {
        if mountedView == nil {
            mountedView = makeView()
        }
    }

    /// Puts a newly mounted node's view into its parent's view, among its
    /// siblings, unless the parent already placed it while ordering its
    /// children. A view whose parent has no view, or doesn't list it, can't
    /// be shown: it is let go.
    @MainActor
    func placeView(parent: UltraNode?, rootContainer: UIView) {
        guard let view = mountedView, view.superview == nil else { return }
        guard let parent else {
            rootContainer.addSubview(view)
            return
        }
        guard let parentView = parent.mountedView,
              let position = parent.mountedChildren.firstIndex(where: { $0 === self })
        else {
            unmountView()
            return
        }
        let siblings = parent.mountedChildren
        for sibling in siblings[..<position].reversed() {
            if let siblingView = sibling.mountedView, siblingView.superview === parentView {
                parentView.insertSubview(view, aboveSubview: siblingView)
                return
            }
        }
        for sibling in siblings[(position + 1)...] {
            if let siblingView = sibling.mountedView, siblingView.superview === parentView {
                parentView.insertSubview(view, belowSubview: siblingView)
                return
            }
        }
        parentView.insertSubview(view, at: 0)
    }

    /// Removes the node's view and its mounted descendants' views. Only the
    /// node's own view leaves its superview; the descendants' views go with
    /// it, which saves UIKit a window change per view.
    @MainActor
    func unmountView() {
        mountedView?.removeFromSuperview()
        forgetViews()
    }

    @MainActor
    private func forgetViews() {
        let view = mountedView
        for child in mountedChildren where child.mountedView?.superview === view {
            child.forgetViews()
        }
        mountedChildren = []
        mountedView = nil
        appliedProps = nil
        appliedContents = nil
    }

    @MainActor
    func apply(_ entry: CommitEntry) {
        guard let view = mountedView else { return }
        if let frame = entry.frame {
            // Bounds and center rather than frame, which is undefined under a
            // transform. A scroll view's bounds origin is its offset: keep it.
            var bounds = view.bounds
            bounds.size = frame.size
            view.bounds = bounds
            view.center = CGPoint(x: frame.midX, y: frame.midY)
        }
        if let props = entry.props {
            ViewPropsApplier.apply(props, previous: entry.kind == .mount ? nil : appliedProps, to: view)
            appliedProps = props
        }
        // While parts of a text fade in, its bitmap is on a sublayer.
        switch entry.contents {
        case .set(let contents)?:
            let drawn = NodeTransitionAnimator.contentsLayer(of: view.layer)
            drawn.contents = contents.cgImage
            drawn.contentsScale = contents.scale
            if appliedContents?.placement != contents.placement || entry.kind == .mount {
                contents.placement.apply(to: view, size: contents.size)
                drawn.contentsGravity = view.layer.contentsGravity
                drawn.contentsCenter = view.layer.contentsCenter
            }
            appliedContents = contents
        case .clear?:
            NodeTransitionAnimator.contentsLayer(of: view.layer).contents = nil
            appliedContents = nil
        case nil:
            if entry.kind == .mount {
                NodeTransitionAnimator.contentsLayer(of: view.layer).contents = nil
                appliedContents = nil
            }
        }
        if let children = entry.children {
            order(children, in: view)
        }
        didApply(entry)
    }

    /// Puts the children's views in `view` in order, after the node's own
    /// sublayers and below any non-node subviews (such as scroll
    /// indicators).
    ///
    /// Only views that are new or out of order are inserted: when a scroll
    /// range moves, the rows that stay keep their place and only the rows
    /// coming in are added.
    @MainActor
    private func order(_ children: [UltraNode], in view: UIView) {
        mountedChildren = children
        let wanted = children.compactMap(\.mountedView)
        let wantedSet = Set(wanted.map(ObjectIdentifier.init))
        // The wanted views already in `view`, bottom to top.
        let current = view.subviews.filter { wantedSet.contains(ObjectIdentifier($0)) }
        var moved = Set<ObjectIdentifier>()
        var cursor = 0
        var previous: UIView?
        for child in wanted {
            while cursor < current.count, moved.contains(ObjectIdentifier(current[cursor])) {
                cursor += 1
            }
            if cursor < current.count, current[cursor] === child {
                // Above everything placed so far: already in order.
                cursor += 1
            } else {
                if let previous {
                    view.insertSubview(child, aboveSubview: previous)
                } else {
                    view.insertSubview(child, at: 0)
                }
                moved.insert(ObjectIdentifier(child))
            }
            previous = child
        }
    }
}

/// Sets view properties, only those that changed.
@MainActor
enum ViewPropsApplier {
    static func apply(_ props: ViewProps, previous: ViewProps?, to view: UIView) {
        let initial = previous == nil
        let layer = view.layer

        if initial || previous?.backgroundColor != props.backgroundColor {
            layer.backgroundColor = props.backgroundColor?.cgColor
        }
        if initial || previous?.cornerRadius != props.cornerRadius || previous?.maskedCorners != props.maskedCorners {
            layer.cornerRadius = props.cornerRadius
            layer.maskedCorners = props.maskedCorners.layerCorners
        }
        if initial || previous?.borderWidth != props.borderWidth || previous?.borderColor != props.borderColor {
            layer.borderWidth = props.borderWidth
            layer.borderColor = props.borderColor?.cgColor
        }
        if initial || previous?.transform != props.transform {
            layer.transform = props.transform.caTransform
        }
        if initial || previous?.clipsToBounds != props.clipsToBounds {
            view.clipsToBounds = props.clipsToBounds
        }
        if initial || previous?.shadow != props.shadow {
            if let shadow = props.shadow {
                layer.shadowColor = shadow.color.cgColor
                layer.shadowOpacity = Float(shadow.opacity)
                layer.shadowOffset = shadow.offset
                layer.shadowRadius = shadow.radius
                layer.shadowPath = shadow.path.map { path in
                    let radius = min(path.cornerRadius, path.rect.width / 2, path.rect.height / 2)
                    return CGPath(roundedRect: path.rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
                }
            } else {
                layer.shadowOpacity = 0
                layer.shadowPath = nil
            }
        }
        if initial || previous?.isHidden != props.isHidden {
            view.isHidden = props.isHidden
        }
        let accessibility = props.accessibility
        let oldAccessibility = previous?.accessibility
        if initial || oldAccessibility?.isElement != accessibility.isElement {
            view.isAccessibilityElement = accessibility.isElement
        }
        if initial || oldAccessibility?.label != accessibility.label {
            view.accessibilityLabel = accessibility.label
        }
        if initial || oldAccessibility?.hint != accessibility.hint {
            view.accessibilityHint = accessibility.hint
        }
        if initial || oldAccessibility?.role != accessibility.role {
            view.accessibilityTraits = accessibility.role?.traits ?? []
        }
        if initial || oldAccessibility?.hidden != accessibility.hidden {
            view.accessibilityElementsHidden = accessibility.hidden
        }

        switch view {
        case let nodeView as NodeView:
            // Sets the opacity too, accounting for a press in progress.
            nodeView.props = props
        case let scrollView as ScrollNodeView:
            scrollView.props = props
            if initial || previous?.opacity != props.opacity {
                view.alpha = props.opacity
            }
            if let scroll = props.scroll, initial || previous?.scroll != props.scroll {
                scrollView.configure(scroll)
            }
        default:
            if initial || previous?.opacity != props.opacity {
                view.alpha = props.opacity
            }
        }
    }
}

extension ContentsPlacement {
    /// Sets how the view shows a bitmap of `size` when its bounds differ.
    @MainActor
    func apply(to view: UIView, size: CGSize) {
        switch self {
        case .fill:
            view.contentMode = .scaleToFill
            view.layer.contentsCenter = CGRect(x: 0, y: 0, width: 1, height: 1)
        case .top(let alignment):
            view.contentMode = switch alignment {
            case .left: .topLeft
            case .center: .top
            case .right: .topRight
            }
            view.layer.contentsCenter = CGRect(x: 0, y: 0, width: 1, height: 1)
        case .stretch(let insets):
            view.contentMode = .scaleToFill
            view.layer.contentsCenter = contentsCenter(size: size, insets: insets)
        }
    }

    /// The stretchable middle in unit coordinates of a bitmap of `size`.
    func contentsCenter(size: CGSize, insets: Insets) -> CGRect {
        guard size.width > 0, size.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(
            x: insets.left / size.width,
            y: insets.top / size.height,
            width: max(0, size.width - insets.left - insets.right) / size.width,
            height: max(0, size.height - insets.top - insets.bottom) / size.height
        )
    }
}

extension CornerMask {
    var layerCorners: CACornerMask {
        var corners: CACornerMask = []
        if contains(.topLeft) { corners.insert(.layerMinXMinYCorner) }
        if contains(.topRight) { corners.insert(.layerMaxXMinYCorner) }
        if contains(.bottomLeft) { corners.insert(.layerMinXMaxYCorner) }
        if contains(.bottomRight) { corners.insert(.layerMaxXMaxYCorner) }
        return corners
    }
}

extension Transform3D {
    var caTransform: CATransform3D {
        CATransform3D(
            m11: self[0, 0], m12: self[0, 1], m13: self[0, 2], m14: self[0, 3],
            m21: self[1, 0], m22: self[1, 1], m23: self[1, 2], m24: self[1, 3],
            m31: self[2, 0], m32: self[2, 1], m33: self[2, 2], m34: self[2, 3],
            m41: self[3, 0], m42: self[3, 1], m43: self[3, 2], m44: self[3, 3]
        )
    }
}

extension AccessibilityRole {
    var traits: UIAccessibilityTraits {
        switch self {
        case .none: []
        case .button, .toggleButton: .button
        case .link: .link
        case .header: .header
        case .image: .image
        case .text: .staticText
        case .search: .searchField
        case .adjustable: .adjustable
        case .summary: .summaryElement
        case .tab: .tabBar
        }
    }
}
#endif
