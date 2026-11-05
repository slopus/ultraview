import Foundation
import Testing
@testable import UltraList

@Suite struct BottomGravityTests {
    /// Visible height 350; the bottom inset's top is at 370.
    let viewport = ListViewport(width: 320, height: 400, insets: .init(top: 20, bottom: 30))

    func heights(_ values: [Double]) -> (Int) -> (height: Double, top: Double, bottom: Double)? {
        { values.indices.contains($0) ? (values[$0], 0, 0) : nil }
    }
    func ys(_ window: ListWindow) -> [Double] { window.rows.map(\.y) }
    func top(_ window: ListWindow, _ index: Int) -> Double? { window.rows.first { $0.index == index }?.y }

    @Test func shortContentRestsOnTheBottomInset() {
        let window = ListWindow.buildGravity(count: 3, anchor: .end, viewport: viewport, clamps: true, measure: heights([50, 50, 50]))
        #expect(ys(window) == [220, 270, 320])
        let edges = window.gravityEdges(origin: 0, count: 3, viewport: viewport)
        #expect(edges.minimum == -220 && edges.maximum == -220)
        // A short window anchored anywhere comes to rest on the bottom inset.
        let anchored = ListWindow.buildGravity(count: 3, anchor: .row(index: 0, y: 20), viewport: viewport, clamps: true, measure: heights([50, 50, 50]))
        #expect(ys(anchored) == [220, 270, 320])
        // Without clamping it stays where the anchor put it.
        let held = ListWindow.buildGravity(count: 3, anchor: .row(index: 0, y: 20), viewport: viewport, clamps: false, measure: heights([50, 50, 50]))
        #expect(ys(held) == [20, 70, 120])
        #expect(held.distanceBelowBottom(count: 3, viewport: viewport) == -200)
    }

    @Test func tallContentOpensOnItsEnd() {
        let window = ListWindow.buildGravity(count: 20, anchor: .end, viewport: viewport, clamps: true, measure: heights(Array(repeating: 50, count: 20)))
        #expect(window.range == 9..<20)
        #expect(window.minY == -180 && window.maxY == 370)
        let edges = window.gravityEdges(origin: 0, count: 20, viewport: viewport)
        #expect(edges.minimum == nil && edges.maximum == 180)
        #expect(window.distanceBelowBottom(count: 20, viewport: viewport) == 0)
        let partial = ListWindow(rows: [.init(index: 3, y: 0, height: 50), .init(index: 4, y: 50, height: 50)])
        #expect(partial.gravityEdges(origin: 0, count: 10, viewport: viewport) == .init(minimum: nil, maximum: nil))
        #expect(partial.distanceBelowBottom(count: 10, viewport: viewport) == nil)
        #expect(ListWindow().gravityEdges(origin: 5, count: 0, viewport: viewport) == .init(minimum: 0, maximum: 0))
    }

    @Test func tallContentKeepsItsStartOnTheTopInset() {
        let window = ListWindow.buildGravity(count: 20, anchor: .row(index: 0, y: 90), viewport: viewport, clamps: true, measure: heights(Array(repeating: 50, count: 20)))
        #expect(top(window, 0) == 20)
    }

    @Test func changesBelowTheAnchorDoNotMoveIt() {
        var values = Array(repeating: 50.0, count: 20)
        let stopped = BottomFollow(budget: 44, phase: .stopped)
        let before = GravityPass.resolve(count: 20, anchor: .row(index: 5, y: 100), viewport: viewport, clamps: true, follow: stopped, measure: heights(values))
        #expect(before.window.range == 0..<15)
        #expect(top(before.window, 0) == -150 && top(before.window, 14) == 550)
        values[8] = 120
        let grown = GravityPass.resolve(count: 20, anchor: .row(index: 5, y: 100), viewport: viewport, clamps: true, follow: stopped, measure: heights(values))
        #expect(top(grown.window, 5) == 100)
        #expect(top(grown.window, 9) == 370)
        #expect(grown.moved == 0 && grown.followed == 0 && !grown.atBottom)
        // The anchor itself grows downward from its top.
        values[5] = 300
        let anchorGrew = GravityPass.resolve(count: 20, anchor: .row(index: 5, y: 100), viewport: viewport, clamps: true, follow: stopped, measure: heights(values))
        #expect(top(anchorGrew.window, 5) == 100 && top(anchorGrew.window, 6) == 400)
    }

