#if canImport(UIKit)
import UIKit
import QuartzCore
import Testing
import UltraCore
import UltraLayout
@testable import UltraList

private actor ColdDrawingGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if !opened { await withCheckedContinuation { waiters.append($0) } }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

@MainActor
private final class ColdPreparedContent: DisplayPreparedContent {
    weak var owner: ColdPreparedView?
    private var gate: ColdDrawingGate?
    private var drawing: Task<Void, Never>?
    private(set) var isDisplayPrepared = true
    private(set) var drawings = 0
    var hasLiveHost: Bool { owner != nil }

    func cool(until gate: ColdDrawingGate) {
        self.gate = gate
        drawing = nil
        isDisplayPrepared = false
    }
    func drawAhead() -> Task<Void, Never>? {
        guard !isDisplayPrepared, let gate else { return nil }
        if let drawing { return drawing }
        drawings += 1
        let drawing = Task { [weak self] in
            await gate.wait()
            guard let self, !Task.isCancelled else { return }
            isDisplayPrepared = true
            owner?.reportDisplayReady()
        }
        self.drawing = drawing
        return drawing
    }
}

@MainActor
private final class ColdPreparedView: ListRowView {
    private var content: ColdPreparedContent?
    override var isDisplayReady: Bool { content?.isDisplayPrepared == true }
    override func applyPreparation(_ preparation: ListPreparation, width: Double, environment: RenderEnvironment) {
        content = preparation.content as? ColdPreparedContent
        content?.owner = self
        _ = content?.drawAhead()
    }
}

@MainActor
private final class ColdPreparedRow: ListRow {
    let identity: String
    let height: Double
    let revision: UInt64
    private let preparationGate: ColdDrawingGate?
    let content = ColdPreparedContent()
    private(set) var preparations = 0
    var measuresAsynchronously: Bool { true }
    convenience init(_ index: Int) { self.init(index, height: 60) }
    init(_ index: Int, height: Double, revision: UInt64 = 0, preparationGate: ColdDrawingGate? = nil) {
        identity = "cold-\(index)"; self.height = height; self.revision = revision; self.preparationGate = preparationGate
    }
    func makeView() -> ListRowView { ColdPreparedView() }
    func prepare(width: Double, environment: RenderEnvironment) async -> ListPreparation? {
        preparations += 1
        await preparationGate?.wait()
        return .init(height: height, content: content)
    }
}

@MainActor
private final class ColdFixedView: ListRowView {
    var height = 1200.0
    override func update(width: Double, transition: ListTransition) -> Double { height }
}

@MainActor
private struct ColdFixedRow: ListRow {
    let identity = "tall"
    var revision: UInt64
    var height: Double
    var measuresAsynchronously: Bool { true }
    func makeView() -> ListRowView { ColdFixedView() }
    func apply(to view: ListRowView, transition: ListTransition) { (view as? ColdFixedView)?.height = height }
    func prepare(width: Double, environment: RenderEnvironment) async -> ListPreparation? { .init(height: height) }
}

@MainActor
private final class GrowingColdRow: ListRow {
    let identity = "growing"
    let view = ColdFixedView()
    init() { view.height = 60 }
    func makeView() -> ListRowView { view }
}

