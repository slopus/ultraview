import Foundation

/// A list that reads from its end, like a chat: rows keep their natural order,
/// the first (oldest) at the top and the last (newest) at the bottom. Content
/// shorter than the viewport rests on the bottom inset, with the space above
/// it empty, and the list opens on its last row.
///
/// Nothing the person is reading moves because content changed, except in
/// four cases. A list resting on its bottom edge shows complete new rows
/// at its end whole, and follows a streaming row (`ListRow.isStreaming`) and
/// growth at its end only by `followBudget` points in total. While its last
/// row pins to the bottom edge (`ListRow.pinsToBottomEdge`, the person's
/// own message), it keeps that row on the bottom inset whatever grows above
/// it. Content shorter than the viewport always rests on the bottom inset.
/// See `BottomFollow` for when the budget is spent and when it is filled
/// again.
public struct ListBottomGravity: Sendable, Equatable {
    /// How far, in points, the list moves its content up by itself to follow
    /// a streaming row and growth at its end, before it stops and lets them
    /// continue below the bottom inset. About two lines of body text is
    /// enough to show that something new started. `.infinity` follows
    /// without limit.
    public var followBudget: Double

    public init(followBudget: Double = 44) {
        self.followBudget = followBudget.isNaN ? 0 : max(0, followBudget)
    }

    /// A budget of `count` lines at `lineHeight` points each.
    public static func lines(_ count: Double = 2, lineHeight: Double) -> Self {
        .init(followBudget: count * lineHeight)
    }
}

/// The new rows one change brings to a bottom-gravity list's end: a run of
/// new rows that ends at the last row, or directly above rows that were
/// already the list's last ones (a footer the host keeps under its newest
/// message).
public struct GravityArrival: Sendable, Equatable {
    /// The first new row of the run.
    public var first: Int
    /// The last row a following pass shows outside the budget: the list's
    /// last row when the run ends with a complete row, otherwise the last
    /// complete new row; nil when every new row streams.
    public var revealsThrough: Int?
    /// Whether a new row streams. Its appearance and growth spend a fresh
    /// budget.
    public var streams: Bool

    public init(first: Int, revealsThrough: Int?, streams: Bool) {
        self.first = first; self.revealsThrough = revealsThrough; self.streams = streams
    }

    /// Finds the run in a collection of `count` rows that had `oldCount`.
    /// `identity` and `oldIdentity` name rows by index, `isNew` tells rows
    /// that weren't in the old collection, and `streams` rows whose content
    /// is still arriving. Looks only at the rows at the end.
    public static func find(count: Int, oldCount: Int, identity: (Int) -> String, oldIdentity: (Int) -> String,
                            isNew: (Int) -> Bool, streams: (Int) -> Bool) -> GravityArrival? {
        var kept = 0
        while kept < count, kept < oldCount, identity(count - 1 - kept) == oldIdentity(oldCount - 1 - kept) { kept += 1 }
        let last = count - 1 - kept
        guard last >= 0, isNew(last) else { return nil }
        var first = last
        while first > 0, isNew(first - 1) { first -= 1 }
        // Above kept rows, the run must open where they were attached; new
        // rows above every old row are older history.
        if kept > 0, first == 0 || oldCount - 1 - kept < 0 || identity(first - 1) != oldIdentity(oldCount - 1 - kept) { return nil }
        let streaming = (first...last).contains(where: streams)
        let lastComplete = (first...last).last { !streams($0) }
        return .init(first: first, revealsThrough: lastComplete.map { $0 == last ? count - 1 : $0 }, streams: streaming)
    }
}