    @Test func changesAboveTheAnchorAreCompensated() {
        // Three older rows arrive at the top; the old row 5 is row 8 now.
        let values = [80.0, 90, 70] + Array(repeating: 50.0, count: 20)
        let pass = GravityPass.resolve(count: 23, anchor: .row(index: 8, y: 100), viewport: viewport, clamps: true,
                                       follow: BottomFollow(budget: 44, phase: .stopped), measure: heights(values))
        #expect(top(pass.window, 8) == 100 && top(pass.window, 7) == 50)
        #expect(pass.moved == 0)
        // A collapsed row above it doesn't move it either.
        var collapsed = Array(repeating: 50.0, count: 20); collapsed[2] = 0
        let collapse = GravityPass.resolve(count: 20, anchor: .row(index: 5, y: 100), viewport: viewport, clamps: true,
                                           follow: BottomFollow(budget: 44, phase: .stopped), measure: heights(collapsed))
        #expect(top(collapse.window, 5) == 100 && top(collapse.window, 2) == 0 && top(collapse.window, 1) == -50)
    }

    @Test func followingSpendsTheBudgetThenStops() {
        var values = Array(repeating: 50.0, count: 20)
        var follow = BottomFollow(budget: 44)
        // At the bottom, row 13 sits at the top inset.
        values[19] = 80
        let first = GravityPass.resolve(count: 20, anchor: .row(index: 13, y: 20), viewport: viewport, clamps: true, follow: follow, measure: heights(values))
        #expect(first.followed == 30 && first.moved == 30 && first.atBottom)
        #expect(top(first.window, 13) == -10 && first.window.maxY == 370)
        follow.record(moved: first.moved, atBottom: first.atBottom)
        #expect(follow.isFollowing && follow.drift == 30 && follow.remaining == 14)
        values[19] = 110
        let second = GravityPass.resolve(count: 20, anchor: .row(index: 13, y: -10), viewport: viewport, clamps: true, follow: follow, measure: heights(values))
        #expect(second.followed == 14 && second.moved == 14 && !second.atBottom)
        #expect(second.window.distanceBelowBottom(count: 20, viewport: viewport) == 16)
        follow.record(moved: second.moved, atBottom: second.atBottom)
        #expect(follow.phase == .stopped && follow.remaining == 0)
        values[19] = 140
        let third = GravityPass.resolve(count: 20, anchor: .row(index: 13, y: -24), viewport: viewport, clamps: true, follow: follow, measure: heights(values))
        #expect(third.followed == 0 && third.moved == 0 && top(third.window, 13) == -24)
        follow.arm()
        #expect(follow.isFollowing && follow.drift == 0 && follow.remaining == 44)
    }

    @Test func shrinkingAtTheBottomGivesBudgetBack() {
        var values = Array(repeating: 50.0, count: 20)
        var follow = BottomFollow(budget: 44)
        follow.record(moved: 30, atBottom: true)
        values[19] = 60
        // Row 19 sat at 290 with height 80; now its end is 20 points above the line.
        let pass = GravityPass.resolve(count: 20, anchor: .row(index: 13, y: -10), viewport: viewport, clamps: true, follow: follow, measure: heights(values))
        #expect(pass.moved == -20 && pass.followed == 0 && pass.atBottom)
        #expect(top(pass.window, 13) == 10)
        follow.record(moved: pass.moved, atBottom: pass.atBottom)
        #expect(follow.drift == 10 && follow.remaining == 34)
        // A change that returns within the frame is net zero.
        follow.record(moved: 25, atBottom: true); follow.record(moved: -25, atBottom: true)
        #expect(follow.drift == 10)
        follow.record(moved: -50, atBottom: true)
        #expect(follow.drift == 0)
    }