@MainActor
@Suite(.serialized) struct ColdRowReadinessTests {
    @Test(arguments: [ScrollEngineMode.uiKit, .stepped, .keyframe])
    func shrinkingATallRowWaitsForCachedContentAcrossThePhysicalViewport(mode: ScrollEngineMode) async throws {
        let (window, list) = mount(mode)
        defer { window.isHidden = true }
        let rows = (1..<80).map(ColdPreparedRow.init)
        list.applyChanges(items: [ColdFixedRow(revision: 0, height: 1200)] + rows, transition: .none)
        try await waitUntil { list.items.count == 80 && rows.prefix(3).allSatisfy { $0.preparations == 1 } }
        #expect(list.settledFrame(at: 0)?.height == 1200)
        let gate = ColdDrawingGate()
        for row in rows.prefix(3) { row.content.cool(until: gate) }
        let farGate = ColdDrawingGate()
        let farRows = Array(rows.dropFirst(9).prefix(11))
        for row in farRows { row.content.cool(until: farGate) }
        let clock = ContinuousClock()
        let began = clock.now
        list.applyChanges(items: [ColdFixedRow(revision: 1, height: 60)] + rows, transition: .none)
        try await waitUntil { rows.prefix(3).allSatisfy { $0.content.drawings == 1 } }
        #expect(list.settledFrame(at: 0)?.height == 1200)
        #expect(list.items.first?.revision == 0)
        #expect(farRows.allSatisfy { $0.content.drawings == 0 })
        let beforeDrag = list.currentScrollOffset, now = CACurrentMediaTime()
        list.receiveScrollInput(.init(time: now, phase: .began))
        list.receiveScrollInput(.init(time: now + 0.01, phase: .changed, translation: .init(y: -20)))
        #expect(abs(list.currentScrollOffset - beforeDrag - 20) < 0.5)
        #expect(list.items.first?.revision == 0)
        list.receiveScrollInput(.init(time: now + 0.02, phase: .ended, translation: .init(y: -20)))
        // The bottom inset is translucent content; rows at y=200...300
        // must be drawn just like the rows above it.
        let released = clock.now
        await gate.open()
        try await waitUntil { list.items.first?.revision == 1 && list.settledFrame(at: 0)?.height == 60 }
        expectPhysicalRowsReady(list)
        #expect(farRows.allSatisfy { $0.content.drawings == 0 })
        await farGate.open()
        #expect(rows.prefix(3).allSatisfy { $0.preparations == 1 && $0.content.drawings == 1 })
        print("Cold readiness \(mode): cached draws=\(rows.reduce(0) { $0 + $1.content.drawings }), held=\(began.duration(to: released)), release-to-commit=\(released.duration(to: clock.now))")

        // The same cached objects can become cold again after being drawn.
        list.applyChanges(items: [ColdFixedRow(revision: 2, height: 1200)] + rows, transition: .none)
        try await waitUntil { list.items.first?.revision == 2 }
        let secondGate = ColdDrawingGate()
        for row in rows.prefix(3) { row.content.cool(until: secondGate) }
        list.applyChanges(items: [ColdFixedRow(revision: 3, height: 60)] + rows, transition: .none)
        try await waitUntil { rows.prefix(3).allSatisfy { $0.content.drawings == 2 } }
        #expect(list.items.first?.revision == 2)
        #expect(list.settledFrame(at: 0)?.height == 1200)
        await secondGate.open()
        try await waitUntil { list.items.first?.revision == 3 }
        expectPhysicalRowsReady(list)
        #expect(rows.prefix(3).allSatisfy { $0.preparations == 1 && $0.content.drawings == 2 })
    }

    @Test(arguments: [ScrollEngineMode.uiKit, .stepped, .keyframe])
    func clearingTheCollectionWhileCachedContentDrawsCannotRestoreIt(mode: ScrollEngineMode) async throws {
        let (window, list) = mount(mode)
        defer { window.isHidden = true }
        let rows = (1..<80).map(ColdPreparedRow.init)
        list.applyChanges(items: [ColdFixedRow(revision: 0, height: 1200)] + rows, transition: .none)
        try await waitUntil { list.items.count == 80 && rows.prefix(3).allSatisfy { $0.preparations == 1 } }
        let gate = ColdDrawingGate()
        for row in rows.prefix(3) { row.content.cool(until: gate) }
        list.applyChanges(items: [ColdFixedRow(revision: 1, height: 60)] + rows, transition: .none)
        try await waitUntil { rows.prefix(3).allSatisfy { $0.content.drawings == 1 } }
        list.applyChanges(items: [], transition: .none)
        await gate.open()
        try await Task.sleep(for: .milliseconds(100))
        #expect(list.items.isEmpty)
        #expect(list.loadedIndexRange.isEmpty)
        #expect(list.loadedItemViews.isEmpty)
        #expect(list.retainedPreparationCount == 0)
    }

