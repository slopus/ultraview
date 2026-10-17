#if canImport(UIKit)
import UIKit
import Testing
import UltraLayout
@testable import UltraList

@MainActor
private final class DisplayViews {
    struct WeakView { weak var value: DisplayRowView? }
    var views: [String: WeakView] = [:]
    var creations: [String: Int] = [:]
    func make(_ identity: String, ready: Bool) -> DisplayRowView {
        let view = DisplayRowView(); view.ready = ready
        views[identity] = WeakView(value: view); creations[identity, default: 0] += 1
        return view
    }
    var waiting: [DisplayRowView] { views.values.compactMap(\.value).filter { !$0.ready } }
}

@MainActor
private struct DisplayRow: ListRow {
    var identity: String
    var ready: Bool
    var storage: DisplayViews
    func makeView() -> ListRowView { storage.make(identity, ready: ready) }
}

@MainActor
private final class DisplayRowView: ListRowView {
    var ready = false
    override var isDisplayReady: Bool { ready }
    override func update(width: Double, transition: ListTransition) -> Double { 50 }
    func finishDisplay() { ready = true; reportDisplayReady() }
}

@MainActor
@Suite(.serialized) struct ListDisplayReadinessTests {
    @Test(arguments: ScrollEngineMode.allCases, [false, true])
    func aFarJumpKeepsTheOldWindowUntilItsVisibleRowsAreReady(mode: ScrollEngineMode, superseded: Bool) throws {
        let storage = DisplayViews(), list = UltraListView(engineMode: mode)
        list.frame = .init(x: 0, y: 0, width: 320, height: 400); list.layoutIfNeeded()
        list.applyChanges(items: (0..<120).map { DisplayRow(identity: String($0), ready: $0 < 20, storage: storage) })
        let oldRange = list.loadedIndexRange
        let oldView = try #require(list.loadedItemView(at: 0))
        let oldFrame = try #require(list.settledFrame(at: 0))
        list.scrollTo(.init(index: 50), transition: .none)
        let first = storage.waiting
        #expect(!first.isEmpty)
        #expect(list.loadedIndexRange == oldRange)
        #expect(oldView.superview != nil && list.settledFrame(at: 0) == oldFrame)
        let target = superseded ? 80 : 50
        if superseded {
            list.scrollTo(.init(index: target), transition: .none)
            for view in first { view.finishDisplay() }
            #expect(list.loadedIndexRange == oldRange)
        }
        for view in storage.waiting { view.finishDisplay() }
        #expect(list.loadedIndexRange.contains(target))
        #expect(list.loadedItemView(at: target)?.isDisplayReady == true)
        #expect(storage.creations[String(target)] == 1)
        #expect(oldView.superview == nil)
        for index in list.loadedIndexRange {
            if let frame = list.settledFrame(at: index), frame.intersects(list.bounds) {
                #expect(list.loadedItemView(at: index)?.isDisplayReady == true)
            }
        }
    }
}
#endif