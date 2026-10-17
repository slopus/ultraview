#if canImport(UIKit)
import UIKit
import QuartzCore
import Testing
@testable import UltraList

private struct SyncRow: ListRow {
    var identity: String
    var revision: UInt64 = 0
    var height: Double = 100
    var pinsToBottomEdge = false
    func makeView() -> ListRowView { SyncRowView() }
    func apply(to view: ListRowView, transition: ListTransition) { (view as? SyncRowView)?.height = height }
}

private final class SyncRowView: ListRowView {
    var height: Double = 100
    override func update(width: Double, transition: ListTransition) -> Double { height }
}

/// Lists in a window with their layer clock stopped, so each check reads what
/// Core Animation shows at one moment of the pass's animation.
/// `Proofs/UltraProofs/List/Pass.lean` and `Animation.lean` prove the
/// properties these regressions pin.
@MainActor
@Suite(.serialized) struct ListSyncTests {
    let window = makeWindow()

    func list(count: Int = 20) -> UltraListView {
        list((0..<count).map { SyncRow(identity: String($0)) })
    }

    fileprivate func list(_ rows: [SyncRow]) -> UltraListView {
        window.frame = .init(x: 0, y: 0, width: 320, height: 400)
        let list = UltraListView()
        list.frame = window.bounds
        window.addSubview(list); window.isHidden = false
        list.layoutIfNeeded()
        list.applyChanges(items: rows)
        list.layer.speed = 0; list.layer.timeOffset = 100
        return list
    }

