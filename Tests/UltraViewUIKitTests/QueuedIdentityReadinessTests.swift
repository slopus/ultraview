#if canImport(UIKit)
import UIKit
import QuartzCore
import Testing
import UltraCore
import UltraLayout
@testable import UltraList

private actor QueuedDrawingGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if !opened { await withCheckedContinuation { waiters.append($0) } }
    }
    func open() {
        opened = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

@MainActor
private final class QueuedPreparedContent: DisplayPreparedContent {
    weak var owner: QueuedPreparedView?
    private var gate: QueuedDrawingGate?
    private var drawing: Task<Void, Never>?
    private(set) var isDisplayPrepared = true
    private(set) var drawings = 0
    var hasLiveHost: Bool { owner != nil }
    func cool(until gate: QueuedDrawingGate) {
        self.gate = gate; drawing = nil; isDisplayPrepared = false
    }
    func drawAhead() -> Task<Void, Never>? {
        guard !isDisplayPrepared, let gate else { return nil }
        if let drawing { return drawing }
        drawings += 1
        let drawing = Task { [weak self] in
            await gate.wait()
            guard let self, !Task.isCancelled else { return }
            isDisplayPrepared = true; owner?.reportDisplayReady()
        }
        self.drawing = drawing
        return drawing
    }
}

@MainActor
private final class QueuedPreparedView: ListRowView {
    private var content: QueuedPreparedContent?
    override var isDisplayReady: Bool { content?.isDisplayPrepared == true }
    override func applyPreparation(_ preparation: ListPreparation, width: Double, environment: RenderEnvironment) {
        content = preparation.content as? QueuedPreparedContent
        content?.owner = self; _ = content?.drawAhead()
    }
}

@MainActor
private final class QueuedPreparedRow: ListRow {
    let identity: String
    let height: Double
    let revision: UInt64
    let content = QueuedPreparedContent()
    private var failuresRemaining: Int
    private(set) var preparations = 0
    var measuresAsynchronously: Bool { true }
    init(_ index: Int, height: Double = 60, revision: UInt64 = 0, failures: Int = 0) {
        identity = "queued-\(index)"; self.height = height; self.revision = revision
        failuresRemaining = failures
    }
    func makeView() -> ListRowView { QueuedPreparedView() }
    func prepare(width: Double, environment: RenderEnvironment) async -> ListPreparation? {
        preparations += 1
        if failuresRemaining > 0 { failuresRemaining -= 1; return nil }
        return .init(height: height, content: content)
    }
}

@MainActor
private final class QueuedGrowingView: ListRowView {
    var height = 60.0
    override func update(width: Double, transition: ListTransition) -> Double { height }
}

@MainActor
private final class QueuedGrowingRow: ListRow {
    let identity = "queued-40"
    let view = QueuedGrowingView()
    func makeView() -> ListRowView { view }
}

@MainActor
private final class QueuedTargetProbe {
    var heights: [Double] = []
    var receivedView = false
    var sawAppliedCollection = false
}

@MainActor
@Suite(.serialized) struct QueuedIdentityReadinessTests {
    @Test(arguments: ScrollEngineMode.allCases)
    func aStreamWaitsForTheIdentityTargetsPhysicalRows(mode: ScrollEngineMode) async throws {
        let (window, list, rows) = try await fixture(mode)
        let gate = QueuedDrawingGate(), offscreen = QueuedDrawingGate()
        defer { clean(window, list, gates: [gate, offscreen]) }
        let witness = try #require(list.settledFrame(at: 42)).minY
        let probe = holdTarget(list, rows: rows, gate: gate)
        try await waitUntil { rows[6].content.drawings == 1 }
        rows[0].content.cool(until: offscreen)
        let changed = QueuedPreparedRow(4, revision: 1)
        var next: [any ListRow] = rows; next[4] = changed
        list.applyChanges(items: next, transition: .none)
        try await waitUntil { changed.preparations == 1 }
        #expect(list.items[4].revision == 0)
        #expect(list.settledFrame(at: 42)?.minY == witness)
        #expect(!list.loadedIndexRange.contains(3))
        #expect(rows[0].content.drawings == 0)
        await gate.open()
        try await waitUntil { list.items[4].revision == 1 && list.loadedIndexRange.contains(3) }
        #expect(abs((try #require(list.settledFrame(at: 3))).maxY - 160) < 0.5)
        #expect(!probe.receivedView && !probe.sawAppliedCollection)
        expectPhysicalRowsReady(list)
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func aShrinkingIdentityTargetWaitsForItsNewPhysicalFrontier(mode: ScrollEngineMode) async throws {
        let (window, list, rows) = try await fixture(mode)
        let gate = QueuedDrawingGate(), frontier = QueuedDrawingGate()
        defer { clean(window, list, gates: [gate, frontier]) }
        let witness = try #require(list.settledFrame(at: 42)).minY
        let probe = holdTarget(list, rows: rows, gate: gate)
        try await waitUntil { rows[6].content.drawings == 1 }
        rows[0].content.cool(until: frontier)
        let target = QueuedPreparedRow(3, height: 20, revision: 1)
        let changed = QueuedPreparedRow(4, revision: 1)
        var next: [any ListRow] = rows; next[3] = target; next[4] = changed
        list.applyChanges(items: next, transition: .none)
        try await waitUntil { target.preparations == 1 && changed.preparations == 1 && rows[0].content.drawings == 1 }
        #expect(list.items[4].revision == 0)
        #expect(list.settledFrame(at: 42)?.minY == witness)
        await gate.open()
        try await waitUntil { rows[6].content.isDisplayPrepared }
        try await Task.sleep(for: .milliseconds(20))
        #expect(list.items[4].revision == 0)
        #expect(list.settledFrame(at: 42)?.minY == witness)
        #expect(!rows[0].content.isDisplayPrepared)
        await frontier.open()
        try await waitUntil { list.items[4].revision == 1 && list.settledFrame(at: 3)?.height == 20 }
        #expect(abs((try #require(list.settledFrame(at: 3))).maxY - 160) < 0.5)
        #expect((try #require(list.settledFrame(at: 0))).maxY > 0)
        #expect((try #require(list.settledFrame(at: 0))).maxY <= 60)
        #expect(probe.heights.contains(20))
        #expect(!probe.receivedView && !probe.sawAppliedCollection)
        expectPhysicalRowsReady(list)
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func anInsertedCollectionKeepsItsIdentityTargetBehindTheDrawGate(mode: ScrollEngineMode) async throws {
        let (window, list, rows) = try await fixture(mode)
        let gate = QueuedDrawingGate()
        defer { clean(window, list, gates: [gate]) }
        let witness = try #require(list.settledFrame(at: 42)).minY
        let probe = holdTarget(list, rows: rows, gate: gate)
        try await waitUntil { rows[6].content.drawings == 1 }
        let inserted = QueuedPreparedRow(1000)
        list.applyChanges(items: [inserted] + rows, transition: .none)
        try await waitUntil { inserted.preparations == 1 }
        #expect(list.items.first?.identity == "queued-0")
        #expect(list.settledFrame(at: 42)?.minY == witness)
        #expect(!list.loadedIndexRange.contains(4))
        await gate.open()
        try await waitUntil { list.items.first?.identity == inserted.identity && list.loadedIndexRange.contains(4) }
        #expect(list.items[4].identity == "queued-3")
        #expect(abs((try #require(list.settledFrame(at: 4))).maxY - 160) < 0.5)
        #expect(!probe.receivedView && !probe.sawAppliedCollection)
        expectPhysicalRowsReady(list)
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func anInvalidQueuedFrontierRetriesItsNewRevision(mode: ScrollEngineMode) async throws {
        let (window, list, rows) = try await fixture(mode)
        let gate = QueuedDrawingGate(), frontier = QueuedDrawingGate()
        defer { clean(window, list, gates: [gate, frontier]) }
        let witness = try #require(list.settledFrame(at: 42)).minY
        let probe = holdTarget(list, rows: rows, gate: gate, index: 30)
        try await waitUntil { rows[33].content.drawings == 1 }
        // Row 17 is physically behind the top inset, outside the initial
        // 24-row preparation band around row 30, and has no committed revision.
        let next = (0..<80).map { QueuedPreparedRow($0, height: 10, revision: 1, failures: $0 == 17 ? 1 : 0) }
        next[17].content.cool(until: frontier)
        list.applyChanges(items: next, transition: .none)
        try await waitUntil { next[17].preparations == 2 && next[17].content.drawings == 1 }
        #expect(list.items[17].revision == 0)
        #expect(list.settledFrame(at: 42)?.minY == witness)
        await frontier.open()
        try await waitUntil { list.items[17].revision == 1 && list.loadedIndexRange.contains(17) }
        #expect(next[17].preparations == 2)
        #expect(!probe.receivedView && !probe.sawAppliedCollection)
        expectPhysicalRowsReady(list)
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func aCommittedRowCanGrowWhileAnIdentityTargetBelongsToTheQueue(mode: ScrollEngineMode) async throws {
        let growing = QueuedGrowingRow()
        let (window, list, rows) = try await fixture(mode, growing: growing)
        let gate = QueuedDrawingGate()
        defer { clean(window, list, gates: [gate]) }
        let probe = holdTarget(list, rows: rows, gate: gate)
        try await waitUntil { rows[6].content.drawings == 1 }
        let changed = QueuedPreparedRow(4, revision: 1)
        var next = list.items; next[4] = changed
        list.applyChanges(items: next, transition: .none)
        try await waitUntil { changed.preparations == 1 }
        growing.view.height = 90; growing.view.onContentDidChange?(false)
        try await waitUntil { list.settledFrame(at: 40)?.height == 90 }
        #expect(list.items[4].revision == 0)
        #expect(!list.loadedIndexRange.contains(3))
        await gate.open()
        try await waitUntil { list.items[4].revision == 1 && list.loadedIndexRange.contains(3) }
        #expect(list.items[40] is QueuedGrowingRow)
        #expect(growing.view.height == 90)
        #expect(!probe.receivedView && !probe.sawAppliedCollection)
        expectPhysicalRowsReady(list)
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func aDragCancelsTheQueuedIdentityTargetBeforeItsOldDrawCompletes(mode: ScrollEngineMode) async throws {
        let (window, list, rows) = try await fixture(mode)
        let gate = QueuedDrawingGate()
        defer { clean(window, list, gates: [gate]) }
        _ = holdTarget(list, rows: rows, gate: gate)
        try await waitUntil { rows[6].content.drawings == 1 }
        let changed = QueuedPreparedRow(4, revision: 1)
        var next: [any ListRow] = rows; next[4] = changed
        list.applyChanges(items: next, transition: .none)
        try await waitUntil { changed.preparations == 1 }
        let witness = try #require(list.settledFrame(at: 42)).minY, now = CACurrentMediaTime()
        list.receiveScrollInput(.init(time: now, phase: .began))
        list.receiveScrollInput(.init(time: now + 0.01, phase: .changed, translation: .init(y: -20)))
        try await waitUntil { list.items[4].revision == 1 }
        #expect(list.isDragging && !list.loadedIndexRange.contains(3))
        #expect(abs((try #require(list.settledFrame(at: 42))).minY - witness + 20) < 0.5)
        await gate.open()
        try await Task.sleep(for: .milliseconds(30))
        #expect(!list.loadedIndexRange.contains(3))
        let before = try #require(list.settledFrame(at: 42)).minY
        list.receiveScrollInput(.init(time: now + 0.2, phase: .changed, translation: .init(y: -60)))
        #expect(list.isDragging)
        #expect(abs((try #require(list.settledFrame(at: 42))).minY - before + 40) < 0.5)
        list.receiveScrollInput(.init(time: now + 0.21, phase: .ended, translation: .init(y: -60)))
        #expect(!list.isDragging)
    }

    private func fixture(_ mode: ScrollEngineMode, growing: QueuedGrowingRow? = nil) async throws -> (UIWindow, UltraListView, [QueuedPreparedRow]) {
        let window = makeWindow(), list = UltraListView(engineMode: mode)
        window.frame = .init(x: 0, y: 0, width: 320, height: 300)
        list.frame = window.bounds; window.addSubview(list); window.isHidden = false
        list.layoutIfNeeded()
        list.applyChanges(newInsets: .init(top: 60, bottom: 100), transition: .none)
        let rows = (0..<80).map { QueuedPreparedRow($0) }
        var items: [any ListRow] = rows
        if let growing { items[40] = growing }
        list.applyChanges(items: items, transition: .none)
        try await waitUntil { list.items.count == 80 && rows[6].preparations == 1 }
        list.scrollTo(.init(index: 40), transition: .none)
        try await waitUntil { abs((list.settledFrame(at: 40)?.minY ?? -1000) - 60) < 0.5 && list.loadedIndexRange.contains(42) }
        return (window, list, rows)
    }

    private func holdTarget(_ list: UltraListView, rows: [QueuedPreparedRow], gate: QueuedDrawingGate, index: Int = 3) -> QueuedTargetProbe {
        rows[index + 3].content.cool(until: gate)
        let probe = QueuedTargetProbe()
        list.scrollTo(.init(index: index, identity: "queued-\(index)", resolve: { height, view in
            probe.heights.append(height)
            probe.receivedView = probe.receivedView || view != nil
            probe.sawAppliedCollection = probe.sawAppliedCollection || list.items.first?.identity != "queued-0" || list.items[4].revision != 0
            return 100 - height
        }), transition: .none)
        return probe
    }

    private func clean(_ window: UIWindow, _ list: UltraListView, gates: [QueuedDrawingGate]) {
        list.applyChanges(items: [], transition: .none); window.isHidden = true
        Task { for gate in gates { await gate.open() } }
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