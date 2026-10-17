#if canImport(UIKit)
import UIKit
import QuartzCore
import UltraView

/// Presses on demo content, so tests can tell a tap that selects from one that doesn't.
@MainActor
enum DemoSelections {
    static var events: [String] = []
    /// Whether each touch on a carousel landed while it was moving.
    static var carouselTouches: [Bool] = []
    static var movingCarousels: Set<String> = []
}

/// Opt-in per-frame measurements of swipe actions and nested horizontal lists,
/// exported as JSON in an accessibility value for the interaction tests.
@MainActor
final class ListSwipeProbe: NSObject {
    private weak var owner: UIView?
    private weak var list: UltraListView?
    private let report = UILabel()
    private var link: CADisplayLink?
    private var frames = 0
    private var performed: [String] = []
    private var removed: [String] = []
    private var revealFrames = 0, maximumButtonDetach = 0.0
    private var maximumRevealOffset = 0.0
    private struct Departure {
        weak var view: UIView?
        var identity: String
        var gapAbove: Double
        var gapBelow: Double
        var deadline: Double
        var above: String?
        var below: String?
    }
    /// The first departure, per frame: seconds since removal, ghost top and height, the
    /// bottom of the row above and the top of the row below, all in the visible content space.
    private var departureTrace: [[Double]] = []
    private var departures: [Departure] = []
    private var deleteFrames = 0, ghostFrames = 0
    private var maximumNeighborDrift = 0.0, maximumSeamError = 0.0, maximumGhostButtonDetach = 0.0
    private var worstSeam: [String: Double] = [:]
    private var worstDrift: [String: Any] = [:]
    private var maximumOffscreenDrift = 0.0
    /// Turns that ran while a finger or an animation moved rows, buttons or a carousel.
    private var turns: [Double] = []
    private var allTurns = 0
    private var slowest: [(milliseconds: Double, notes: [String])] = []
    private var activeUntil = 0.0
    /// The probe's own sampling, subtracted from the turns it ran in.
    private var probeIntervals: [(start: Double, end: Double)] = []
    private var rawTurns: [Double] = []
    private var hostActions: [String: Double] = [:]
    private var carouselPositions: [String: Double] = [:]
    private var initialMainWork = 0
    private var previousTurn: ((MainThreadMonitor.Turn) -> Void)?

