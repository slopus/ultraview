#if canImport(UIKit)
import UIKit
import Testing
import UltraLayout
@testable import UltraList

@MainActor
private final class HeldViews {
    struct WeakView { weak var value: HeldRowView? }
    var views: [WeakView] = []
    var live: [HeldRowView] { views.compactMap(\.value) }
}

@MainActor
private final class HeldRowView: ListRowView {
    var ready = false
    override var isDisplayReady: Bool { ready }
    override func update(width: Double, transition: ListTransition) -> Double { 50 }
    func finishDisplay() { ready = true; reportDisplayReady() }
}

@MainActor
private struct HeldRow: ListRow {
    var identity: String
    var ready: Bool
    var storage: HeldViews
    func makeView() -> ListRowView {
        let view = HeldRowView(); view.ready = ready
        storage.views.append(.init(value: view))
        return view
    }
}

@MainActor
@Suite(.serialized) struct ListPendingTargetTests {
    /// A jump held for readiness, then a zero-width layout and a newer jump:
    /// a flush must retry the newer jump, with its options, and the old
    /// hold's late readiness must not bring the older target back.
    @Test(arguments: ScrollEngineMode.allCases)
    func theNewestTargetAppliesAfterAZeroWidthLayout(mode: ScrollEngineMode) async throws {
        let storage = HeldViews(), list = UltraListView(engineMode: mode)
        list.frame = .init(x: 0, y: 0, width: 320, height: 400); list.layoutIfNeeded()
        list.applyChanges(items: (0..<120).map { HeldRow(identity: String($0), ready: $0 < 20, storage: storage) })
        let oldView = try #require(list.loadedItemView(at: 0))
        list.scrollTo(.init(index: 50), transition: .none)
        #expect(list.loadedIndexRange.contains(0))
        let held = storage.live.filter { !$0.ready }
        #expect(!held.isEmpty)
        list.frame.size.width = 0; list.layoutIfNeeded()
        list.applyChanges(scrollTo: .init(index: 80), additionalScrollDistance: 30, transition: .none)
        oldView.onContentDidChange?(false)
        try await Task.sleep(for: .milliseconds(50))
        list.frame.size.width = 320; list.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        #expect(list.loadedIndexRange.contains(80))
        #expect(!list.loadedIndexRange.contains(50))
        #expect(list.settledFrame(at: 80)?.minY == 30)
        for view in held { view.finishDisplay() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(list.loadedIndexRange.contains(80))
        #expect(!list.loadedIndexRange.contains(50))
        #expect(list.settledFrame(at: 80)?.minY == 30)
    }
}
#endif