    @Test(arguments: [ScrollEngineMode.uiKit, .stepped, .keyframe])
    func anOverlappingTargetWaitsForColdContentBelowTheBottomInset(mode: ScrollEngineMode) async throws {
        let (window, list) = mount(mode)
        defer { window.isHidden = true }
        let rows = (0..<80).map(ColdPreparedRow.init)
        list.applyChanges(items: rows, transition: .none)
        try await waitUntil { list.items.count == 80 && list.loadedIndexRange.contains(6) }
        let before = list.settledFrame(at: 3)?.minY
        let gate = ColdDrawingGate()
        rows[6].content.cool(until: gate)
        list.scrollTo(.init(index: 3), transition: .none)
        try await waitUntil { rows[6].content.drawings == 1 }
        #expect(list.settledFrame(at: 3)?.minY == before)
        list.handleScroll(list.currentScrollOffset)
        await gate.open()
        try await waitUntil { abs((list.settledFrame(at: 3)?.minY ?? -1000) - 60) < 0.5 }
        expectPhysicalRowsReady(list)
        let physicalRow = list.settledFrame(at: 6)
        #expect((physicalRow?.minY ?? 0) >= 200)
        #expect((physicalRow?.minY ?? 1000) < 300)
    }

    @Test(arguments: [ScrollEngineMode.uiKit, .stepped, .keyframe], [false, true])
    func aNewDragOwnsTheWindowWhenAnOverlappingTargetFinishesDrawing(mode: ScrollEngineMode, release: Bool) async throws {
        let (window, list) = mount(mode)
        defer { window.isHidden = true }
        let rows = (0..<80).map(ColdPreparedRow.init)
        list.applyChanges(items: rows, transition: .none)
        try await waitUntil { list.items.count == 80 && list.loadedIndexRange.contains(6) }
        let gate = ColdDrawingGate()
        rows[6].content.cool(until: gate)
        let beforeTarget = list.settledFrame(at: 3)?.minY
        list.scrollTo(.init(index: 3), transition: .none)
        try await waitUntil { rows[6].content.drawings == 1 }
        #expect(list.settledFrame(at: 3)?.minY == beforeTarget)
        let now = CACurrentMediaTime()
        list.receiveScrollInput(.init(time: now, phase: .began))
        list.receiveScrollInput(.init(time: now + 0.01, phase: .changed, translation: .init(y: -80)))
        if release { list.receiveScrollInput(.init(time: now + 0.02, phase: .ended, translation: .init(y: -80))) }
        let witness = try #require(list.settledFrame(at: 3)).minY
        await gate.open()
        try await waitUntil { rows[6].content.isDisplayPrepared }
        try await Task.sleep(for: .milliseconds(50))
        #expect(abs((try #require(list.settledFrame(at: 3))).minY - witness) < 0.5)
        if !release {
            #expect(list.isDragging)
            let before = list.currentScrollOffset
            list.receiveScrollInput(.init(time: now + 0.2, phase: .changed, translation: .init(y: -120)))
            #expect(abs(list.currentScrollOffset - before - 40) < 0.5)
            list.receiveScrollInput(.init(time: now + 0.21, phase: .ended, translation: .init(y: -120)))
            #expect(!list.isDragging)
        }
    }

    @Test(arguments: [ScrollEngineMode.uiKit, .stepped, .keyframe], [false, true])
    func aTargetWithNewGeometryAppliesThatGeometryBeforeTheNextDrag(mode: ScrollEngineMode, changesSize: Bool) async throws {
        let (window, list) = mount(mode)
        defer { window.isHidden = true }
        let rows = (0..<80).map(ColdPreparedRow.init)
        list.applyChanges(items: rows, transition: .none)
        try await waitUntil { list.items.count == 80 && list.loadedIndexRange.contains(6) }
        let gate = ColdDrawingGate()
        rows[6].content.cool(until: gate)
        let insets = changesSize ? ListInsets(top: 60, bottom: 100) : ListInsets(top: 80, bottom: 120)
        if changesSize {
            window.frame.size.height = 340
            list.frame = window.bounds
        }
        list.applyChanges(newSize: changesSize ? list.bounds.size : nil,
                          newInsets: changesSize ? nil : insets, scrollTo: .init(index: 3), transition: .none)
        #expect(list.viewportInsets == insets)
        #expect(abs((list.settledFrame(at: 3)?.minY ?? -1000) - insets.top) < 0.5)
        let now = CACurrentMediaTime(), before = list.currentScrollOffset
        list.receiveScrollInput(.init(time: now, phase: .began))
        list.receiveScrollInput(.init(time: now + 0.01, phase: .changed, translation: .init(y: -40)))
        #expect(abs(list.currentScrollOffset - before - 40) < 0.5)
        let witness = try #require(list.settledFrame(at: 3)).minY
        await gate.open()
        try await Task.sleep(for: .milliseconds(50))
        #expect(list.isDragging)
        #expect(abs((try #require(list.settledFrame(at: 3))).minY - witness) < 0.5)
        list.receiveScrollInput(.init(time: now + 0.2, phase: .ended, translation: .init(y: -40)))
    }

