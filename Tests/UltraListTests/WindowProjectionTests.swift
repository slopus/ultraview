import Foundation
import Testing
@testable import UltraList

@Suite struct WindowProjectionTests {
    let viewport = ListViewport(width: 320, height: 400, insets: .init(top: 20, bottom: 30))

    func rows(_ indices: ClosedRange<Int>, from y: Double, height: Double) -> ListWindow {
        ListWindow(rows: indices.enumerated().map { WindowRow(index: $0.element, y: y + Double($0.offset) * height, height: height) })
    }

    func anchor(oldWindow: ListWindow, oldBase: Double = 0, oldSettled: Double = 0, oldViewport: ListViewport? = nil,
                newViewport: ListViewport? = nil, oldSlack: Double = 0, pinnedIndex: Int? = nil, holdsPinnedRow: Bool = false,
                survivor: WindowRow? = nil, survivorNewIndex: Int? = nil, atTop: Bool = false, automatic: Bool = true,
                additionalDistance: Double = 0, compensates: Bool = true, keepsReadingPosition: Bool = false) -> PreservedWindowAnchor {
        PreservedWindowAnchor(oldWindow: oldWindow, oldBase: oldBase, oldSettled: oldSettled, oldViewport: oldViewport ?? viewport,
                              newViewport: newViewport ?? viewport, oldSlack: oldSlack, pinnedIndex: pinnedIndex,
                              holdsPinnedRow: holdsPinnedRow, survivor: survivor, survivorNewIndex: survivorNewIndex, atTop: atTop,
                              automatic: automatic, additionalDistance: additionalDistance, compensates: compensates,
                              keepsReadingPosition: keepsReadingPosition)
    }

    func place(_ window: ListWindow, count: Int, viewport: ListViewport? = nil, pinnedIndex: Int? = nil, oldWindowIsEmpty: Bool = false,
               platform: Bool = false, hasTarget: Bool = false, oldOrigin: Double = 0, oldOffset: Double = 0, oldSettled: Double = 0,
               oldOverscroll: Double = 0, displaces: Bool = false, moves: Bool = false, absorbs: Bool = false,
               containerOrigin: Double) -> WindowPlacement {
        WindowPlacement(newWindow: window, count: count, viewport: viewport ?? self.viewport, pinnedIndex: pinnedIndex,
                        oldWindowIsEmpty: oldWindowIsEmpty, platformCoordinates: platform, hasTarget: hasTarget, oldOrigin: oldOrigin,
                        oldOffset: oldOffset, oldSettled: oldSettled, oldOverscroll: oldOverscroll, displaces: displaces, moves: moves,
                        absorbsOverscroll: absorbs, containerOrigin: containerOrigin)
    }

    @Test func theRowShowingAtTheTopIsTheSurvivor() {
        let window = rows(0...4, from: 0, height: 50)
        func survivor(settled: Double = 60, inset: Double = 20, automatic: Bool = true, _ survives: (Int) -> Bool) -> Int? {
            PreservedWindowAnchor.survivor(in: window, base: 0, settled: settled, topInset: inset, automatic: automatic, survives: survives)?.index
        }
        #expect(survivor { _ in true } == 1)
        // Automatic anchoring gives a departing row's place to the row above it.
        #expect(survivor { $0 != 1 } == 0)
        #expect(survivor { $0 > 1 } == 2)
        // Preserving visible content counts the top inset and looks below first.
        #expect(survivor(automatic: false) { $0 != 1 } == 2)
        #expect(survivor(inset: 50, automatic: false) { _ in true } == 2)
        #expect(survivor(settled: 1000) { _ in true } == 4)
        #expect(survivor { _ in false } == nil)
        #expect(PreservedWindowAnchor.survivor(in: .init(), base: 0, settled: 0, topInset: 0, automatic: true) { _ in true } == nil)
    }

