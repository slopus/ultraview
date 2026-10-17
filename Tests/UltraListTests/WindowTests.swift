import Foundation
import Testing
@testable import UltraList

@Suite struct WindowTests {
    let viewport = ListViewport(width: 320, height: 400, insets: .init(top: 20, bottom: 30))
    func measure(_ index: Int) -> (height: Double, top: Double, bottom: Double)? { (Double(20 + index % 5 * 10), 0, 0) }
    @Test func underfillTopWinsAndReservesStack() {
        let window = ListWindow.build(count: 2, anchor: 1, viewport: viewport, pinsLoadedTop: true, measure: { _ in (40, 10, 5) }, resolveY: { _ in 300 })
        #expect(window.minY == 20)
        #expect(window.rows[1].y == window.rows[0].maxY + 15)
        #expect(window.height == 110)
        let edges = window.edges(origin: 0, count: 2, viewport: viewport)
        #expect(edges.clamped(100) == -20)
    }
    @Test func measurementFrontierIsOpen() {
        let window = ListWindow.build(count: 100, anchor: 40, viewport: viewport, measure: { index in (38...42).contains(index) ? (50, 0, 0) : nil }, resolveY: { _ in 100 })
        #expect(window.range == 38..<43)
        #expect(window.edges(origin: -125, count: 100, viewport: viewport) == .init())
        let unavailable = ListWindow.build(count: 10, anchor: 5, viewport: viewport, measure: { _ in nil }, resolveY: { _ in 0 })
        #expect(unavailable.rows.isEmpty)
    }
    @Test func rebalanceDoesNotMoveASurvivor() {
        var window = ListWindow.build(count: 10_000, anchor: 500, viewport: viewport, measure: measure, resolveY: { _ in 20 })
        let old = window
        let oldOrigin = ScrollCore.containerOrigin(height: old.height, topLoaded: false, bottomLoaded: false)
        let oldBase = oldOrigin - old.minY, offset = oldBase + 100
        window.rebalance(count: 10_000, offsetInFrameSpace: offset - oldBase, viewportHeight: 400, measure: measure)
        let newOrigin = ScrollCore.containerOrigin(height: window.height, topLoaded: false, bottomLoaded: false)
        let newBase = newOrigin - window.minY, shiftedOffset = offset + newBase - oldBase
        let shared = window.rows.first { row in old.rows.contains { $0.index == row.index } }!
        #expect(abs(newBase + shared.y - shiftedOffset - (oldBase + shared.y - offset)) < 1e-10)
        #expect(window.rows.count < 40)
    }
    @Test func slackClampsAndDoesNotDependOnLatch() {
        let window = ListWindow(rows: [.init(index: 0, y: 0, height: 100), .init(index: 1, y: 100, height: 60)])
        #expect(window.pinSlack(index: 1, viewport: viewport) == 190)
        let tall = ListWindow(rows: [.init(index: 0, y: 0, height: 620), .init(index: 1, y: 620, height: 60)])
        #expect(tall.pinSlack(index: 1, viewport: viewport) == 0)
    }
    @Test func diffMovesAndIdentityReuses() {
        let diff = ItemDiff(old: ["a", "b", "c", "d"], new: ["a", "c", "b", "d"])
        #expect(diff.moves.count == 1)
        #expect(diff.inserts.count == 1 && diff.deletes.count == 1)
        for index in 0..<4 { #expect(diff.survivingIndex(for: index) != nil) }
        let replaced = ItemDiff(old: [1, 2, 3], new: [4, 5])
        #expect(replaced.survivors.isEmpty)
        #expect(replaced.inserts == [0, 1]); #expect(replaced.deletes == [0, 1, 2])
    }
    @Test func cacheRejectsStaleCompletionAndDeduplicates() {
        let cache = MeasurementCache(), key = MeasurementKey(identity: "a", width: 300)
        let ticket = cache.request(key)!
        #expect(cache.request(key) == nil)
        cache.invalidate()
        #expect(!cache.complete(key, height: 100, ticket: ticket))
        let fresh = cache.request(key)!
        #expect(cache.complete(key, height: 120, ticket: fresh))
        #expect(cache.height(for: key) == 120)
        #expect(cache.height(for: .init(identity: "a", width: 301)) == nil)
        #expect(MeasurementCache.priority(count: 5, anchor: 2, direction: -1, limit: 5) == [2, 1, 3, 0, 4])
    }
    @Test func schedulerDoesNotDropDirtyOnDeferredPass() {
        var scheduler = PassScheduler()
        let first = scheduler.mark("a", animated: false), second = scheduler.mark("b", animated: true)
        #expect(first && !second)
        scheduler.beginFlush()
        #expect(scheduler.dirty == ["a", "b"])
        #expect(scheduler.animated)
        let dirty = scheduler.consume()
        #expect(dirty == ["a", "b"] && scheduler.dirty.isEmpty)
    }
}

@Suite struct AnimationTests {
    @Test(arguments: [ListCurve.linear, .easeInOut, .easeIn, .spring, .uiKitScroll, .smoothDeceleration, .bezier(0, 0, 0, 1)])
    func curvesAreContinuous(curve: ListCurve) {
        #expect(abs(curve.value(at: 0)) < 1e-10)
        #expect(abs(curve.value(at: 1) - 1) < 1e-5)
        var last = 0.0
        for index in 1...1000 {
            let value = curve.value(at: Double(index) / 1000)
            #expect(value >= last - 1e-10); #expect(value - last < 0.1)
            last = value
        }
    }
    @Test func interruptedTrackAndStaleCompletion() {
        var model = ListAnimationModel()
        let transition = ListTransition(duration: 1, curve: .linear)
        let first = model.replace(.row("a"), .height, from: 40, to: 100, at: 0, transition: transition)!
        #expect(model.value(.row("a"), .height, at: 0.5) == 70)
        let second = model.transition(.row("a"), .height, old: 100, new: 200, resume: 68, at: 0.5, transition: transition)!
        #expect(second.from == 68)
        let stale = model.finish(.init(.row("a"), .height), generation: first.generation)
        #expect(!stale)
        #expect(model.value(.row("a"), .height, at: 0.5) == 68)
    }
    @Test func noOpPreservesTrackAndZeroDurationIsImmediate() {
        var model = ListAnimationModel()
        let first = model.replace(.viewport, .viewportOffset, from: 100, to: 0, at: 0, transition: .easeInOut(1))!
        let unchanged = model.transition(.viewport, .viewportOffset, old: 20, new: 20, at: 0.5, transition: .easeInOut(2))
        #expect(unchanged == first)
        let immediate = model.replace(.viewport, .viewportOffset, from: 200, to: 0, at: 0.5, transition: .easeInOut(0))
        #expect(immediate == nil)
        #expect(model.value(.viewport, .viewportOffset, at: 0.5) == 0)
    }
    @Test func equalEndpointsHaveAnalyticDeadline() {
        var model = ListAnimationModel()
        let track = model.replace(.exit(1), .opacity, from: 1, to: 1, at: 10, transition: .easeInOut(0.5))!
        #expect(model.completed(at: 10.49).isEmpty)
        #expect(model.completed(at: 10.5).first?.1 == track.generation)
    }
    @Test func scrollCurveMatchesPublicShape() {
        var error = 0.0
        for index in 0...1000 {
            let x = Double(index) / 1000
            error = max(error, abs(ListCurve.uiKitScroll.value(at: x) - pow(sin(x * .pi / 2), 2)))
        }
        #expect(error < 0.00021)
    }
}