    @Test(arguments: [ScrollEngineMode.uiKit, .stepped, .keyframe])
    func aCommittedRowCanGrowWhileTheCollectionWaitsForColdContent(mode: ScrollEngineMode) async throws {
        let (window, list) = mount(mode)
        defer { window.isHidden = true }
        let growing = GrowingColdRow(), rows = (2..<80).map(ColdPreparedRow.init)
        let initial: [any ListRow] = [growing, ColdFixedRow(revision: 0, height: 1200)] + rows
        list.applyChanges(items: initial, transition: .none)
        try await waitUntil { list.items.count == 80 && rows.prefix(2).allSatisfy { $0.preparations == 1 } }
        let gate = ColdDrawingGate()
        for row in rows.prefix(2) { row.content.cool(until: gate) }
        let next: [any ListRow] = [growing, ColdFixedRow(revision: 1, height: 60)] + rows
        list.applyChanges(items: next, transition: .none)
        try await waitUntil { rows.prefix(2).allSatisfy { $0.content.drawings == 1 } }
        growing.view.height = 70
        growing.view.onContentDidChange?(false)
        try await waitUntil { list.settledFrame(at: 0)?.height == 70 }
        #expect(list.items[1].revision == 0)
        #expect(list.settledFrame(at: 1)?.height == 1200)
        await gate.open()
        try await waitUntil { list.items[1].revision == 1 }
        #expect(list.settledFrame(at: 0)?.height == 70)
        expectPhysicalRowsReady(list)
    }

    @Test(arguments: [ScrollEngineMode.uiKit, .stepped, .keyframe])
    func aCollapseWaitsForPhysicalRowsBeyondTheInitialPreparationBand(mode: ScrollEngineMode) async throws {
        let (window, list) = mount(mode)
        defer { window.isHidden = true }
        let rows = (0..<80).map { ColdPreparedRow($0, height: 10) }
        var initial: [any ListRow] = rows
        initial[40] = ColdFixedRow(revision: 0, height: 1200)
        list.applyChanges(items: initial, scrollTo: .init(index: 60), transition: .none)
        try await waitUntil { rows[60].preparations == 1 && list.loadedIndexRange.contains(70) }
        list.scrollTo(.init(index: 40), transition: .none)
        try await waitUntil { list.settledFrame(at: 40)?.height == 1200 }
        let gate = ColdDrawingGate()
        rows[60].content.cool(until: gate)
        var next = initial
        next[40] = ColdFixedRow(revision: 1, height: 10)
        list.applyChanges(items: next, transition: .none)
        try await waitUntil { rows[60].content.drawings == 1 }
        #expect(list.settledFrame(at: 40)?.height == 1200)
        #expect(!list.loadedIndexRange.contains(60))
        await gate.open()
        try await waitUntil { list.settledFrame(at: 40)?.height == 10 && list.loadedIndexRange.contains(60) }
        #expect(rows[60].preparations == 1)
        expectPhysicalRowsReady(list)
    }