    @Test func aWidthChangeKeepsTheShareOfTheReadRowAboveTheEdge() {
        // Row 5 is 100 tall and shows from -40: 40% of it is above the top.
        let old = ListWindow(rows: [WindowRow(index: 4, y: 0, height: 60), WindowRow(index: 5, y: 60, height: 100),
                                    WindowRow(index: 6, y: 160, height: 80)])
        let narrow = ListViewport(width: 200, height: 400, insets: .init(top: 20, bottom: 30))
        func resolved(_ keeps: Bool, automatic: Bool = true, settled: Double = 100) -> PreservedWindowAnchor {
            anchor(oldWindow: old, oldSettled: settled, newViewport: narrow, survivor: old.rows[1], survivorNewIndex: 5,
                   automatic: automatic, keepsReadingPosition: keeps)
        }
        // Taller at the new width: 40% of 150 stays above the edge.
        #expect(resolved(true).resolveY(150) == -60)
        #expect(resolved(true).resolveY(100) == -40)
        #expect(resolved(true).resolveY(50) == -20)
        // Without it, the row's top keeps its place.
        #expect(resolved(false).resolveY(150) == -40)
        // Preserving visible content reads from the top inset: 60% above it.
        #expect(resolved(true, automatic: false).resolveY(150) == 20 - 0.6 * 150)
        // A row wholly below the edge keeps its top.
        #expect(resolved(true, settled: 50).resolveY(150) == 10)
        // A list resting on its top stays there.
        let top = anchor(oldWindow: old, oldSettled: 100, newViewport: narrow, survivor: old.rows[1], survivorNewIndex: 5,
                         atTop: true, keepsReadingPosition: true)
        #expect(top.pinsTop)
    }

    @Test func aSurvivorKeepsItsScreenPositionAcrossInsetsAndDistance() {
        let old = rows(4...9, from: 0, height: 50)
        let moved = ListViewport(width: 320, height: 400, insets: .init(top: 50, bottom: 30))
        func resolved(compensates: Bool, distance: Double = 0) -> PreservedWindowAnchor {
            anchor(oldWindow: old, oldBase: 1000, oldSettled: 1080, newViewport: moved, survivor: old.rows[1], survivorNewIndex: 6,
                   additionalDistance: distance, compensates: compensates)
        }
        // Row 5 showed at 1000 + 50 - 1080; the top inset grew by 30.
        #expect(resolved(compensates: false).resolveY(80) == -30)
        #expect(resolved(compensates: true).resolveY(80) == 0)
        #expect(resolved(compensates: true, distance: 7).resolveY(80) == 7)
        let result = resolved(compensates: true)
        #expect(result.index == 6)
        #expect(!result.pinsTop && !result.pinsLoadedTop && result.slackBaseline == nil)
    }

    @Test func restingOnTheTopPinsTheFirstRowUnlessSomethingMovesIt() {
        let old = rows(0...6, from: 20, height: 50)
        func resolved(holds: Bool = false, automatic: Bool = true, distance: Double = 0) -> PreservedWindowAnchor {
            anchor(oldWindow: old, pinnedIndex: holds ? 9 : nil, holdsPinnedRow: holds, survivor: old.rows[2], survivorNewIndex: 3,
                   atTop: true, automatic: automatic, additionalDistance: distance)
        }
        #expect(resolved().index == 0 && resolved().pinsTop && resolved().pinsLoadedTop)
        #expect(resolved(distance: 5).index == 3 && !resolved(distance: 5).pinsTop)
        #expect(resolved(automatic: false).index == 3 && !resolved(automatic: false).pinsTop)
        #expect(resolved(holds: true).index == 9 && !resolved(holds: true).pinsLoadedTop)
    }

