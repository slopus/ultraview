#if canImport(UIKit)
import UIKit
import Testing
@testable import UltraList

private struct SettlementRow: ListRow {
    var identity: String
    func makeView() -> ListRowView { SettlementRowView() }
    func apply(to view: ListRowView, transition: ListTransition) {}
}

private final class SettlementRowView: ListRowView {
    override func update(width: Double, transition: ListTransition) -> Double { 100 }
}

private enum RestingPath: CaseIterable { case shiftAfterEdges, sameEdges, halt, windowReentry }

@MainActor
@Suite(.serialized) struct OverscrollSettlementTests {
    @Test(arguments: ScrollEngineMode.allCases, RestingPath.allCases)
    private func restingContentReturnsAfterTheFinalGeometryWrites(mode: ScrollEngineMode, path: RestingPath) async throws {
        let window = makeWindow()
        window.frame = .init(x: 0, y: 0, width: 402, height: 604)
        let list = UltraListView(engineMode: mode)
        list.frame = window.bounds; window.addSubview(list); window.isHidden = false
        defer { list.engine.teardown(); window.isHidden = true }
        list.layoutIfNeeded()
        list.applyChanges(items: (0..<60).map { SettlementRow(identity: String($0)) },
                          newInsets: .init(top: 52), transition: .none)
        let edges = ScrollEdges(minimum: -52)
        list.engine.setEdges(edges); list.setScrollOffset(-52)
        let held = -52.0 - 13.0 / 3
        switch path {
        case .shiftAfterEdges:
            list.engine.setEdges(edges); list.engine.shift(by: -13.0 / 3)
        case .sameEdges:
            list.setScrollOffset(held); list.engine.setEdges(edges)
        case .halt:
            list.setScrollOffset(held); list.haltScrolling()
        case .windowReentry:
            list.setScrollOffset(held); list.removeFromSuperview()
            try await Task.sleep(for: .milliseconds(80))
            #expect(!list.isDecelerating)
            window.addSubview(list); list.layoutIfNeeded()
        }
        if mode != .uiKit || path != .windowReentry {
            #expect(abs(list.currentScrollOffset - held) < 1e-8)
        }
        for _ in 0..<100 where abs(list.overscrollDistance) > 0.5 || list.isDecelerating {
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(abs(list.overscrollDistance) <= 0.5 && !list.isDecelerating,
                "\(mode)/\(path): offset \(list.currentScrollOffset), overscroll \(list.overscrollDistance)")
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func teardownCancelsAQueuedReturn(mode: ScrollEngineMode) async throws {
        let window = makeWindow()
        window.frame = .init(x: 0, y: 0, width: 320, height: 400)
        let scroll = UltraScrollView(engineMode: mode)
        scroll.frame = window.bounds; window.addSubview(scroll); window.isHidden = false
        defer { window.isHidden = true }
        scroll.contentHeight = 1000; scroll.layoutIfNeeded()
        scroll.setScrollOffset(-20); scroll.engine.teardown()
        try await Task.sleep(for: .milliseconds(80))
        #expect(!scroll.isDecelerating && scroll.currentScrollOffset == -20)
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func anEdgePastTheBandDoesNotMoveContentUnderTheFinger(mode: ScrollEngineMode) async throws {
        let window = makeWindow()
        window.frame = .init(x: 0, y: 0, width: 320, height: 400)
        let scroll = UltraScrollView(engineMode: mode)
        scroll.frame = window.bounds; window.addSubview(scroll); window.isHidden = false
        defer { scroll.engine.teardown(); window.isHidden = true }
        scroll.contentHeight = 1000; scroll.layoutIfNeeded(); scroll.setScrollOffset(500)
        let time = CACurrentMediaTime()
        scroll.receiveScrollInput(.init(time: time, phase: .touchDown))
        scroll.receiveScrollInput(.init(time: time, phase: .began))
        scroll.contentHeight = 400
        scroll.engine.reanchorDrag()
        scroll.receiveScrollInput(.init(time: time + 0.01, phase: .changed))
        #expect(abs(scroll.currentScrollOffset - 500) < 1e-8)
        try await Task.sleep(for: .milliseconds(80))
        #expect(scroll.isDragging && !scroll.isDecelerating && abs(scroll.currentScrollOffset - 500) < 1e-8,
                "\(mode): offset \(scroll.currentScrollOffset), dragging \(scroll.isDragging), decelerating \(scroll.isDecelerating)")
        scroll.receiveScrollInput(.init(time: time + 0.1, phase: .ended))
        for _ in 0..<100 where abs(scroll.currentScrollOffset) > 0.5 || scroll.isDecelerating {
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(abs(scroll.currentScrollOffset) <= 0.5 && !scroll.isDecelerating)
    }
}
#endif