    @Test func shortContentCrossingTheViewportCountsItsRise() {
        var follow = BottomFollow(budget: 44)
        // Three 100-point rows rest on the inset at 70, 170 and 270.
        let rest = ListWindow.buildGravity(count: 3, anchor: .end, viewport: viewport, clamps: true, measure: heights([100, 100, 100]))
        #expect(ys(rest) == [70, 170, 270])
        // Still short: gravity lifts the whole conversation.
        let short = GravityPass.resolve(count: 3, anchor: .row(index: 0, y: 70), viewport: viewport, clamps: true, follow: follow, measure: heights([100, 100, 150]))
        #expect(short.moved == 50 && short.followed == 0 && short.atBottom && ys(short.window) == [20, 120, 220])
        follow.record(moved: short.moved, atBottom: short.atBottom)
        #expect(follow.isFollowing && follow.remaining == 0)
        // Past the viewport: the start rests on the top inset and nothing follows.
        let tall = GravityPass.resolve(count: 3, anchor: .row(index: 0, y: 20), viewport: viewport, clamps: true, follow: follow, measure: heights([100, 100, 200]))
        #expect(tall.moved == 0 && tall.followed == 0 && !tall.atBottom)
        #expect(tall.window.distanceBelowBottom(count: 3, viewport: viewport) == 50)
        // A fresh budget crossing in one pass: the rise to the top inset is spent first.
        let crossing = GravityPass.resolve(count: 3, anchor: .row(index: 0, y: 70), viewport: viewport, clamps: true,
                                           follow: BottomFollow(budget: 44), measure: heights([100, 100, 200]))
        #expect(crossing.moved == 50 && crossing.followed == 0 && ys(crossing.window) == [20, 120, 220])
        let roomy = GravityPass.resolve(count: 3, anchor: .row(index: 0, y: 70), viewport: viewport, clamps: true,
                                        follow: BottomFollow(budget: 80), measure: heights([100, 100, 200]))
        #expect(roomy.moved == 80 && roomy.followed == 30 && !roomy.atBottom && ys(roomy.window) == [-10, 90, 190])
    }

    @Test func aFingerHoldsTheFollow() {
        var follow = BottomFollow(budget: 44)
        follow.record(moved: 10, atBottom: true)
        follow.hold()
        #expect(!follow.isFollowing && follow.distance(toward: 30) == 0 && follow.remaining == 34)
        // Content resting on an edge while held still counts.
        follow.record(moved: 4, atBottom: false)
        #expect(follow.phase == .held && follow.drift == 14)
        follow.release(atBottom: true)
        #expect(follow.isFollowing && follow.remaining == 30)
        follow.hold(); follow.release(atBottom: false)
        #expect(follow.phase == .stopped)
        follow.hold(); follow.release(atBottom: true)
        #expect(follow.phase == .stopped)
        follow.arm()
        #expect(follow.distance(toward: 100) == 44 && follow.distance(toward: 100, after: 40) == 4 && follow.distance(toward: -5) == 0)
        #expect(ListBottomGravity.lines(lineHeight: 24).followBudget == 48)
        #expect(ListBottomGravity(followBudget: -3).followBudget == 0 && ListBottomGravity(followBudget: .nan).followBudget == 0)
    }

    @Test func theTouchedRowIsTheAnchor() {
        let window = ListWindow(rows: (0...4).map { WindowRow(index: $0, y: Double($0) * 50, height: 50) })
        #expect(GravityPass.survivor(in: window, base: 0, offset: 0, topInset: 20, touchY: 120) { _ in true }?.index == 2)
        #expect(GravityPass.survivor(in: window, base: 0, offset: 0, topInset: 20, touchY: 120) { $0 != 2 }?.index == 0)
        #expect(GravityPass.survivor(in: window, base: 0, offset: 0, topInset: 20, touchY: nil) { _ in true }?.index == 0)
        #expect(GravityPass.survivor(in: window, base: 0, offset: 40, topInset: 20, touchY: nil) { _ in true }?.index == 1)
        #expect(GravityPass.survivor(in: window, base: 0, offset: 40, topInset: 20, touchY: nil) { $0 < 1 }?.index == 0)
        // Overscrolled by 30: the finger at 120 is on what shows there.
        #expect(GravityPass.survivor(in: window, base: 0, offset: -30, topInset: 20, touchY: 120) { _ in true }?.index == 1)
        #expect(GravityPass.survivor(in: .init(), base: 0, offset: 0, topInset: 0, touchY: 10) { _ in true } == nil)
    }