    @Test func aHeldPinnedRowRestsOnTheBottomEdge() {
        let old = rows(5...9, from: 0, height: 50)
        let held = anchor(oldWindow: old, pinnedIndex: 9, holdsPinnedRow: true, survivor: old.rows[0], survivorNewIndex: 5)
        // Visible height 350: a short row ends at 370; a tall one extends past
        // the screen by its part beyond half the visible height.
        #expect(held.index == 9)
        #expect(held.resolveY(100) == 270)
        #expect(held.resolveY(300) == 195)
        let moved = anchor(oldWindow: old, pinnedIndex: 9, holdsPinnedRow: true, survivor: old.rows[0], survivorNewIndex: 5, additionalDistance: 4)
        #expect(moved.resolveY(100) == 274)
        // Holding without a pinned row in the collection falls back to the survivor.
        let unpinned = anchor(oldWindow: old, oldBase: 0, oldSettled: -10, holdsPinnedRow: true, survivor: old.rows[0], survivorNewIndex: 5)
        #expect(unpinned.index == 5 && unpinned.resolveY(100) == 10)
    }

    @Test func aRowAboveThePinnedRowCarriesItsSlack() {
        let old = rows(0...3, from: 0, height: 50)
        // Row 3 ends 200 below the top of the content: 350 - 200 of slack.
        #expect(old.pinSlack(index: 3, viewport: viewport) == 150)
        let above = anchor(oldWindow: old, oldBase: 0, oldSettled: -20, oldSlack: 100, pinnedIndex: 3, survivor: old.rows[1], survivorNewIndex: 1)
        #expect(above.slackBaseline == 150)
        #expect(above.resolveY(50) == 120)
        let below = anchor(oldWindow: old, pinnedIndex: 3, survivor: old.rows[1], survivorNewIndex: 5)
        #expect(below.slackBaseline == nil)
        let held = anchor(oldWindow: old, pinnedIndex: 3, holdsPinnedRow: true, survivor: old.rows[1], survivorNewIndex: 1)
        #expect(held.slackBaseline == nil)
    }

    @Test func aFirstWindowStartsAtTheTopInset() {
        let first = anchor(oldWindow: .init())
        #expect(first.index == 0 && first.pinsLoadedTop && !first.pinsTop)
        #expect(first.resolveY(60) == 20)
        #expect(!anchor(oldWindow: .init(), pinnedIndex: 4, holdsPinnedRow: true).pinsLoadedTop)
    }

    @Test func theProjectedWindowKeepsTheSurvivorOverNewHeightsAbove() {
        let screen = ListViewport(width: 320, height: 300, insets: .init(top: 60, bottom: 100))
        let old = rows(3...9, from: 0, height: 60)
        let survivor = PreservedWindowAnchor.survivor(in: old, base: 500, settled: 590, topInset: 60, automatic: true) { _ in true }
        #expect(survivor?.index == 4)
        let projected = anchor(oldWindow: old, oldBase: 500, oldSettled: 590, oldViewport: screen, newViewport: screen,
                               survivor: survivor, survivorNewIndex: 4)
        let window = projected.window(count: 100, margin: 160) { index in (index < 4 ? 100 : 60, 0, 0) }
        #expect(window.range == 2..<13)
        #expect(window.rows.first { $0.index == 4 }?.y == -30)
        #expect(window.rows.first?.y == -230)
        let placement = place(window, count: 100, viewport: screen,
                              containerOrigin: ScrollCore.containerOrigin(height: window.height, topLoaded: false, bottomLoaded: false))
        #expect(placement.origin == -370 && placement.base == -140 && placement.destination == -140)
        #expect(placement.edges == .init())
        #expect(placement.physicalRows.map { $0.index } == Array(4...9))
        #expect(placement.uncoveredIndices.isEmpty)
    }