/// Whether a bottom-gravity list follows growth at its end, and how much of
/// its budget it has left. The list owns one and feeds it these events:
///
/// - `arm()`: the list came to rest on its bottom edge because the person
///   scrolled there, or the host scrolled to the bottom (`scrollToBottom`, a
///   `.bottom` target, a target that lands on the bottom edge), or a new
///   streaming row arrived at the end while the list was following. The
///   budget is full again. Complete new rows neither fill nor spend it,
///   and neither does keeping a pinned last row on the bottom inset.
/// - `hold()`: a finger touched the list. Nothing follows while it is down.
/// - `release(atBottom:)`: the finger lifted without scrolling. A held list
///   follows again with what was left of its budget, but only if it is still
///   on its bottom edge. A tap doesn't refill the budget.
/// - `stop()`: a drag began, or the host asked to stop. Only `arm()` resumes.
/// - `record(moved:atBottom:)`: after every pass, with how far the content
///   moved up by itself (following, or resting on an edge) and whether it
///   rests on the bottom edge. Moving down gives budget back.
public struct BottomFollow: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case following, held, stopped }
    public private(set) var phase: Phase
    /// How far the content has moved up by itself since `arm()`, net of the
    /// distance it moved back down. Never negative.
    public private(set) var drift: Double = 0
    public var budget: Double

    public init(budget: Double, phase: Phase = .following) {
        self.budget = budget; self.phase = phase
    }

    public var isFollowing: Bool { phase == .following }
    /// What the list may still follow. Zero once it stopped.
    public var remaining: Double { phase == .stopped ? 0 : max(0, budget - drift) }

    public mutating func arm() { phase = .following; drift = 0 }
    public mutating func stop() { phase = .stopped }
    public mutating func hold() { if phase == .following { phase = .held } }
    public mutating func release(atBottom: Bool) {
        guard phase == .held else { return }
        phase = atBottom ? .following : .stopped
    }

    /// How far past the anchored placement a following pass scrolls toward
    /// the bottom: up to `needed`, the distance the content's end lies below
    /// the bottom inset, and within what is left after the pass already moved
    /// the content up by `forced` to rest on an edge.
    public func distance(toward needed: Double, after forced: Double = 0) -> Double {
        guard isFollowing, needed > 0 else { return 0 }
        return min(needed, max(0, remaining - max(0, forced)))
    }

    public mutating func record(moved: Double, atBottom: Bool) {
        guard phase != .stopped else { return }
        drift = max(0, drift + moved)
        if phase == .following, !atBottom { phase = .stopped }
    }
}

/// The row a bottom-gravity pass keeps in place, or the list's end.
public enum GravityAnchor: Sendable, Equatable {
    /// Row `index` of the new collection has its top at `y` on screen (at the
    /// settled offset). With a `fraction`, a row that was `height` tall keeps
    /// that share of its new height above where it was cut.
    case row(index: Int, y: Double, fraction: Double = 0, height: Double = 0)
    /// The last row rests on the bottom inset.
    case end

    /// The row the window is built from, in a collection of `count` rows.
    func index(count: Int) -> Int {
        if case .row(let index, _, _, _) = self { return index }
        return count - 1
    }

    func resolveY(_ height: Double) -> Double? {
        guard case let .row(_, y, fraction, previous) = self else { return nil }
        return y + fraction * (previous - height)
    }
}

extension ListViewport {
    /// Where the content's end rests: the top of the bottom inset.
    public var bottomLine: Double { height - insets.bottom }
}

extension ListWindow {
    /// How far the content's end lies below the bottom inset, in the
    /// window's screen coordinates; `nil` while the last row isn't loaded.
    public func distanceBelowBottom(count: Int, viewport: ListViewport) -> Double? {
        guard !rows.isEmpty, range.upperBound == count else { return nil }
        return maxY - viewport.bottomLine
    }

    /// Scroll edges for bottom gravity. With both ends loaded and the content
    /// no taller than the visible height, both edges rest the end on the
    /// bottom inset.
    public func gravityEdges(origin: Double, count: Int, viewport: ListViewport) -> ScrollEdges {
        guard !rows.isEmpty else { return .init(minimum: 0, maximum: 0) }
        let maximum = range.upperBound == count ? origin + height + viewport.insets.bottom - viewport.height : nil
        var minimum = range.lowerBound == 0 ? origin - viewport.insets.top : nil
        if let top = minimum, let maximum { minimum = min(top, maximum) }
        return .init(minimum: minimum, maximum: maximum)
    }

    /// The translation that rests a window on its edges under bottom gravity:
    /// a short collection's end on the bottom inset, a tall one's end no
    /// higher than the bottom inset and its start no lower than the top inset.
    func gravityCorrection(count: Int, viewport: ListViewport) -> Double {
        guard !rows.isEmpty else { return 0 }
        let start = range.lowerBound == 0, end = range.upperBound == count
        if start, end, height <= viewport.visibleHeight { return viewport.bottomLine - maxY }
        if end, maxY < viewport.bottomLine { return viewport.bottomLine - maxY }
        if start, minY > viewport.insets.top { return viewport.insets.top - minY }
        return 0
    }

