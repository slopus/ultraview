#if canImport(UIKit)
import UIKit
import UltraView

struct ListChaosFinding {
    /// Kinds that are logged and counted but never trap: resting-state
    /// expectations that the list doesn't promise in every engine.
    static let advisoryKinds: Set<String> = ["restingOverscroll", "coverageTop", "coverageBottom", "neverSettles"]
    var kind: String
    var detail: String
    var isAdvisory: Bool { Self.advisoryKinds.contains(kind) }
}

/// Node hosts found by walking the window, plus weak records of every list
/// host and root seen so far. A host that never appears in a walk is not
/// counted, so the live counts are lower bounds.
struct ListChaosCensus {
    var views = 0
    var hosts = 0
    var hiddenHosts = 0
    var listHosts = 0
    var duplicateRoots = 0
    var liveListHosts = 0
    var liveListRoots = 0
    var orphanListHosts: Int { max(0, liveListHosts - listHosts) }
    var dictionary: [String: Int] {
        ["views": views, "hosts": hosts, "hiddenHosts": hiddenHosts, "listHosts": listHosts, "duplicateRoots": duplicateRoots,
         "liveListHosts": liveListHosts, "liveListRoots": liveListRoots, "orphanListHosts": orphanListHosts]
    }
}

@MainActor
final class ListChaosInspector {
    private let seenHosts = NSHashTable<NodeHostView>.weakObjects()
    private let seenRoots = NSHashTable<UltraNode>.weakObjects()
    private var reserveHeights: [String: Double] = [:]

    func census(window: UIWindow?) -> ListChaosCensus {
        var census = ListChaosCensus()
        var roots: [ObjectIdentifier: Int] = [:]
        var stack: [(UIView, Bool)] = window.map { [($0, false)] } ?? []
        while let entry = stack.popLast() {
            let (view, insideList) = entry
            census.views += 1
            let inList = insideList || view is UltraListView
            if let host = view as? NodeHostView {
                census.hosts += 1
                if host.isHidden { census.hiddenHosts += 1 }
                roots[ObjectIdentifier(host.rootNode), default: 0] += 1
                if inList { census.listHosts += 1; seenHosts.add(host); seenRoots.add(host.rootNode) }
                // A host's subviews are its node views; no host nests another here.
                continue
            }
            for child in view.subviews { stack.append((child, inList)) }
        }
        census.duplicateRoots = roots.values.filter { $0 > 1 }.count
        census.liveListHosts = seenHosts.allObjects.count
        census.liveListRoots = seenRoots.allObjects.count
        return census
    }

    /// Valid after any pass: settled frames are destinations, not animated values.
    func structural(_ list: UltraListView) -> [ListChaosFinding] {
        var findings: [ListChaosFinding] = []
        func fail(_ kind: String, _ detail: String) { findings.append(.init(kind: kind, detail: detail)) }
        let items = list.items, window = list.settledWindow, range = list.loadedIndexRange
        guard range.lowerBound >= 0, range.upperBound <= items.count else {
            fail("windowRange", "range \(range) items \(items.count)"); return findings
        }
        for (offset, row) in window.rows.enumerated() where row.index != range.lowerBound + offset {
            fail("windowContiguity", "row \(offset) index \(row.index) range \(range)"); return findings
        }
        let views = list.loadedItemViews
        if views.count != window.rows.count { fail("loadedViews", "views \(views.count) rows \(window.rows.count)") }
        let insets = list.viewportInsets
        let width = Double(list.bounds.width) - insets.left - insets.right
        var seen = Set<ObjectIdentifier>()
        var previous: (row: WindowRow, frame: CGRect)?
        for row in window.rows {
            guard let frame = list.settledFrame(at: row.index), let presented = list.presentedFrame(at: row.index) else {
                fail("missingFrame", "index \(row.index)"); previous = nil; continue
            }
            let values = [frame.minX, frame.minY, frame.width, frame.height, presented.minX, presented.minY, presented.width, presented.height]
            if !values.allSatisfy(\.isFinite) { fail("nonFiniteFrame", "index \(row.index) settled \(frame) presented \(presented)") }
            if let view = list.loadedItemView(at: row.index) {
                if !seen.insert(ObjectIdentifier(view)).inserted { fail("sharedRowView", "index \(row.index)") }
                if view.superview == nil { fail("detachedRowView", "index \(row.index)") }
            } else { fail("missingRowView", "index \(row.index) identity \(items[row.index].identity)") }
            if let demo = items[row.index] as? DemoListRow, demo.height >= 8, abs(Double(frame.height) - demo.height) > 0.5 {
                fail("rowHeight", "index \(row.index) identity \(demo.identity) revision \(demo.revision) settled \(frame.height) declared \(demo.height)")
            }
            let expected = reserves(items, row.index, width: width)
            if row.reservedTop < 0 || row.reservedBottom < 0 || abs(expected.top - row.reservedTop) > 0.01 || abs(expected.bottom - row.reservedBottom) > 0.01 {
                fail("attachmentReserve", "index \(row.index) window \(row.reservedTop)/\(row.reservedBottom) expected \(expected.top)/\(expected.bottom)")
            }
            if let previous {
                let gap = Double(frame.minY - previous.frame.maxY), expectedGap = previous.row.reservedBottom + row.reservedTop
                if abs(gap - expectedGap) > 0.01 {
                    fail("geometryGap", "between \(previous.row.index) and \(row.index): gap \(gap) expected \(expectedGap)")
                }
            }
            previous = (row, frame)
        }
        findings += swipeStructure(list)
        return findings
    }