    @Test(arguments: [ScrollEngineMode.uiKit, .stepped, .keyframe])
    func cancellingAnInheritedTargetStillWaitsForTheCollapsedCollectionsColdRows(mode: ScrollEngineMode) async throws {
        let (window, list) = mount(mode)
        defer { window.isHidden = true }
        let rows = (1..<80).map(ColdPreparedRow.init)
        list.applyChanges(items: [ColdFixedRow(revision: 0, height: 1200)] + rows, transition: .none)
        try await waitUntil { list.items.count == 80 && rows.prefix(3).allSatisfy { $0.preparations == 1 } }
        let drawing = ColdDrawingGate(), measuring = ColdDrawingGate()
        for row in rows.prefix(3) { row.content.cool(until: drawing) }
        let remote = ColdPreparedRow(60, height: 60, revision: 1, preparationGate: measuring)
        var next: [any ListRow] = [ColdFixedRow(revision: 1, height: 60)] + rows
        next[60] = remote
        list.applyChanges(items: next, scrollTo: .init(index: 60), additionalScrollDistance: 123, transition: .none)
        try await waitUntil { remote.preparations == 1 }
        let now = CACurrentMediaTime()
        list.receiveScrollInput(.init(time: now, phase: .began))
        list.receiveScrollInput(.init(time: now + 0.01, phase: .changed, translation: .init(y: -20)))
        try await waitUntil { rows.prefix(3).allSatisfy { $0.content.drawings == 1 } }
        #expect(list.items.first?.revision == 0)
        #expect(list.settledFrame(at: 0)?.height == 1200)
        await drawing.open()
        try await waitUntil { list.items.first?.revision == 1 }
        #expect(!list.loadedIndexRange.contains(60))
        #expect(list.isDragging)
        let before = list.currentScrollOffset
        list.receiveScrollInput(.init(time: now + 0.2, phase: .changed, translation: .init(y: -60)))
        #expect(abs(list.currentScrollOffset - before - 40) < 0.5)
        list.receiveScrollInput(.init(time: now + 0.21, phase: .ended, translation: .init(y: -60)))
        let witness = try #require(list.settledFrame(at: 0)).minY
        await measuring.open()
        try await Task.sleep(for: .milliseconds(50))
        #expect(abs((try #require(list.settledFrame(at: 0))).minY - witness) < 0.5)
        #expect(!list.loadedIndexRange.contains(60))
        expectPhysicalRowsReady(list)
    }

    @Test func cachedNodeContentReportsColdAfterItsLiveHostRetires() async throws {
        let row = NodeRow(identity: "retired-host") {
            var style = Style()
            style.height = .points(60)
            return UltraNode(style: style, children: [UltraTextNode("Prepared content")])
        }
        let environment = RenderEnvironment()
        let prepared = await ListPreparationHint.$showsSoon.withValue(true) {
            await row.prepare(width: 320, environment: environment)
        }
        let preparation = try #require(prepared)
        let content = try #require(preparation.content as? any DisplayPreparedContent)
        for _ in 0..<4 where !content.isDisplayPrepared { await content.drawAhead()?.value }
        #expect(content.isDisplayPrepared)
        weak var mounted: ListRowView?
        autoreleasepool {
            let view = row.makeView()
            mounted = view
            view.applyPreparation(preparation, width: 320, environment: environment)
            #expect(content.hasLiveHost)
            #expect(view.isDisplayReady)
        }
        try await waitUntil { mounted == nil && !content.hasLiveHost }
        #expect(!content.isDisplayPrepared)
        let clock = ContinuousClock()
        let began = clock.now
        for _ in 0..<4 where !content.isDisplayPrepared { await content.drawAhead()?.value }
        #expect(content.isDisplayPrepared)
        print("Cold node rehost: draw-await=\(began.duration(to: clock.now))")
    }

    private func mount(_ mode: ScrollEngineMode) -> (UIWindow, UltraListView) {
        let window = makeWindow()
        window.frame = .init(x: 0, y: 0, width: 320, height: 300)
        let list = UltraListView(engineMode: mode)
        list.frame = window.bounds
        window.addSubview(list)
        window.isHidden = false
        list.layoutIfNeeded()
        list.applyChanges(newInsets: .init(top: 60, bottom: 100), transition: .none)
        return (window, list)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<600 where !predicate() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }

    private func expectPhysicalRowsReady(_ list: UltraListView) {
        let physical = list.loadedIndexRange.filter {
            guard let frame = list.settledFrame(at: $0) else { return false }
            return frame.maxY > 0 && frame.minY < 300
        }
        #expect(!physical.isEmpty)
        #expect(physical.allSatisfy { list.loadedItemView(at: $0)?.isDisplayReady == true })
    }
}
#endif