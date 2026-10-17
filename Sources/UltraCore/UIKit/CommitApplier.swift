#if canImport(UIKit)
import QuartzCore
import UIKit
import UltraLayout

/// Applies commits to views on the main thread. The work is proportional to
/// the entries in the commit: it assigns frames, properties and contents,
/// creates or removes views, and reorders subviews. It never measures, lays
/// out or draws.
@MainActor
enum CommitApplier {
    /// Applies `commit` in one Core Animation transaction without implicit
    /// animations. `rootContainer` receives the root node's view.
    static func apply(_ commit: Commit, root: UltraNode, in rootContainer: UIView) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let entries = commit.orderedEntries
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

        if let rootView = root.mountedView {
            if rootView.superview !== rootContainer {
                rootContainer.addSubview(rootView)
            }
        }
        // A view whose parent didn't take it can't be shown; let it go.
        for entry in mounts where entry.node !== root && entry.node.mountedView?.superview == nil {
            entry.node.unmountView()
        }
    }
}

extension UltraNode {
    @MainActor
    func ensureView() {
        if mountedView == nil {
            mountedView = makeView()
        }
    }

    /// Removes the node's view and its mounted descendants' views.
    @MainActor
    func unmountView() {
        let view = mountedView
        let children = mountedChildren
        mountedChildren = []
        for child in children where child.mountedView?.superview === view {
            child.unmountView()
        }
        view?.removeFromSuperview()
        mountedView = nil
        appliedProps = nil
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
        switch entry.contents {
        case .set(let contents)?:
            view.layer.contents = contents.cgImage
            view.layer.contentsScale = contents.scale
        case .clear?:
            view.layer.contents = nil
        case nil:
            if entry.kind == .mount {
                view.layer.contents = nil
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
    @MainActor
    private func order(_ children: [UltraNode], in view: UIView) {
        mountedChildren = children
        let wanted = children.compactMap(\.mountedView)
        let wantedSet = Set(wanted.map(ObjectIdentifier.init))
        let current = view.subviews.filter { wantedSet.contains(ObjectIdentifier($0)) }
        guard current.count != wanted.count || !zip(current, wanted).allSatisfy({ $0 === $1 }) else { return }
        var previous: UIView?
        for child in wanted {
            if let previous {
                view.insertSubview(child, aboveSubview: previous)
            } else {
                view.insertSubview(child, at: 0)
            }
            previous = child
        }
    }
}

/// Sets view properties, only those that changed.
@MainActor
enum ViewPropsApplier {
    static func apply(_ props: ViewProps, previous: ViewProps?, to view: UIView) {
        func changed<Value: Equatable>(_ keyPath: KeyPath<ViewProps, Value>) -> Bool {
            previous.map { $0[keyPath: keyPath] != props[keyPath: keyPath] } ?? true
        }
        let layer = view.layer

        if changed(\.backgroundColor) {
            layer.backgroundColor = props.backgroundColor?.cgColor
        }
        if changed(\.cornerRadius) || changed(\.maskedCorners) {
            layer.cornerRadius = props.cornerRadius
            layer.maskedCorners = props.maskedCorners.layerCorners
        }
        if changed(\.borderWidth) || changed(\.borderColor) {
            layer.borderWidth = props.borderWidth
            layer.borderColor = props.borderColor?.cgColor
        }
        if changed(\.transform) {
            layer.transform = props.transform.caTransform
        }
        if changed(\.clipsToBounds) {
            view.clipsToBounds = props.clipsToBounds
        }
        if changed(\.shadow) {
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
        if changed(\.isHidden) {
            view.isHidden = props.isHidden
        }
        if changed(\.accessibility) {
            let accessibility = props.accessibility
            view.isAccessibilityElement = accessibility.isElement
            view.accessibilityLabel = accessibility.label
            view.accessibilityHint = accessibility.hint
            view.accessibilityTraits = accessibility.role?.traits ?? []
            view.accessibilityElementsHidden = accessibility.hidden
        }

        switch view {
        case let nodeView as NodeView:
            // Sets the opacity too, accounting for a press in progress.
            nodeView.props = props
        case let scrollView as ScrollNodeView:
            scrollView.props = props
            if changed(\.opacity) {
                view.alpha = props.opacity
            }
            if let scroll = props.scroll, changed(\.scroll) {
                scrollView.configure(scroll)
            }
        default:
            if changed(\.opacity) {
                view.alpha = props.opacity
            }
        }
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