    /// At most one row shows its actions, and it is the controller's revealed
    /// row. A row closing still animates, but its model offset is already zero.
    private func swipeStructure(_ list: UltraListView) -> [ListChaosFinding] {
        let items = list.items, revealed = list.swipeActions.revealedIdentity
        let open = list.loadedIndexRange.compactMap { index -> (String, Double)? in
            guard let view = list.loadedItemView(at: index) else { return nil }
            let offset = Double(view.layer.sublayerTransform.m41)
            return abs(offset) > 0.5 ? (items[index].identity, offset) : nil
        }
        var findings: [ListChaosFinding] = []
        if open.count > 1 { findings.append(.init(kind: "swipeOpenRows", detail: "\(open) revealed \(revealed ?? "nil")")) }
        if let row = open.first, row.0 != revealed { findings.append(.init(kind: "swipeUntracked", detail: "\(row) revealed \(revealed ?? "nil")")) }
        return findings
    }

    /// At rest: the revealed row is loaded at its open width with every button
    /// covering the uncovered area, no other row keeps buttons or an offset,
    /// and each row's VoiceOver actions are its current swipe actions.
    private func swipeRest(_ list: UltraListView) -> [ListChaosFinding] {
        var findings: [ListChaosFinding] = []
        func fail(_ kind: String, _ detail: String) { findings.append(.init(kind: kind, detail: detail)) }
        let items = list.items, revealed = list.swipeActions.revealedIdentity
        func buttons(_ view: UIView) -> [CALayer] { (view.layer.sublayers ?? []).filter { $0.name?.hasPrefix("swipe:") == true } }
        if let revealed {
            if let index = items.firstIndex(where: { $0.identity == revealed }) {
                if let view = list.loadedItemView(at: index) {
                    let offset = Double(view.layer.sublayerTransform.m41), item = items[index]
                    let actions = offset < 0 ? item.trailingSwipeActions : item.leadingSwipeActions
                    let openWidth = actions.reduce(0) { $0 + $1.width }
                    if abs(abs(offset) - openWidth) > 0.5 { fail("swipeRestingOffset", "\(revealed) offset \(offset) open width \(openWidth)") }
                    let shown = buttons(view)
                    if shown.count != actions.count { fail("swipeButtons", "\(revealed) shows \(shown.count) of \(actions.count)") }
                    if !shown.isEmpty, abs(offset) > 0.5 {
                        let width = Double(view.layer.bounds.width)
                        let spans = shown.map { (Double($0.position.x) + offset, Double($0.position.x) + offset + Double($0.bounds.width)) }.sorted { $0.0 < $1.0 }
                        var union = spans[0], error = 0.0
                        for span in spans.dropFirst() { error = max(error, span.0 - union.1); union.1 = max(union.1, span.1) }
                        let expected = offset < 0 ? (width + offset, width) : (0, offset)
                        error = max(error, abs(union.0 - expected.0), abs(union.1 - expected.1))
                        if error > 0.5 { fail("swipeButtonDetach", "\(revealed) error \(error) spans \(spans) offset \(offset)") }
                    }
                } else { fail("swipeRevealNotLoaded", "\(revealed) at \(index), loaded \(list.loadedIndexRange)") }
            } else { fail("swipeStaleReveal", "\(revealed) is not in the collection") }
        }
        for index in list.loadedIndexRange {
            guard let view = list.loadedItemView(at: index) else { continue }
            let item = items[index]
            if item.identity != revealed, !CATransform3DIsIdentity(view.layer.sublayerTransform) || !buttons(view).isEmpty {
                fail("swipeLeak", "\(item.identity) offset \(view.layer.sublayerTransform.m41) buttons \(buttons(view).count) revealed \(revealed ?? "nil")")
            }
            let expected = (item.leadingSwipeActions + item.trailingSwipeActions).map(\.title)
            let names = (view.accessibilityCustomActions ?? []).map(\.name)
            if names != expected { fail("swipeCustomActions", "\(item.identity) has \(names) expected \(expected)") }
        }
        return findings
    }