    @Test func aHeldWindowKeepsOverscrollInsteadOfResting() {
        var values = Array(repeating: 50.0, count: 20)
        values[19] = 20
        let anchor = GravityAnchor.row(index: 13, y: 20)
        let held = GravityPass.resolve(count: 20, anchor: anchor, viewport: viewport, clamps: false,
                                       follow: BottomFollow(budget: 44, phase: .held), measure: heights(values))
        #expect(held.moved == 0 && top(held.window, 13) == 20 && held.window.distanceBelowBottom(count: 20, viewport: viewport) == -30)
        let resting = GravityPass.resolve(count: 20, anchor: anchor, viewport: viewport, clamps: true,
                                          follow: BottomFollow(budget: 44, phase: .held), measure: heights(values))
        #expect(resting.moved == -30 && top(resting.window, 13) == 50 && resting.atBottom)
    }

    @Test func aWidthChangeKeepsTheShareAboveTheTopInset() {
        #expect(GravityAnchor.row(index: 0, y: -40, fraction: 0.4, height: 100).resolveY(200) == -80)
        #expect(GravityAnchor.end.resolveY(200) == nil)
    }

    @Test func followingFindsAnEndItHasNotLoaded() {
        let values = Array(repeating: 50.0, count: 20)
        let pass = GravityPass.resolve(count: 20, anchor: .row(index: 0, y: 20), viewport: viewport, clamps: true,
                                       follow: BottomFollow(budget: .infinity), measure: heights(values))
        #expect(pass.followed >= 200 && pass.atBottom && pass.window.maxY == 370 && pass.window.range == 9..<20)
        let limited = GravityPass.resolve(count: 1000, anchor: .row(index: 500, y: 0), viewport: viewport, clamps: true,
                                          follow: BottomFollow(budget: 44), measure: { _ in (50, 0, 0) })
        #expect(limited.followed == 44 && top(limited.window, 500) == -44 && !limited.atBottom)
        let missing = GravityPass.resolve(count: 3, anchor: .row(index: 1, y: 0), viewport: viewport, clamps: true,
                                          follow: BottomFollow(budget: 44), measure: { _ in nil })
        #expect(missing.window.rows.isEmpty && missing.moved == 0 && !missing.atBottom)
    }

    @Test func newRowsAreRevealedWholeOutsideTheBudget() {
        // Row 13 is the first shown, at the top inset; row 19 ends on the bottom inset.
        func pass(_ added: [Double], reveal: Bool) -> GravityPass {
            let values = Array(repeating: 50.0, count: 20) + added
            return GravityPass.resolve(count: values.count, anchor: .row(index: 13, y: 20), viewport: viewport, clamps: true,
                                       follow: BottomFollow(budget: 44), reveal: reveal ? 20 : nil, measure: heights(values))
        }
        let budgeted = pass([60], reveal: false)
        #expect(budgeted.followed == 44 && !budgeted.atBottom && !budgeted.revealed)
        let shown = pass([60], reveal: true)
        #expect(shown.followed == 60 && shown.atBottom && shown.revealed && shown.window.maxY == 370)
        // Taller than the visible height: its top stops on the top inset.
        let tall = pass([500], reveal: true)
        #expect(tall.followed == 350 && top(tall.window, 20) == 20 && !tall.atBottom)
        // Several new rows: the first one's top.
        let several = pass([100, 300], reveal: true)
        #expect(several.followed == 350 && top(several.window, 20) == 20 && top(several.window, 21) == 120)
        // A list that isn't following leaves them below.
        let values = Array(repeating: 50.0, count: 20) + [60]
        let stopped = GravityPass.resolve(count: 21, anchor: .row(index: 13, y: 20), viewport: viewport, clamps: true,
                                          follow: BottomFollow(budget: 44, phase: .stopped), reveal: 20, measure: heights(values))
        #expect(stopped.followed == 0 && !stopped.revealed && top(stopped.window, 20) == 370)
    }
}
