#if canImport(UIKit)
import UIKit
import QuartzCore
import Testing
@testable import UltraList

private struct ViewportRow: ListRow {
    var identity: String
    var revision: UInt64 { 0 }
    func makeView() -> ListRowView { ViewportRowView() }
    func apply(to view: ListRowView, transition: ListTransition) {}
}
private final class ViewportRowView: ListRowView {
    override func update(width: Double, transition: ListTransition) -> Double { 100 }
}

@MainActor
@Suite(.serialized) struct ViewportTransitionTests {
    @Test(arguments: ScrollEngineMode.allCases)
    func finishingAnInsetCorrectionLandsItsPresentation(mode: ScrollEngineMode) async throws {
        let (window, list) = fixture(mode)
        defer { list.haltScrolling(); window.isHidden = true }
        list.layer.speed = 0; list.layer.timeOffset = 100
        list.applyChanges(newInsets: .init(top: 80), transition: .init(duration: 1, curve: .linear))
        CATransaction.flush(); try await Task.sleep(for: .milliseconds(35))
        list.layer.timeOffset = 100.4
        CATransaction.flush(); try await Task.sleep(for: .milliseconds(35))
        let row = try #require(list.loadedItemView(at: 10))
        let settled = try #require(list.settledFrame(at: 10))
        let shown = try #require(row.layer.presentation()), destination = try #require(list.layer.presentation())
        #expect(abs(shown.convert(shown.bounds, to: destination).minY - settled.minY + 48) < 0.5)
        let offset = list.currentScrollOffset
        list.finishViewportTransition()
        #expect(list.contentView.layer.animation(forKey: "ultraview.list.viewportOffset") == nil)
        #expect(list.viewportInsets.top == 80 && list.currentScrollOffset == offset)
        CATransaction.flush(); try await Task.sleep(for: .milliseconds(35))
        let landed = try #require(row.layer.presentation()), target = try #require(list.layer.presentation())
        #expect(abs(landed.convert(landed.bounds, to: target).minY - settled.minY) < 0.5)
    }

    @Test(arguments: ScrollEngineMode.allCases, [-600.0, 600])
    func finishingAnInsetCorrectionKeepsTheExistingFlight(mode: ScrollEngineMode, velocity: Double) async throws {
        let (window, list) = fixture(mode)
        defer { list.haltScrolling(); window.isHidden = true }
        list.beginMomentum(velocity: velocity)
        list.applyChanges(newInsets: .init(top: 80), transition: .easeInOut(0.3))
        let flight = list.engine.activeFlight, offset = list.currentScrollOffset
        let before = try #require(list.engine.coveredOffsets(horizon: 0.05))
        list.finishViewportTransition()
        #expect(list.isDecelerating && list.currentScrollOffset == offset)
        #expect(list.engine.activeFlight == flight)
        let after = try #require(list.engine.coveredOffsets(horizon: 0.05))
        #expect(abs((after.upperBound - after.lowerBound) - (before.upperBound - before.lowerBound)) < 0.5)
        try await Task.sleep(for: .milliseconds(50))
        #expect(abs(list.currentScrollOffset - offset) > 10)
        #expect(list.isDecelerating)
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func aViewportProfileAppliesOnlyToInsetPasses(mode: ScrollEngineMode) throws {
        let (window, list) = fixture(mode)
        defer { list.haltScrolling(); window.isHidden = true }
        let profile = ViewportCurve(progress: [0, 0, 0.5, 1])
        let transition = ListTransition(duration: 1, curve: .linear, viewportCurve: profile)
        list.applyChanges(newInsets: .init(top: 80), transition: transition)
        #expect(list.contentView.layer.animation(forKey: "ultraview.list.viewportOffset") is CAKeyframeAnimation)
        list.applyChanges(newInsets: .init(top: 120), scrollTo: .init(index: 15), transition: transition)
        #expect(list.contentView.layer.animation(forKey: "ultraview.list.viewportOffset") is CABasicAnimation)
        let row = try #require(list.loadedItemView(at: 15))
        #expect(!(row.layer.animation(forKey: "ultraview.list.height") is CAKeyframeAnimation))
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func finishingWithoutACorrectionDoesNothing(mode: ScrollEngineMode) throws {
        let (window, list) = fixture(mode)
        defer { list.haltScrolling(); window.isHidden = true }
        let offset = list.currentScrollOffset, frame = try #require(list.settledFrame(at: 10))
        var callbacks = 0
        list.onVisibleWindowChanged = { callbacks += 1 }
        list.finishViewportTransition(); list.finishViewportTransition()
        #expect(callbacks == 0 && list.currentScrollOffset == offset)
        #expect(list.settledFrame(at: 10) == frame && list.viewportInsets.top == 0)
        #expect(list.contentView.layer.animation(forKey: "ultraview.list.viewportOffset") == nil)
    }

    private func fixture(_ mode: ScrollEngineMode) -> (UIWindow, UltraListView) {
        let window = makeWindow()
        window.frame = .init(x: 0, y: 0, width: 320, height: 400)
        let list = UltraListView(engineMode: mode)
        list.frame = window.bounds; window.addSubview(list); window.isHidden = false
        list.layoutIfNeeded()
        list.applyChanges(items: (0..<50).map { ViewportRow(identity: String($0)) }, scrollTo: .init(index: 10), transition: .none)
        return (window, list)
    }
}
#endif