import Foundation

/// Where a pass without an explicit target builds its window: on the row held
/// pinned to the bottom edge, on the top the content rests on, or on the
/// surviving row the user was looking at, which keeps its place on screen.
/// A pass and a check that predicts its window before it applies read the
/// same answer.
struct PreservedWindowAnchor: Sendable, Equatable {
    /// The row the window is built from, in the new collection.
    let index: Int
    /// Whether the window rests on the top of the content.
    let pinsTop: Bool
    /// Whether a window that reaches the first row starts at the top inset.
    let pinsLoadedTop: Bool
    /// The pinned row's slack before the pass, when the anchor is above it.
    let slackBaseline: Double?
    let viewport: ListViewport
    let pinnedIndex: Int?
    private let pinned: Bool
    private let fixed: Double
    private let compensation: Double
    private let additionalDistance: Double
    /// How much of the survivor was above the reading edge, and its height
    /// then, when a resize keeps that share of it above the edge.
    private let fraction: Double
    private let survivorHeight: Double

    /// `survivor` is a row of `oldWindow`, and `survivorNewIndex` its index in
    /// the new collection; give both or neither. `pinnedIndex` is the new
    /// collection's, and `atTop` whether the old offset rested on its top edge.
    /// With `keepsReadingPosition`, for a change of width, a survivor cut
    /// by the reading edge (the screen's top, or the top inset when
    /// `automatic` is false) keeps the same share of its height above that
    /// edge at its new height, so the line being read stays about where it
    /// was; otherwise its top keeps its place.
    init(oldWindow: ListWindow, oldBase: Double, oldSettled: Double, oldViewport: ListViewport, newViewport: ListViewport,
         oldSlack: Double, pinnedIndex: Int?, holdsPinnedRow: Bool, survivor: WindowRow?, survivorNewIndex: Int?,
         atTop: Bool, automatic: Bool, additionalDistance: Double, compensates: Bool, keepsReadingPosition: Bool = false) {
        precondition((survivor == nil) == (survivorNewIndex == nil))
        let top = !holdsPinnedRow && automatic && atTop && additionalDistance == 0
        let anchor: Int
        if holdsPinnedRow, let pinnedIndex { anchor = pinnedIndex }
        else if top { anchor = 0 }
        else { anchor = survivorNewIndex ?? 0 }
        let updatedSlack = oldWindow.pinSlack(index: pinnedIndex, viewport: newViewport)
        index = anchor; pinsTop = top
        pinsLoadedTop = top || (oldWindow.rows.isEmpty && !holdsPinnedRow)
        slackBaseline = !holdsPinnedRow && anchor < (pinnedIndex ?? -1) ? updatedSlack : nil
        viewport = newViewport
        self.pinnedIndex = pinnedIndex
        pinned = holdsPinnedRow && anchor == pinnedIndex
        fixed = survivor.map { oldBase + $0.y - oldSettled } ?? newViewport.insets.top
        compensation = compensates ? newViewport.insets.top - oldViewport.insets.top + updatedSlack - oldSlack : 0
        self.additionalDistance = additionalDistance
        if keepsReadingPosition, !top, !pinned, let survivor, survivor.height > 0 {
            let edge = automatic ? 0 : oldViewport.insets.top
            fraction = min(1, max(0, (edge - fixed) / survivor.height))
            survivorHeight = survivor.height
        } else {
            fraction = 0; survivorHeight = 0
        }
    }

    /// The anchor row's top on screen, given its height.
    func resolveY(_ height: Double) -> Double {
        if pinned {
            return viewport.insets.top + viewport.visibleHeight + max(0, height - viewport.visibleHeight / 2) - height + additionalDistance
        }
        return fixed + fraction * (survivorHeight - height) + compensation + additionalDistance
    }

    func window(count: Int, margin: Double, measure: (Int) -> (height: Double, top: Double, bottom: Double)?) -> ListWindow {
        ListWindow.build(count: count, anchor: index, viewport: viewport, margin: margin, pinnedIndex: pinnedIndex,
                         pinsLoadedTop: pinsLoadedTop, slackBaseline: slackBaseline, measure: measure) { resolveY($0) }
    }

    /// The row of `window` a pass keeps in place: the first one showing below
    /// the top of the screen, or below the top inset when `automatic` is
    /// false, that survives into the new collection. Otherwise the nearest
    /// surviving row below it, then above it. With `automatic`, a visible
    /// row that leaves gives way to the nearest surviving row above it.
    /// `survives` takes an old index.
    static func survivor(in window: ListWindow, base: Double, settled: Double, topInset: Double, automatic: Bool,
                         survives: (Int) -> Bool) -> WindowRow? {
        let threshold = settled + (automatic ? 0 : topInset)
        let visible = window.rows.firstIndex { base + $0.maxY > threshold } ?? max(0, window.rows.count - 1)
        let order = Array(window.rows.dropFirst(visible)) + Array(window.rows.prefix(visible).reversed())
        var survivor = order.first { survives($0.index) }
        if automatic, window.rows.indices.contains(visible), !survives(window.rows[visible].index) {
            survivor = window.rows.prefix(visible).reversed().first { survives($0.index) } ?? survivor
        }
        return survivor
    }
}

/// Where a built window goes in the scroll coordinate, and the offset the
/// pass moves to. `containerOrigin` is the engine's origin for the window;
/// the platform engine keeps an untargeted window under its settled offset.
struct WindowPlacement: Sendable, Equatable {
    let window: ListWindow
    let count: Int
    let viewport: ListViewport
    let origin: Double
    /// The scroll offset at which the window's coordinates are screen points.
    let base: Double
    let edges: ScrollEdges
    let destination: Double

    init(newWindow: ListWindow, count: Int, viewport: ListViewport, pinnedIndex: Int?, oldWindowIsEmpty: Bool,
         platformCoordinates: Bool, hasTarget: Bool, oldOrigin: Double, oldOffset: Double, oldSettled: Double,
         oldOverscroll: Double, displaces: Bool, moves: Bool, absorbsOverscroll: Bool, containerOrigin: Double) {
        window = newWindow; self.count = count; self.viewport = viewport
        origin = platformCoordinates && !hasTarget && !oldWindowIsEmpty ? oldSettled + newWindow.minY : containerOrigin
        base = origin - newWindow.minY
        edges = newWindow.edges(origin: origin, count: count, viewport: viewport, pinnedIndex: pinnedIndex)
        var destination = base
        if !hasTarget && (!moves || displaces) && (oldOverscroll == 0 || displaces) { destination = edges.clamped(destination) }
        if !hasTarget { destination = absorbsOverscroll ? oldOffset + origin - oldOrigin : destination + oldOverscroll }
        self.destination = destination
    }

    /// Rows on the physical screen at `destination`, including those behind
    /// the insets.
    var physicalRows: [WindowRow] {
        window.rows.filter { base + $0.maxY - destination > 0 && base + $0.y - destination < viewport.height }
    }

    /// The rows just past the window's ends where the screen would show past
    /// them: their measurements are missing.
    var uncoveredIndices: [Int] {
        var result: [Int] = []
        if window.range.lowerBound > 0, base + window.minY - destination > 0.5 { result.append(window.range.lowerBound - 1) }
        if window.range.upperBound < count, base + window.maxY - destination < viewport.height - 0.5 { result.append(window.range.upperBound) }
        return result
    }
}