    /// Where `view` is drawn in `list`, from the presentation tree at the
    /// list's stopped time.
    func shown(_ view: UIView, in list: UltraListView) async throws -> CGRect {
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(35))
        let layer = try #require(view.layer.presentation())
        let target = try #require(list.layer.presentation())
        return layer.convert(layer.bounds, to: target)
    }

    func advance(_ list: UltraListView, to time: Double) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        list.layer.timeOffset = time
        CATransaction.commit()
    }

    @Test(arguments: [false, true]) func rowsOnScreenStayLoadedThroughAnAnimatedInsetChange(relayout: Bool) async throws {
        let list = list((0..<40).map { SyncRow(identity: String($0), height: 50) })
        var before: [(Int, ListRowView, CGRect)] = []
        for index in 0..<8 {
            let view = try #require(list.loadedItemView(at: index))
            before.append((index, view, try await shown(view, in: list)))
        }
        list.applyChanges(newSize: relayout ? list.bounds.size : nil, newInsets: .init(top: 252), transition: .init(duration: 1, curve: .linear))
        for (index, view, frame) in before {
            let start = try await shown(view, in: list)
            #expect(view.superview != nil && abs(start.minY - frame.minY) < 0.5, "row \(index) was at \(frame.minY); loaded \(list.loadedIndexRange), starts at \(start.minY)")
        }
    }

    @Test func aShortPinnedListKeepsItsPinnedRowOnTheEdgeThroughAnInsetChange() throws {
        var rows = (0..<3).map { SyncRow(identity: String($0)) }
        rows[2].pinsToBottomEdge = true
        let list = list(rows)
        let before = try #require(list.settledFrame(at: 2))
        list.applyChanges(newInsets: .init(top: 100), transition: .immediate)
        let after = try #require(list.settledFrame(at: 2))
        #expect(abs(list.overscrollDistance) < 0.5 && abs(after.maxY - before.maxY) < 0.5)
    }

    @Test func anInsetAnimationFillsTheExposedViewportWithThinRows() throws {
        let list = list((0..<1000).map { SyncRow(identity: String($0), height: 1) })
        list.applyChanges(newInsets: .init(top: 252), transition: .immediate)
        list.handleScroll(list.currentScrollOffset)
        #expect(!list.loadedIndexRange.contains(399))
        list.applyChanges(newInsets: .init(top: 0), transition: .init(duration: 1, curve: .linear))
        let row = try #require(list.loadedItemView(at: 399))
        #expect(row.superview != nil)
    }

    @Test func contentAtItsEndStaysThereWhenTheTopInsetShrinks() throws {
        let list = list(count: 20)
        list.applyChanges(newInsets: .init(top: 252), transition: .immediate)
        list.scrollTo(.init(index: 19, pointOffset: 48), transition: .immediate)
        let before = try #require(list.settledFrame(at: 19))
        list.applyChanges(newInsets: .init(top: 0), transition: .immediate)
        let after = try #require(list.settledFrame(at: 19))
        #expect(abs(list.overscrollDistance) < 0.5 && abs(after.maxY - before.maxY) < 0.5)
    }

    @Test(arguments: [false, true]) func anUncompensatedInsetChangeKeepsTheOffsetAndLeavesEdgeCorrectionToTheEngine(atEnd: Bool) throws {
        let list = list(count: 20)
        list.applyChanges(newInsets: .init(top: 252), transition: .immediate)
        if atEnd { list.scrollTo(.init(index: 19, pointOffset: 48), transition: .immediate) }
        let offset = list.currentScrollOffset
        list.applyChanges(newInsets: .init(top: 0), compensatesInsetChange: false, transition: .immediate)
        #expect(list.currentScrollOffset == offset)
        #expect(abs(list.overscrollDistance - (atEnd ? 0 : -252)) < 0.5)
    }

    @Test func loadedRowsStartWhereTheyWereOnAScroll() async throws {
        let list = list()
        let row1 = try #require(list.loadedItemView(at: 1))
        let before = try await shown(row1, in: list)
        list.scrollTo(.init(index: 3), transition: .init(duration: 1, curve: .linear))
        let start = try await shown(row1, in: list)
        #expect(abs(start.minY - before.minY) < 0.5)
        advance(list, to: 100.5)
        let half = try await shown(row1, in: list)
        let settled = try #require(list.settledFrame(at: 1))
        #expect(abs(half.minY - (before.minY + settled.minY) / 2) < 0.5)
    }

    @Test func carriedRowStartsWhereItWasOnAScroll() async throws {
        let list = list()
        let row0 = try #require(list.loadedItemView(at: 0))
        let before = try await shown(row0, in: list)
        list.scrollTo(.init(index: 3), transition: .init(duration: 1, curve: .linear))
        #expect(!list.loadedIndexRange.contains(0) && row0.superview != nil)
        let start = try await shown(row0, in: list)
        advance(list, to: 100.5)
        let half = try await shown(row0, in: list)
        #expect(abs(start.minY - before.minY) < 0.5, "row 0 was at \(before.minY), starts at \(start.minY)")
        #expect(row0.superview != nil && abs(half.minY - (before.minY - 150)) < 0.5, "row 0 is at \(half.minY) halfway")
    }

    /// A size with the insets (a host relayout) takes the full pass, which rebuilds the window; its rows follow the
    /// inset change from where they were, as on the inset-only path.
    @Test func rowsFollowARelayoutWithNewInsets() async throws {
        let list = list()
        let row0 = try #require(list.loadedItemView(at: 0))
        let before = try await shown(row0, in: list)
        list.applyChanges(newSize: list.bounds.size, newInsets: .init(top: 252), transition: .init(duration: 1, curve: .linear))
        let start = try await shown(row0, in: list)
        #expect(abs(start.minY - before.minY) < 0.5, "row 0 was at \(before.minY), starts at \(start.minY)")
        advance(list, to: 100.5)
        let half = try await shown(row0, in: list)
        #expect(abs(half.minY - (before.minY + 126)) < 0.5, "row 0 is at \(half.minY) halfway")
        advance(list, to: 101)
        let end = try await shown(row0, in: list)
        #expect(abs(end.minY - (before.minY + 252)) < 0.5)
    }

    @Test func contentFollowsAnInsetChangeInOnePass() async throws {
        let list = list()
        let row0 = try #require(list.loadedItemView(at: 0))
        let before = try await shown(row0, in: list)
        list.applyChanges(newInsets: .init(top: 252), transition: .immediate)
        let after = try await shown(row0, in: list)
        #expect(abs(after.minY - (before.minY + 252)) < 0.5)
    }

    @Test func contentMovesWithAnAnimatedInsetChange() async throws {
        let list = list()
        let row0 = try #require(list.loadedItemView(at: 0))
        let before = try await shown(row0, in: list)
        list.applyChanges(newInsets: .init(top: 252), transition: .init(duration: 1, curve: .linear))
        let start = try await shown(row0, in: list)
        #expect(abs(start.minY - before.minY) < 0.5)
        advance(list, to: 100.5)
        let half = try await shown(row0, in: list)
        #expect(abs(half.minY - (before.minY + 126)) < 0.5, "row 0 was at \(before.minY), is at \(half.minY) halfway")
        advance(list, to: 101)
        let end = try await shown(row0, in: list)
        #expect(abs(end.minY - (before.minY + 252)) < 0.5)
    }

    @Test func touchingRowsKeepTouchingWhenARowGrowsMidSlide() async throws {
        let list = list(count: 10)
        var rows = (0..<10).map { SyncRow(identity: String($0)) }
        rows.insert(SyncRow(identity: "new"), at: 0)
        let linear = ListTransition(duration: 1, curve: .linear)
        list.applyChanges(items: rows, transition: linear)
        advance(list, to: 100.5)
        _ = try await shown(try #require(list.loadedItemView(at: 1)), in: list)
        rows[1].height = 150; rows[1].revision = 1
        list.applyChanges(items: rows, transition: linear)
        advance(list, to: 101)
        let upper = try #require(list.presentedFrame(at: 1)), lower = try #require(list.presentedFrame(at: 2))
        #expect(abs(upper.maxY - lower.minY) < 0.5, "upper bottom \(upper.maxY), lower top \(lower.minY)")
    }
    /// The bottom of row `index` and the top of row `index + 1` on screen, from the presentation tree.
    func seam(_ list: UltraListView, at index: Int) async throws -> (upper: Double, lower: Double, height: Double) {
        let upper = try await shown(try #require(list.loadedItemView(at: index)), in: list)
        let lower = try await shown(try #require(list.loadedItemView(at: index + 1)), in: list)
        return (upper.maxY, lower.minY, upper.height)
    }

    /// An immediate change during a slide stacks on it: rows land on their new places with the slide's remaining
    /// distance still to go, so they touch throughout (Animation.lean, `now_shifts`).
    @Test func touchingRowsKeepTouchingWhenARowGrowsImmediatelyMidSlide() async throws {
        let list = list(count: 10)
        var rows = (0..<10).map { SyncRow(identity: String($0)) }
        rows.insert(SyncRow(identity: "new"), at: 0)
        list.applyChanges(items: rows, transition: .init(duration: 1, curve: .linear))
        advance(list, to: 100.5)
        _ = try await seam(list, at: 1)
        rows[1].height = 150; rows[1].revision = 1
        list.applyChanges(items: rows, transition: .immediate)
        for time in [100.5, 100.75, 101] {
            advance(list, to: time)
            let seam = try await seam(list, at: 1)
            #expect(abs(seam.upper - seam.lower) < 0.5, "at \(time): upper bottom \(seam.upper), lower top \(seam.lower)")
        }
    }

    /// An immediate change to a row whose height is animating moves that animation with it.
    @Test func touchingRowsKeepTouchingWhenAGrowingRowChangesImmediately() async throws {
        let list = list(count: 10)
        var rows = (0..<10).map { SyncRow(identity: String($0)) }
        rows[1].height = 200; rows[1].revision = 1
        list.applyChanges(items: rows, transition: .init(duration: 1, curve: .linear))
        advance(list, to: 100.5)
        _ = try await seam(list, at: 1)
        rows[1].height = 300; rows[1].revision = 2
        list.applyChanges(items: rows, transition: .immediate)
        for time in [100.5, 100.75, 101] {
            advance(list, to: time)
            let seam = try await seam(list, at: 1)
            #expect(abs(seam.upper - seam.lower) < 0.5, "at \(time): upper bottom \(seam.upper), lower top \(seam.lower)")
            #expect(seam.height >= 0)
        }
    }

    /// Moving a growth below zero would show a negative height, so the row lands at its new height at once.
    @Test func aGrowingRowSetImmediatelyToZeroNeverHasANegativeHeight() async throws {
        let list = list(count: 10)
        var rows = (0..<10).map { SyncRow(identity: String($0)) }
        rows[1].height = 200; rows[1].revision = 1
        list.applyChanges(items: rows, transition: .init(duration: 1, curve: .linear))
        advance(list, to: 100.5)
        _ = try await seam(list, at: 1)
        rows[1].height = 0; rows[1].revision = 2
        list.applyChanges(items: rows, transition: .immediate)
        for time in [100.5, 100.75, 101] {
            advance(list, to: time)
            let seam = try await seam(list, at: 1)
            #expect(seam.height >= 0, "at \(time): height \(seam.height)")
        }
    }

    @Test func rowOnlyRetimingPreservesAnExistingViewportSpring() throws {
        let list = list(count: 10)
        list.applyChanges(newInsets: .init(top: 100), transition: .spring(1, damping: 22))
        let key = "ultraview.list.viewportOffset"
        let original = try #require(list.contentView.layer.animation(forKey: key) as? CASpringAnimation)
        advance(list, to: 100.2)
        var rows = (0..<10).map { SyncRow(identity: String($0)) }
        rows[1].height = 150; rows[1].revision = 1
        list.applyChanges(items: rows, transition: .easeInOut(0.4))
        let kept = try #require(list.contentView.layer.animation(forKey: key) as? CASpringAnimation)
        #expect(kept.beginTime == original.beginTime && kept.duration == original.duration)
        #expect(kept.stiffness == original.stiffness && kept.damping == original.damping)
    }
    @Test func rowOnlyRetimingPreservesAnExistingOpacityDeadline() throws {
        let list = list(count: 10)
        var rows = (0..<10).map { SyncRow(identity: String($0)) }
        rows.insert(SyncRow(identity: "new"), at: 0)
        list.applyChanges(items: rows, transition: .easeInOut(1))
        let inserted = try #require(list.loadedItemView(at: 0))
        let key = "ultraview.list.opacity"
        let original = try #require(inserted.layer.animation(forKey: key))
        advance(list, to: 100.2)
        rows[1].height = 150; rows[1].revision = 1
        list.applyChanges(items: rows, transition: .easeInOut(0.4))
        let kept = try #require(inserted.layer.animation(forKey: key))
        #expect(kept.beginTime == original.beginTime && kept.duration == original.duration)
    }
}
#endif