    init(owner: UIView, list: UltraListView) {
        self.owner = owner; self.list = list
        super.init()
        report.frame = .init(x: 0, y: 0, width: 1, height: 1)
        report.text = " "; report.accessibilityLabel = "Swipe probe"
        report.accessibilityIdentifier = "swipeProbe"; report.isAccessibilityElement = true
        owner.addSubview(report)
        initialMainWork = Diagnostics.shared.counts.mainThreadWork
        previousTurn = MainThreadMonitor.shared.onTurn
        // Launch and first layout aren't interaction; turns count from here.
        let recordFrom = CACurrentMediaTime() + 1.5
        MainThreadMonitor.shared.onTurn = { [weak self] turn in
            guard let self else { return }
            previousTurn?(turn)
            guard turn.startTime >= recordFrom else { return }
            allTurns += 1
            // UI automation's accessibility snapshots run on main between gestures; they aren't swiping.
            guard turn.startTime <= activeUntil else { return }
            let end = turn.startTime + turn.milliseconds / 1000
            let probe = probeIntervals.reduce(0.0) { $0 + max(0, min(end, $1.end) - max(turn.startTime, $1.start)) }
            probeIntervals.removeAll { $0.end <= end }
            let net = max(0, turn.milliseconds - probe * 1000)
            rawTurns.append(turn.milliseconds); turns.append(net)
            if slowest.count < 5 || net > slowest[slowest.count - 1].milliseconds {
                slowest.append((net, Array(turn.notes.prefix(6))))
                slowest.sort { $0.milliseconds > $1.milliseconds }
                if slowest.count > 5 { slowest.removeLast() }
            }
        }
        let link = CADisplayLink(target: self, selector: #selector(sample))
        link.add(to: .main, forMode: .common); self.link = link
    }
    func stop() { link?.invalidate(); link = nil }
    func record(_ event: String) { performed.append(event) }
    /// Times a host action on main, such as the list update a delete makes.
    func measure<Result>(_ name: String, _ body: () -> Result) -> Result {
        let start = CACurrentMediaTime()
        defer { hostActions[name] = max(hostActions[name] ?? 0, (CACurrentMediaTime() - start) * 1000) }
        return body()
    }

    /// Called before the host removes a row, while its view still has its old neighbours.
    func willRemove(_ identity: String, action: String) {
        performed.append("\(action):\(identity)"); removed.append(identity)
        guard let list, let index = list.loadedIndexRange.first(where: { list.items[$0].identity == identity }),
              let view = list.loadedItemView(at: index) else { return }
        let rect = modelRect(view)
        let neighbours = rows(excluding: identity).map { ($0.identity, modelRect($0.view)) }
        let above = neighbours.filter { $0.1.maxY <= rect.minY + 0.5 }.max { $0.1.maxY < $1.1.maxY }
        let below = neighbours.filter { $0.1.minY >= rect.maxY - 0.5 }.min { $0.1.minY < $1.1.minY }
        departures.append(.init(view: view, identity: identity, gapAbove: above.map { rect.minY - $0.1.maxY } ?? 0, gapBelow: below.map { $0.1.minY - rect.maxY } ?? 0,
                                deadline: CACurrentMediaTime() + 0.8, above: above?.0, below: below?.0))
    }

    private var space: CALayer? { list.map { $0.contentView.layer.presentation() ?? $0.contentView.layer } }
    private func modelRect(_ view: UIView) -> CGRect {
        guard let list else { return .zero }
        return view.layer.convert(view.layer.bounds, to: list.contentView.layer)
    }
    private func presentedRect(_ view: UIView) -> CGRect? {
        guard let list, let space, let layer = view.layer.presentation() else { return nil }
        // A container the list made this turn has no presentation yet; converting through it reads stale geometry.
        var ancestor = view.layer.superlayer
        while let current = ancestor, current !== list.contentView.layer {
            guard current.presentation() != nil else { return nil }
            ancestor = current.superlayer
        }
        return layer.convert(layer.bounds, to: space)
    }
    private func rows(excluding identity: String? = nil) -> [(identity: String, view: ListRowView)] {
        guard let list else { return [] }
        return list.loadedIndexRange.compactMap { index in
            let id = list.items[index].identity
            guard id != identity, let view = list.loadedItemView(at: index) else { return nil }
            return (id, view)
        }
    }
    /// How far the shown buttons are from covering exactly the uncovered part of the row.
    private func buttonDetach(_ view: UIView) -> (offset: Double, error: Double)? {
        guard let layer = view.layer.presentation() else { return nil }
        let offset = Double(layer.sublayerTransform.m41)
        let buttons = (layer.sublayers ?? []).filter { $0.name?.hasPrefix("swipe:") == true }
        guard abs(offset) > 0.5, !buttons.isEmpty else { return nil }
        let width = Double(layer.bounds.width)
        let spans = buttons.map { button -> (Double, Double) in
            let shown = button.presentation() ?? button
            let minX = Double(shown.position.x) + offset
            return (minX, minX + Double(shown.bounds.width))
        }.sorted { $0.0 < $1.0 }
        // Merge the spans; any hole or a union not matching the uncovered area is detachment.
        var union = spans[0], error = 0.0
        for span in spans.dropFirst() {
            if span.0 > union.1 + 0.01 { error = max(error, span.0 - union.1) }
            union = (union.0, max(union.1, span.1))
        }
        let expected = offset < 0 ? (width + offset, width) : (0, offset)
        error = max(error, abs(union.0 - expected.0), abs(union.1 - expected.1))
        return (offset, error)
    }

    /// Whether anything the probe measures is moving: a tracked finger, a reveal
    /// spring, a departing row or a carousel.
    private func interacting(_ list: UltraListView) -> Bool {
        if list.isTracking || list.isDragging || list.isScrollFlightActive || !departures.isEmpty { return true }
        if list.gestureRecognizers?.contains(where: { $0.state == .began || $0.state == .changed }) == true { return true }
        for index in list.loadedIndexRange {
            guard let view = list.loadedItemView(at: index) else { continue }
            if view.layer.animationKeys()?.contains(where: { $0.hasPrefix("ultraview.") }) == true { return true }
            if let carousel = view as? DemoCarouselView {
                let inner = carousel.horizontal.list
                if inner.isTracking || inner.isScrollFlightActive || inner.contentView.layer.animationKeys()?.isEmpty == false { return true }
            }
        }
        return false
    }

    @objc private func sample() {
        let started = CACurrentMediaTime()
        defer {
            probeIntervals.append((started, CACurrentMediaTime()))
            MainThreadMonitor.shared.note("swipe probe sample \((CACurrentMediaTime() - started) * 1000) ms")
        }
        guard let list, owner?.window != nil else { return }
        frames += 1
        let now = CACurrentMediaTime()
        // The turn that delivered a frame of motion and the next one both count.
        if interacting(list) { activeUntil = now + 0.05 }
        for index in list.loadedIndexRange {
            guard let carousel = list.loadedItemView(at: index) as? DemoCarouselView else { continue }
            let identity = list.items[index].identity, position = carousel.position
            if let previous = carouselPositions[identity], abs(previous - position) > 0.05 { DemoSelections.movingCarousels.insert(identity) }
            else { DemoSelections.movingCarousels.remove(identity) }
            carouselPositions[identity] = position
        }
        if let identity = list.swipeActions.revealedIdentity,
           let index = list.loadedIndexRange.first(where: { list.items[$0].identity == identity }),
           let view = list.loadedItemView(at: index), let detach = buttonDetach(view) {
            revealFrames += 1
            maximumButtonDetach = max(maximumButtonDetach, detach.error)
            maximumRevealOffset = max(maximumRevealOffset, abs(detach.offset))
        }
        departures.removeAll { $0.deadline < now || $0.view == nil }
        for departure in departures {
            guard let ghost = departure.view, let ghostRect = presentedRect(ghost) else { continue }
            deleteFrames += 1
            if let detach = buttonDetach(ghost) { maximumGhostButtonDetach = max(maximumGhostButtonDetach, detach.error) }
            if departure.identity == removed.first {
                let origin = (list.contentView.layer.presentation() ?? list.contentView.layer).bounds.minY
                func shown(_ identity: String?) -> CGRect? { rows().first { $0.identity == identity }.flatMap { presentedRect($0.view) } }
                departureTrace.append([now - departure.deadline + 0.8, ghostRect.minY - origin, ghostRect.height,
                                       (shown(departure.above)?.maxY ?? .nan) - origin, (shown(departure.below)?.minY ?? .nan) - origin].map { ($0 * 100).rounded() / 100 })
            }
            let survivors = rows(excluding: departure.identity).compactMap { row -> (identity: String, model: CGRect, shown: CGRect)? in
                presentedRect(row.view).map { (row.identity, modelRect(row.view), $0) }
            }.sorted { $0.shown.minY < $1.shown.minY }
            for (a, b) in zip(survivors, survivors.dropFirst()) {
                let straddles = ghostRect.midY > a.shown.midY && ghostRect.midY < b.shown.midY
                let shownGap = b.shown.minY - a.shown.maxY
                if straddles, ghostRect.height > 0.5 {
                    ghostFrames += 1
                    let above = abs(ghostRect.minY - a.shown.maxY - departure.gapAbove)
                    let below = abs(b.shown.minY - ghostRect.maxY - departure.gapBelow)
                    if max(above, below) > maximumSeamError {
                        maximumSeamError = max(above, below)
                        worstSeam = ["above": above, "below": below, "ghostTop": ghostRect.minY, "ghostHeight": ghostRect.height, "previousBottom": a.shown.maxY, "nextTop": b.shown.minY]
                    }
                } else if !straddles {
                    let drift = abs(shownGap - (b.model.minY - a.model.maxY))
                    // Only seams on screen count; rows in the preload band are reported separately.
                    let viewport = (list.contentView.layer.presentation() ?? list.contentView.layer).bounds
                    let visible = a.shown.maxY < viewport.maxY && b.shown.minY > viewport.minY
                    if !visible { maximumOffscreenDrift = max(maximumOffscreenDrift, drift) }
                    else if drift > maximumNeighborDrift {
                        maximumNeighborDrift = drift
                        worstDrift = ["above": a.identity, "below": b.identity, "shownGap": shownGap, "modelGap": b.model.minY - a.model.maxY,
                                      "seamY": a.shown.maxY - viewport.minY, "sinceRemoval": now - departure.deadline + 0.8]
                    }
                }
            }
        }
        guard frames % 6 == 0 || !departures.isEmpty else { return }
        publish()
    }

    private func publish() {
        guard let list else { return }
        let anchor = list.loadedIndexRange.first(where: { (list.settledFrame(at: $0)?.maxY ?? 0) > 0 })
        var carousels: [String: Double] = [:], rowFrames: [String: [Double]] = [:]
        for index in list.loadedIndexRange {
            guard let view = list.loadedItemView(at: index) else { continue }
            let identity = list.items[index].identity
            if let carousel = view as? DemoCarouselView { carousels[identity] = carousel.position }
            let rect = view.convert(view.bounds, to: nil).intersection(list.convert(list.bounds, to: nil))
            if !rect.isNull, rect.height > 20 { rowFrames[identity] = [rect.minX, rect.minY, rect.width, rect.height] }
        }
        let sorted = turns.sorted()
        var document: [String: Any] = [
            "frames": frames, "rows": list.items.count, "performed": performed, "removed": removed,
            "revealed": list.swipeActions.revealedIdentity ?? "", "revealFrames": revealFrames,
            "maximumRevealOffset": maximumRevealOffset, "buttonDetach": maximumButtonDetach,
            "deleteFrames": deleteFrames, "ghostFrames": ghostFrames, "neighborDrift": maximumNeighborDrift,
            "seamError": maximumSeamError, "ghostButtonDetach": maximumGhostButtonDetach, "worstSeam": worstSeam, "worstDrift": worstDrift, "offscreenDrift": maximumOffscreenDrift, "departureTrace": departureTrace.map { $0.map { $0.isNaN ? -9999 : $0 } },
            "carousels": carousels, "rowFrames": rowFrames, "hostActions": hostActions,
            "rawTurnP99": rawTurns.isEmpty ? 0 : rawTurns.sorted()[Int(Double(rawTurns.count - 1) * 0.99)], "selections": DemoSelections.events, "carouselTouches": DemoSelections.carouselTouches, "turns": sorted.count,
            "turnP99": sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.99)], "turnMax": sorted.last ?? 0,
            "allTurns": allTurns, "slowestTurns": slowest.map { ["milliseconds": $0.milliseconds, "notes": $0.notes] as [String: Any] },
            "mainThreadWork": Diagnostics.shared.counts.mainThreadWork - initialMainWork,
        ]
        if let anchor, let frame = list.settledFrame(at: anchor) {
            document["anchor"] = list.items[anchor].identity; document["anchorY"] = frame.minY
        }
        if let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]) {
            report.accessibilityValue = String(decoding: data, as: UTF8.self)
        }
    }
}
#endif
