#if canImport(UIKit)
import Testing
import UIKit
import UltraCore
@testable import UltraList

private actor FrontierGate {
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
private struct FrontierRow: ListRow {
    var identity: String
    var revision: UInt64 = 0
    var gate: FrontierGate?
    var measuresAsynchronously: Bool { gate != nil }
    func makeView() -> ListRowView { FrontierRowView() }
    func apply(to view: ListRowView, transition: ListTransition) { view.accessibilityIdentifier = identity }
    func measure(width: Double, environment: RenderEnvironment) async -> Double? { await gate?.wait(); return 100 }
}

@MainActor
private final class FrontierRowView: ListRowView {
    override func update(width: Double, transition: ListTransition) -> Double { 100 }
}

@MainActor
@Suite(.serialized) struct FarJumpCoverageTests {
    @Test(arguments: ScrollEngineMode.allCases)
    func aDistantAnimatedJumpWaitsForItsVisibleGeometry(mode: ScrollEngineMode) async throws {
        let window = makeWindow()
        window.frame = .init(x: 0, y: 0, width: 320, height: 400)
        let list = UltraListView(engineMode: mode)
        list.frame = window.bounds; window.addSubview(list); window.isHidden = false
        defer { list.haltScrolling(); window.isHidden = true; list.removeFromSuperview() }
        list.layoutIfNeeded()
        var rows = (0..<6000).map { FrontierRow(identity: "row-\($0)") }
        list.applyChanges(items: rows, transition: .none)
        list.scrollTo(.init(index: 5000), transition: .none)
        let outgoing = list.loadedItemViews
        let gate = FrontierGate()
        rows[3].revision = 1; rows[3].gate = gate
        list.applyChanges(items: rows, transition: .none)
        #expect(list.loadedIndexRange.contains(5000))
        list.layer.speed = 0; list.layer.timeOffset = 100
        list.scrollTo(.init(index: 0), transition: .smoothDeceleration())
        CATransaction.flush(); try await Task.sleep(for: .milliseconds(35))
        #expect(list.loadedIndexRange.contains(5000),
                "\(mode): a partial incoming window cannot displace the outgoing strip")
        await gate.open()
        for _ in 0..<150 where !list.loadedIndexRange.contains(0) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(list.loadedIndexRange.contains(0))
        let last = try #require(list.loadedIndexRange.last)
        #expect((list.settledFrame(at: last)?.maxY ?? 0) >= list.bounds.height)
        CATransaction.flush(); try await Task.sleep(for: .milliseconds(35))
        #expect(list.contentView.layer.animation(forKey: "ultraview.list.viewportOffset") != nil,
                "\(mode): opening the frontier must start the requested travel")
        let stale = outgoing.filter { $0.isDescendant(of: list) }.map {
            $0.convert($0.bounds, to: list).insetBy(dx: 0, dy: 0.5).intersection(list.bounds)
        }.filter { !$0.isNull && !$0.isEmpty }
        #expect(stale.allSatisfy { old in
            list.loadedItemViews.allSatisfy { !$0.convert($0.bounds, to: list).intersects(old) }
        }, "\(mode): a departing strip cannot paint through the incoming rows' gaps")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        list.layer.timeOffset = 102
        CATransaction.commit(); CATransaction.flush()
        for _ in 0..<80 where outgoing.contains(where: { $0.isDescendant(of: list) }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(outgoing.allSatisfy { !$0.isDescendant(of: list) },
                "\(mode): every outgoing row must leave after the travel ends")
    }
}
#endif