    /// Builds a window around `anchor` and fills `margin` points beyond the
    /// viewport each way. With `clamps`, the window then rests on its edges
    /// (`gravityCorrection`); without, it stays where the anchor put it,
    /// which a drag or a flight turns into overscroll. `lift` then moves the
    /// window up by that many points. Missing measurements leave that edge
    /// open, as in `build`.
    public static func buildGravity(count: Int, anchor: GravityAnchor, viewport: ListViewport, margin: Double = 160, clamps: Bool,
                                    lift: Double = 0, measure: (Int) -> (height: Double, top: Double, bottom: Double)?) -> ListWindow {
        buildGravity(count: count, anchorIndex: anchor.index(count: count), viewport: viewport, margin: margin, clamps: clamps,
                     lift: lift, measure: measure) { height, reservedBottom in
            anchor.resolveY(height) ?? viewport.bottomLine - reservedBottom - height
        }
    }

    /// `buildGravity` around row `anchorIndex`, whose top `resolveY` places
    /// from its height and the space it reserves below itself.
    static func buildGravity(count: Int, anchorIndex index: Int, viewport: ListViewport, margin: Double = 160, clamps: Bool,
                             lift: Double = 0, measure: (Int) -> (height: Double, top: Double, bottom: Double)?,
                             resolveY: (Double, Double) -> Double) -> ListWindow {
        guard index >= 0, index < count, viewport.contentWidth > 0, viewport.height > 0,
              let measured = measure(index) else { return .init() }
        func row(_ index: Int, _ y: Double, _ m: (height: Double, top: Double, bottom: Double)) -> WindowRow {
            precondition(m.height.isFinite && m.height >= 0 && m.top >= 0 && m.bottom >= 0)
            return WindowRow(index: index, y: y, height: m.height, reservedTop: m.top, reservedBottom: m.bottom)
        }
        let y = resolveY(measured.height, measured.bottom)
        var result = ListWindow(rows: [row(index, y, measured)])
        func fill() {
            while result.minY > -margin, let first = result.rows.first, first.index > 0, let m = measure(first.index - 1) {
                result.rows.insert(row(first.index - 1, first.bandTop - m.bottom - m.height, m), at: 0)
            }
            while result.maxY < viewport.height + margin, let last = result.rows.last, last.index + 1 < count, let m = measure(last.index + 1) {
                result.rows.append(row(last.index + 1, last.bandBottom + m.top, m))
            }
        }
        fill()
        if clamps {
            // Each translation can load rows that change the next one; a
            // window settles within a few rounds.
            for _ in 0..<4 {
                let correction = result.gravityCorrection(count: count, viewport: viewport)
                guard abs(correction) > 1e-9 else { break }
                result.translate(by: correction); fill()
            }
        }
        // Following lifts the rested window; it never lifts the end above
        // the bottom inset, so the window stays on its edges.
        if lift != 0 { result.translate(by: -lift); fill() }
        return result
    }
}

/// One bottom-gravity pass: the window it builds and what it did to the
/// follow budget.
public struct GravityPass: Sendable, Equatable {
    public let window: ListWindow
    /// How far the anchor ended above where it was asked to be: what the
    /// list moved the content up by itself, following its end or resting
    /// on an edge. Negative when the content moved down. Zero for `.end`.
    public let moved: Double
    /// The part of `moved` that followed growth at the end.
    public let followed: Double
    /// Whether the content's end rests on the bottom inset.
    public let atBottom: Bool
    /// The part of `followed` that showed complete new rows or kept a
    /// pinned last row on the bottom inset, outside the budget.
    public let revealed: Double

