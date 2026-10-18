#if canImport(UIKit)
import UIKit
import Testing
import UltraCore
import UltraLayout
@testable import UltraList

private actor InitialMeasurementGate: NodeRowMeasuring {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var completed = 0

    func measure(_ root: UltraNode, width: CGFloat, environment: RenderEnvironment) async -> CGSize {
        if !opened { await withCheckedContinuation { waiters.append($0) } }
        completed += 1
        return .init(width: width, height: 60)
    }

    var waiting: Int { waiters.count }
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

enum InitialGeometryChange: CaseIterable, Sendable, Equatable {
    case size, insets, both
}

@MainActor
@Suite(.serialized) struct InitialPreparationGeometryTests {
    @Test(arguments: [ScrollEngineMode.uiKit, .stepped, .keyframe], InitialGeometryChange.allCases)
    func geometryWhileTheFirstCollectionWaitsKeepsItsRowsAndTarget(mode: ScrollEngineMode, change: InitialGeometryChange) async throws {
        let gate = InitialMeasurementGate()
        let list = UltraListView(engineMode: mode)
        let window = makeWindow()
        window.frame = .init(x: 0, y: 0, width: 320, height: 300)
        list.frame = window.bounds
        window.addSubview(list)
        window.isHidden = false
        list.layoutIfNeeded()
        defer { window.isHidden = true }

        let initialInsets = ListInsets(top: 20, bottom: 10)
        list.applyChanges(newInsets: initialInsets, transition: .none)
        let rows = makeRows(gate: gate)
        list.applyChanges(items: rows, newSize: list.bounds.size, newInsets: initialInsets,
                          scrollTo: .init(index: 40, pointOffset: 17), transition: .none)
        var waiting = 0
        for _ in 0..<600 where waiting < 24 {
            try await Task.sleep(for: .milliseconds(5))
            waiting = await gate.waiting
        }
        #expect(waiting == 24)
        #expect(list.items.isEmpty && list.loadedItemViews.isEmpty)

        let changesSize = change != .insets
        let changesInsets = change != .size
        if changesSize {
            window.frame.size = .init(width: 360, height: 340)
            list.frame = window.bounds
        }
        let insets = changesInsets ? ListInsets(top: 80, bottom: 40) : initialInsets
        list.applyChanges(newSize: changesSize ? list.bounds.size : nil,
                          newInsets: changesInsets ? insets : nil, transition: .none)
        list.layoutIfNeeded()
        #expect(list.items.isEmpty)
        await gate.open()

        for _ in 0..<600 where list.items.count != rows.count || list.loadedItemViews.isEmpty || !list.loadedItemViews.allSatisfy(\.isDisplayReady) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(list.items.count == rows.count)
        #expect(list.loadedIndexRange.contains(40))
        #expect(!list.loadedItemViews.isEmpty)
        let ready = list.loadedItemViews.allSatisfy { $0.isDisplayReady }
        #expect(ready)
        #expect(list.loadedItemView(at: 40)?.bounds.width == (changesSize ? 360 : 320))
        #expect(list.viewportInsets == insets)
        #expect(abs((list.settledFrame(at: 40)?.minY ?? -1000) - (insets.top + 17)) < 0.5)
    }

    @Test(arguments: [ScrollEngineMode.uiKit, .stepped, .keyframe])
    func anExplicitEmptyCollectionStillCancelsTheFirstPreparation(mode: ScrollEngineMode) async throws {
        let gate = InitialMeasurementGate()
        let list = UltraListView(engineMode: mode)
        list.frame = .init(x: 0, y: 0, width: 320, height: 300)
        list.layoutIfNeeded()
        list.applyChanges(items: makeRows(gate: gate), scrollTo: .init(index: 40), transition: .none)
        var waiting = 0
        for _ in 0..<600 where waiting < 24 {
            try await Task.sleep(for: .milliseconds(5))
            waiting = await gate.waiting
        }
        #expect(waiting == 24)
        list.applyChanges(items: [], transition: .none)
        await gate.open()
        var completed = 0
        for _ in 0..<600 where completed < 24 {
            try await Task.sleep(for: .milliseconds(5))
            completed = await gate.completed
        }
        #expect(completed == 24)
        try await Task.sleep(for: .milliseconds(100))
        #expect(list.items.isEmpty)
        #expect(list.loadedItemViews.isEmpty)
        #expect(list.loadedIndexRange.isEmpty)
        #expect(list.retainedPreparationCount == 0)
    }

    private func makeRows(gate: InitialMeasurementGate) -> [any ListRow] {
        (0..<80).map { index in
            NodeRow(identity: "initial-\(index)", measurer: gate) {
                var style = Style()
                style.height = .points(60)
                return UltraNode(style: style)
            }
        }
    }
}
#endif