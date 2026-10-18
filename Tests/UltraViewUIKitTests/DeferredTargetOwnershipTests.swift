#if canImport(UIKit)
import UIKit
import QuartzCore
import Testing
import UltraCore
import UltraLayout
@testable import UltraList

@MainActor
private final class OwnershipPreparationGate {
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !opened { await withCheckedContinuation { waiting.append($0) } } }
    func open() {
        opened = true
        let pending = waiting; waiting.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

@MainActor
private final class OwnershipRowView: ListRowView {
    var height = 50.0
    var ready = true
    override var isDisplayReady: Bool { ready }
    override func update(width: Double, transition: ListTransition) -> Double { height }
    func finishDisplay() { ready = true; reportDisplayReady() }
}

@MainActor
private final class OwnershipViews {
    struct WeakView { weak var value: OwnershipRowView? }
    var views: [WeakView] = []
    var waiting: [OwnershipRowView] { views.compactMap(\.value).filter { !$0.ready } }
}

@MainActor
private struct OwnershipRow: ListRow {
    var identity: String
    var revision: UInt64 = 0
    var gate: OwnershipPreparationGate?
    var storage: OwnershipViews?
    var ready = true
    var measuresAsynchronously: Bool { gate != nil }
    func makeView() -> ListRowView {
        let view = OwnershipRowView(); view.ready = ready
        storage?.views.append(.init(value: view))
        return view
    }
    func prepare(width: Double, environment: RenderEnvironment) async -> ListPreparation? {
        await gate?.wait()
        return .init(height: 50)
    }
}

@MainActor
private final class OwnershipAvailability { var ready = false }

@MainActor
private struct OwnershipMeasuredRow: ListRow {
    let identity: String
    let availability: OwnershipAvailability
    var measuresAsynchronously: Bool { true }
    func makeView() -> ListRowView { OwnershipRowView() }
    func prepare(width: Double, environment: RenderEnvironment) async -> ListPreparation? {
        availability.ready ? .init(height: 50) : nil
    }
}

/// A target that waits, for a remote row's preparation or for the rows it
/// lands on to draw, belongs to the moment it was asked for: a drag that
/// begins meanwhile keeps the content the user holds.
@MainActor
@Suite(.serialized) struct DeferredTargetOwnershipTests {
    private func fixture(_ mode: ScrollEngineMode, storage: OwnershipViews? = nil) -> (UIWindow, UltraListView) {
        let window = makeWindow(), list = UltraListView(engineMode: mode)
        window.frame = .init(x: 0, y: 0, width: 320, height: 400)
        list.frame = window.bounds; window.addSubview(list); window.isHidden = false
        list.layoutIfNeeded()
        list.applyChanges(items: (0..<120).map { OwnershipRow(identity: "row-\($0)", storage: storage, ready: storage == nil || $0 < 60) }, transition: .none)
        list.scrollTo(.init(index: 30), transition: .none)
        return (window, list)
    }

    private func drag(_ list: UltraListView, release: Bool) {
        let now = CACurrentMediaTime()
        list.receiveScrollInput(.init(time: now, phase: .began))
        list.receiveScrollInput(.init(time: now + 0.01, phase: .changed, translation: .init(y: -80)))
        if release { list.receiveScrollInput(.init(time: now + 0.02, phase: .ended, translation: .init(y: -80))) }
    }

    /// The drag still tracks the finger, and ends once.
    private func finishDragAndCheckTracking(_ list: UltraListView) throws {
        #expect(list.isDragging)
        let index = try #require(list.items.firstIndex { $0.identity == "row-32" })
        let before = try #require(list.settledFrame(at: index))
        #expect(before.maxY > 0 && before.minY < list.bounds.height)
        let offset = list.currentScrollOffset, range = list.loadedIndexRange, now = CACurrentMediaTime()
        var endings = 0
        list.didEndDragging = { endings += 1 }
        list.receiveScrollInput(.init(time: now, phase: .changed, translation: .init(y: -120)))
        let after = try #require(list.settledFrame(at: index))
        #expect(abs(after.minY - before.minY + 40) < 0.5,
            "row-32 screen y \(before.minY)→\(after.minY); raw offset delta \(list.currentScrollOffset - offset), window \(range)→\(list.loadedIndexRange)")
        list.receiveScrollInput(.init(time: now + 0.01, phase: .ended, translation: .init(y: -120)))
        #expect(!list.isDragging && endings == 1)
    }

    @Test(arguments: ScrollEngineMode.allCases, [false, true])
    func aDragDropsATargetWaitingForPreparationButTheCollectionCommits(mode: ScrollEngineMode, release: Bool) async throws {
        let (window, list) = fixture(mode), gate = OwnershipPreparationGate()
        defer { gate.open(); list.applyChanges(items: [], transition: .none); window.isHidden = true }
        var rows = list.items
        rows[80] = OwnershipRow(identity: "row-80", revision: 1, gate: gate)
        rows.insert(OwnershipRow(identity: "inserted"), at: 0)
        list.applyChanges(items: rows, scrollTo: .init(index: 81), additionalScrollDistance: 123, transition: .none)
        #expect(list.items.first?.identity == "row-0")
        drag(list, release: release)
        let witness = try #require(list.settledFrame(at: 32)).minY
        // Cancelling the target also lifts the barrier at its remote row.
        for _ in 0..<200 where list.items.first?.identity != "inserted" { try await Task.sleep(for: .milliseconds(5)) }
        #expect(list.items.first?.identity == "inserted")
        #expect(abs((try #require(list.settledFrame(at: 33))).minY - witness) < 0.5)
        #expect(!list.loadedIndexRange.contains(81))
        gate.open()
        try await Task.sleep(for: .milliseconds(30))
        #expect(abs((try #require(list.settledFrame(at: 33))).minY - witness) < 0.5)
        #expect(!list.loadedIndexRange.contains(81))
        if !release { try finishDragAndCheckTracking(list) }
    }

    @Test(arguments: ScrollEngineMode.allCases, [false, true])
    func aDragDropsATargetWaitingForDisplay(mode: ScrollEngineMode, release: Bool) async throws {
        let storage = OwnershipViews(), (window, list) = fixture(mode, storage: storage)
        defer { list.applyChanges(items: [], transition: .none); window.isHidden = true }
        let visible = try #require(list.loadedItemView(at: 32) as? OwnershipRowView)
        list.scrollTo(.init(index: 80), transition: .none)
        let waiting = storage.waiting
        #expect(!waiting.isEmpty)
        #expect(!list.loadedIndexRange.contains(80))
        let passes = list.appliedPassCount
        visible.height = 70; visible.onContentDidChange?(false)
        for _ in 0..<100 where list.appliedPassCount == passes { try await Task.sleep(for: .milliseconds(5)) }
        #expect(list.appliedPassCount > passes)
        drag(list, release: release)
        let cancelledPasses = list.appliedPassCount
        for view in waiting { view.finishDisplay() }
        for _ in 0..<100 where list.appliedPassCount == cancelledPasses { try await Task.sleep(for: .milliseconds(5)) }
        #expect(list.appliedPassCount > cancelledPasses)
        #expect(list.loadedIndexRange.contains(32))
        #expect(!list.loadedIndexRange.contains(80))
        #expect(list.settledFrame(at: 32)?.height == 70)
        if !release { try finishDragAndCheckTracking(list) }
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func anIdentityTargetFollowsItsRowAcrossAnInsertion(mode: ScrollEngineMode) async throws {
        let storage = OwnershipViews(), (window, list) = fixture(mode, storage: storage)
        defer { list.applyChanges(items: [], transition: .none); window.isHidden = true }
        list.scrollTo(.init(index: 80, identity: "row-80", pointOffset: 17), transition: .none)
        #expect(!storage.waiting.isEmpty)
        #expect(!list.loadedIndexRange.contains(80))
        var next = list.items
        next.insert(OwnershipRow(identity: "inserted"), at: 0)
        list.applyChanges(items: next, transition: .none)
        for view in storage.waiting { view.finishDisplay() }
        for _ in 0..<100 where !list.loadedIndexRange.contains(81) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(list.items[81].identity == "row-80")
        #expect(abs((try #require(list.settledFrame(at: 81))).minY - 17) < 0.5)
        try await Task.sleep(for: .milliseconds(50))
        #expect(abs((try #require(list.settledFrame(at: 81))).minY - 17) < 0.5)
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func anOrdinaryWaitingTargetKeepsItsIndexWhenACollectionInsertsBeforeIt(mode: ScrollEngineMode) async throws {
        let storage = OwnershipViews(), (window, list) = fixture(mode, storage: storage)
        defer { list.applyChanges(items: [], transition: .none); window.isHidden = true }
        list.scrollTo(.init(index: 80, pointOffset: 17), transition: .none)
        #expect(!storage.waiting.isEmpty)
        #expect(!list.loadedIndexRange.contains(80))
        var next = list.items
        next.insert(OwnershipRow(identity: "inserted"), at: 0)
        list.applyChanges(items: next, transition: .none)
        for view in storage.waiting { view.finishDisplay() }
        for _ in 0..<100 where !list.loadedIndexRange.contains(80) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(list.items[80].identity == "row-79")
        #expect(abs((try #require(list.settledFrame(at: 80))).minY - 17) < 0.5)
        try await Task.sleep(for: .milliseconds(50))
        #expect(abs((try #require(list.settledFrame(at: 80))).minY - 17) < 0.5)
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func aRemovedWaitingTargetCannotReturnWhenItsIdentityReappears(mode: ScrollEngineMode) async throws {
        let storage = OwnershipViews(), (window, list) = fixture(mode, storage: storage)
        defer { list.applyChanges(items: [], transition: .none); window.isHidden = true }
        let witness = try #require(list.settledFrame(at: 32)).minY
        list.scrollTo(.init(index: 80, identity: "row-80"), transition: .none)
        let waiting = storage.waiting
        #expect(!waiting.isEmpty)
        let late = waiting.compactMap { $0.displayWaitObserver }.first
        var next = list.items
        let removed = next.remove(at: 80)
        list.applyChanges(items: next, transition: .none)
        next.insert(removed, at: 0)
        list.applyChanges(items: next, transition: .none)
        for view in waiting { view.finishDisplay() }
        late?()
        try await Task.sleep(for: .milliseconds(50))
        #expect(list.items[0].identity == "row-80")
        #expect(!list.loadedIndexRange.contains(0))
        #expect(abs((try #require(list.settledFrame(at: 33))).minY - witness) < 0.5)
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func anOrdinaryTargetUsesTheCollectionWaitingForItsFirstWindow(mode: ScrollEngineMode) async throws {
        let (window, list) = fixture(mode), availability = OwnershipAvailability()
        defer { list.applyChanges(items: [], transition: .none); window.isHidden = true }
        var next: [any ListRow] = (0..<120).map { OwnershipRow(identity: "desired-\($0)") }
        next[0] = OwnershipMeasuredRow(identity: "desired-0", availability: availability)
        next[5] = OwnershipMeasuredRow(identity: "desired-5", availability: availability)
        let passes = list.appliedPassCount
        list.applyChanges(items: next, transition: .none)
        for _ in 0..<100 where list.appliedPassCount == passes { try await Task.sleep(for: .milliseconds(5)) }
        #expect(list.appliedPassCount > passes)
        #expect(list.items.first?.identity == "row-0")
        list.scrollTo(.init(index: 5, pointOffset: 17), transition: .none)
        #expect(list.items.first?.identity == "row-0")
        availability.ready = true
        for _ in 0..<400 where list.items.first?.identity != "desired-0" || !list.loadedIndexRange.contains(5) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(list.items[5].identity == "desired-5")
        #expect(abs((try #require(list.settledFrame(at: 5))).minY - 17) < 0.5)
    }
}
#endif
