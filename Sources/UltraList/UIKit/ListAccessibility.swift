#if canImport(UIKit)
import UIKit

/// Preserves logical focus while the window replaces its row views.
@MainActor
final class ListAccessibility: NSObject {
    weak var list: UltraListView?
    var notify: (UIAccessibility.Notification, Any?) -> Void = { UIAccessibility.post(notification: $0, argument: $1) }
    private(set) var preferredIdentity: String?
    private var path: [Int] = []
    private var screenY: CGFloat = 0
    private weak var currentElement: AnyObject?
    private weak var requestedElement: AnyObject?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(focusChanged(_:)), name: UIAccessibility.elementFocusedNotification, object: nil)
    }

    @objc private func focusChanged(_ notification: Notification) {
        guard let element = notification.userInfo?[UIAccessibility.focusedElementUserInfoKey] else { return }
        recordFocus(element as AnyObject)
    }

    func recordFocus(_ element: AnyObject) {
        currentElement = element
        if element === requestedElement { return }
        requestedElement = nil
        guard let list, let match = rows().first(where: { contains(element, in: $0.view) }) else {
            preferredIdentity = nil; path = []; return
        }
        preferredIdentity = match.identity
        path = []
        if var view = element as? UIView {
            screenY = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: list).y
            while view !== match.view, let parent = view.superview, let index = parent.subviews.firstIndex(of: view) {
                path.insert(index, at: 0); view = parent
            }
        } else { screenY = match.view.convert(match.view.bounds, to: list).midY }
    }

    func reconcile() {
        guard let list, let preferredIdentity else { return }
        let visible = rows().filter { row in
            guard row.view.isDisplayReady else { return false }
            let rect = row.view.convert(row.view.bounds, to: list).intersection(list.bounds)
            return !rect.isNull && rect.width > 0 && rect.height > 0
        }
        guard !visible.isEmpty else { return }
        let preferred = visible.first { $0.identity == preferredIdentity }
        let selected = preferred ?? visible.min { abs($0.view.convert($0.view.bounds, to: list).midY - screenY) < abs($1.view.convert($1.view.bounds, to: list).midY - screenY) }!
        if list.index(forRowIdentity: preferredIdentity) == nil {
            self.preferredIdentity = selected.identity; path = []
        }
        var view = selected.view as UIView
        if preferred != nil {
            for index in path {
                guard view.subviews.indices.contains(index) else { break }
                view = view.subviews[index]
            }
        }
        guard let target = firstElement(in: view) ?? firstElement(in: selected.view) else { return }
        if target === currentElement || target === requestedElement { return }
        requestedElement = target
        notify(.layoutChanged, target)
    }

    private func rows() -> [(identity: String, view: ListRowView)] {
        guard let list else { return [] }
        return list.loadedIndexRange.compactMap { index in
            guard list.items.indices.contains(index), let view = list.loadedItemView(at: index) else { return nil }
            return (list.items[index].identity, view)
        }
    }

    private func contains(_ element: AnyObject, in row: UIView) -> Bool {
        var element: AnyObject? = element
        var seen = Set<ObjectIdentifier>()
        while let current = element, seen.insert(ObjectIdentifier(current)).inserted {
            if let view = current as? UIView { return view === row || view.isDescendant(of: row) }
            element = (current as? UIAccessibilityElement)?.accessibilityContainer as AnyObject?
        }
        return false
    }

    private func firstElement(in view: UIView) -> AnyObject? {
        guard !view.isHidden, view.alpha > 0.01 else { return nil }
        if view.isAccessibilityElement { return view }
        if let element = view.accessibilityElements?.first { return element as AnyObject }
        for child in view.subviews {
            if let element = firstElement(in: child) { return element }
        }
        return nil
    }
}
#endif