    /// Valid only once the list rests with the host's newest collection.
    func settled(_ list: UltraListView, model: [DemoListRow]?, checksPin: Bool) -> [ListChaosFinding] {
        var findings = structural(list)
        func fail(_ kind: String, _ detail: String) { findings.append(.init(kind: kind, detail: detail)) }
        let items = list.items, range = list.loadedIndexRange, rows = list.settledWindow.rows
        if Set(items.map(\.identity)).count != items.count { fail("duplicateIdentity", "items \(items.count)") }
        if let model, let mismatch = Self.firstMismatch(model, items) {
            fail("staleSnapshot", mismatch)
        }
        if !items.isEmpty, list.bounds.width > 0, list.bounds.height > 0, range.isEmpty { fail("emptyWindow", "items \(items.count)") }
        if let first = rows.first, first.index > 0, let frame = list.settledFrame(at: first.index), Double(frame.minY) - first.reservedTop > 0.5 {
            fail("coverageTop", "first \(first.index) top \(Double(frame.minY) - first.reservedTop)")
        }
        if let last = rows.last, last.index + 1 < items.count, let frame = list.settledFrame(at: last.index),
           Double(frame.maxY) + last.reservedBottom < Double(list.bounds.height) - 0.5 {
            fail("coverageBottom", "last \(last.index) bottom \(Double(frame.maxY) + last.reservedBottom) height \(list.bounds.height)")
        }
        if abs(list.overscrollDistance) > 0.5 { fail("restingOverscroll", "\(list.overscrollDistance)") }
        findings += swipeRest(list)
        if checksPin, list.holdsPinnedRow, let pinned = items.firstIndex(where: \.pinsToBottomEdge), range.contains(pinned), !list.isStrictlyPinnedToBottomEdge {
            fail("pinEdge", "pinned \(pinned) frame \(list.presentedFrame(at: pinned).map { "\($0)" } ?? "nil") insets \(list.viewportInsets) height \(list.bounds.height)")
        }
        return findings
    }

    /// Loaded rows with a positive visible area whose content has not shown.
    func unreadyVisibleRows(_ list: UltraListView) -> [String] {
        list.loadedIndexRange.compactMap { index in
            guard let frame = list.settledFrame(at: index), let view = list.loadedItemView(at: index), !view.isDisplayReady else { return nil }
            let visible = frame.intersection(CGRect(origin: .zero, size: list.bounds.size))
            return visible.isNull || visible.width <= 0 || visible.height <= 0 ? nil : "\(index):\(list.items[index].identity)"
        }
    }

    static func firstMismatch(_ model: [DemoListRow], _ items: [any ListRow]) -> String? {
        if model.count != items.count { return "model \(model.count) list \(items.count)" }
        for (index, (expected, actual)) in zip(model, items).enumerated() where expected.identity != actual.identity || expected.revision != actual.revision {
            return "index \(index) model \(expected.identity)#\(expected.revision) list \(actual.identity)#\(actual.revision)"
        }
        return nil
    }

    /// The reservation rule stated by the list: a top attachment reserves at the start
    /// of its run, a bottom one at the end.
    private func reserves(_ items: [any ListRow], _ index: Int, width: Double) -> (top: Double, bottom: Double) {
        var top = 0.0, bottom = 0.0
        for (key, attachment) in items[index].attachments where attachment.reservesSpace {
            let previous = index > 0 ? items[index - 1].attachments[key] : nil
            let next = index + 1 < items.count ? items[index + 1].attachments[key] : nil
            if attachment.edge == .top, previous.map({ !$0.combines(with: attachment) }) ?? true { top += height(attachment, width: width) }
            if attachment.edge == .bottom, next.map({ !attachment.combines(with: $0) }) ?? true { bottom += height(attachment, width: width) }
        }
        return (top, bottom)
    }

    /// Demo attachments have content-independent heights, so one probe per type and width suffices.
    private func height(_ attachment: any ListAttachment, width: Double) -> Double {
        let key = "\(type(of: attachment))@\(width)"
        if let known = reserveHeights[key] { return known }
        let probe = attachment.makeView()
        attachment.apply(to: probe, transition: .immediate)
        let value = probe.update(width: width, transition: .immediate)
        reserveHeights[key] = value
        return value
    }
}
#endif