    @Test(arguments: [false, true])
    func aShrinkingTopRowExposesRowsBehindTheBottomInset(platform: Bool) {
        let screen = ListViewport(width: 320, height: 300, insets: .init(top: 60, bottom: 100))
        let old = ListWindow(rows: [WindowRow(index: 0, y: 60, height: 1200)])
        let survivor = PreservedWindowAnchor.survivor(in: old, base: -60, settled: -60, topInset: 60, automatic: true) { _ in true }
        let projected = anchor(oldWindow: old, oldBase: -60, oldSettled: -60, oldViewport: screen, newViewport: screen,
                               survivor: survivor, survivorNewIndex: 0, atTop: true)
        #expect(projected.pinsTop && projected.index == 0)
        let window = projected.window(count: 80, margin: 160) { _ in (60, 0, 0) }
        #expect(window.range == 0..<7 && window.minY == 60)
        let settled = platform ? 940.0 : -60
        let placement = place(window, count: 80, viewport: screen, platform: platform, oldSettled: settled,
                              containerOrigin: ScrollCore.containerOrigin(height: window.height, topLoaded: true, bottomLoaded: false))
        #expect(placement.base == settled && placement.destination == settled)
        #expect(placement.edges.minimum == settled && placement.edges.maximum == nil)
        // Rows 1 to 3 were below the tall row; row 3 shows behind the bottom inset.
        #expect(placement.physicalRows.map { $0.index } == [0, 1, 2, 3])
    }

    @Test func anUntargetedPlacementClampsUnlessOverscrollOrMovesKeepIt() {
        let window = rows(97...99, from: 0, height: 100)
        let origin = ScrollCore.containerOrigin(height: window.height, topLoaded: false, bottomLoaded: true)
        func destination(overscroll: Double = 0, displaces: Bool = false, moves: Bool = false, absorbs: Bool = false,
                         hasTarget: Bool = false) -> Double {
            place(window, count: 100, hasTarget: hasTarget, oldOrigin: -310, oldOffset: 40, oldOverscroll: overscroll,
                  displaces: displaces, moves: moves, absorbs: absorbs, containerOrigin: origin).destination
        }
        let base = place(window, count: 100, containerOrigin: origin)
        #expect(base.origin == -300 && base.base == -300)
        #expect(base.edges == .init(minimum: nil, maximum: -370))
        // At the bottom edge the offset settles with the last row on the bottom inset.
        #expect(destination() == -370)
        #expect(destination(overscroll: 15) == -285)
        #expect(destination(overscroll: 15, displaces: true) == -355)
        #expect(destination(moves: true) == -300)
        #expect(destination(displaces: true, moves: true) == -370)
        #expect(destination(absorbs: true) == 50)
        #expect(destination(overscroll: 15, hasTarget: true) == -300)
    }

    @Test func thePlatformEngineKeepsAnUntargetedWindowUnderItsSettledOffset() {
        let window = rows(97...99, from: 0, height: 100)
        let custom = ScrollCore.containerOrigin(height: window.height, topLoaded: false, bottomLoaded: true)
        let platform = place(window, count: 100, platform: true, oldSettled: 1234, containerOrigin: custom)
        #expect(platform.origin == 1234 && platform.base == 1234)
        #expect(platform.edges.maximum == 1164 && platform.destination == 1164)
        #expect(place(window, count: 100, platform: true, hasTarget: true, oldSettled: 1234, containerOrigin: custom).origin == -300)
        #expect(place(window, count: 100, oldWindowIsEmpty: true, platform: true, oldSettled: 1234, containerOrigin: custom).origin == -300)
    }

    @Test func physicalRowsIncludeTheInsetsAndUncoveredEdgesNeedRows() {
        let tall = place(rows(10...21, from: -100, height: 50), count: 100, hasTarget: true, containerOrigin: 0)
        #expect(tall.base == 100 && tall.destination == 100)
        // Rows from 0 to 400 on screen, behind both insets too.
        #expect(tall.physicalRows.map { $0.index } == Array(12...19))
        #expect(tall.uncoveredIndices.isEmpty)
        let short = place(rows(10...15, from: 30, height: 50), count: 100, hasTarget: true, containerOrigin: 0)
        #expect(short.physicalRows.map { $0.index } == Array(10...15))
        #expect(short.uncoveredIndices == [9, 16])
        let whole = place(rows(0...5, from: 30, height: 50), count: 6, hasTarget: true, containerOrigin: 0)
        #expect(whole.uncoveredIndices.isEmpty)
    }
}