    /// Builds the window around `anchor`, resting it on its edges when
    /// `clamps`, then follows the end within `follow`'s budget. With an
    /// `arrival` whose rows reveal, a following pass first follows outside
    /// the budget until the end of row `revealsThrough` rests on the bottom
    /// inset, or the first new row's top reaches the top inset, whichever
    /// comes first; only in the first case does the budget cover the rest.
    /// With `pinsEnd` (the last row pins to the bottom edge), a following
    /// pass rests the end on the bottom inset outside the budget, however
    /// far that is and whatever arrived.
    public static func resolve(count: Int, anchor: GravityAnchor, viewport: ListViewport, margin: Double = 160, clamps: Bool,
                               follow: BottomFollow, arrival: GravityArrival? = nil, pinsEnd: Bool = false,
                               measure: (Int) -> (height: Double, top: Double, bottom: Double)?) -> GravityPass {
        func build(_ lift: Double) -> ListWindow {
            ListWindow.buildGravity(count: count, anchor: anchor, viewport: viewport, margin: margin, clamps: clamps, lift: lift, measure: measure)
        }
        var window = build(0)
        let index = anchor.index(count: count)
        func top(_ window: ListWindow) -> Double? { window.rows.first { $0.index == index }?.y }
        guard let placed = window.rows.first(where: { $0.index == index }) else {
            return .init(window: window, moved: 0, followed: 0, atBottom: false, revealed: 0)
        }
        // Where the anchor was asked to be, at the height it has now.
        let intended = anchor.resolveY(placed.height) ?? placed.y
        let forced = intended - placed.y
        var followed = 0.0, revealed = 0.0
        if follow.isFollowing {
            // Where the anchor sits when the end rests on the bottom inset.
            var ended: ListWindow?
            func endTop() -> Double? {
                if ended == nil {
                    ended = ListWindow.buildGravity(count: count, anchor: .end, viewport: viewport, margin: margin, clamps: true, measure: measure)
                }
                return ended.flatMap(top)
            }
            for _ in 0..<8 {
                let needed: Double
                if let below = window.distanceBelowBottom(count: count, viewport: viewport) { needed = below + followed }
                else if let current = top(window), let end = endTop() { needed = current - end + followed }
                else if follow.remaining.isInfinite || pinsEnd, let ended, !ended.rows.isEmpty {
                    // Too far to measure, and nothing limits the follow.
                    followed += window.maxY - viewport.bottomLine
                    window = ended; break
                } else {
                    // The end lies at least this far below; following that
                    // far loads more of the way there.
                    needed = window.maxY - viewport.bottomLine + followed
                }
                var total: Double
                if pinsEnd {
                    total = needed
                } else if let arrival, let through = arrival.revealsThrough {
                    // Rows not loaded yet lie below: following further loads them.
                    let room = window.rows.first { $0.index == arrival.first }.map { max(0, $0.y - viewport.insets.top) } ?? .infinity
                    let shown = window.rows.first { $0.index == through }.map { $0.y + $0.height - viewport.bottomLine + followed } ?? needed
                    let reach = max(0, min(needed, shown))
                    if followed + room < reach {
                        total = followed + room; revealed = total
                    } else {
                        revealed = reach
                        total = reach + follow.distance(toward: needed - reach, after: forced)
                    }
                } else {
                    total = follow.distance(toward: needed, after: forced)
                }
                guard total - followed > 1e-9 else { break }
                followed = total
                window = build(followed)
            }
        }
        if pinsEnd { revealed = followed }
        let moved = anchor == .end ? 0 : top(window).map { intended - $0 } ?? forced + followed
        let atBottom = window.distanceBelowBottom(count: count, viewport: viewport).map { abs($0) <= 0.5 } ?? false
        return .init(window: window, moved: moved, followed: followed, atBottom: atBottom, revealed: min(revealed, followed))
    }

    /// The row a bottom-gravity pass keeps in place: the surviving row under
    /// the finger while one is down (`touchY`, in screen points), otherwise
    /// the first surviving row showing below the top inset, then the nearest
    /// surviving row below it, then above it. `offset` is the scroll offset
    /// the screen shows, `base` the offset at which the window's coordinates
    /// are screen points. `survives` takes an old index.
    public static func survivor(in window: ListWindow, base: Double, offset: Double, topInset: Double, touchY: Double?,
                                survives: (Int) -> Bool) -> WindowRow? {
        if let touchY, let touched = window.rows.first(where: { row in
            base + row.bandTop - offset <= touchY && touchY < base + row.bandBottom - offset
        }), survives(touched.index) { return touched }
        let visible = window.rows.firstIndex { base + $0.maxY - offset > topInset } ?? max(0, window.rows.count - 1)
        let order = Array(window.rows.dropFirst(visible)) + Array(window.rows.prefix(visible).reversed())
        return order.first { survives($0.index) }
    }
}
