#if canImport(UIKit)
import UIKit
import Testing
import UltraCore
@testable import UltraList

@MainActor
private final class MadeViews { var count = 0 }

private struct CountedRow: ListRow {
    var identity: String
    var revision: UInt64 = 0
    var made: MadeViews
    func makeView() -> ListRowView { made.count += 1; return CountedRowView() }
}

private final class CountedRowView: ListRowView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true; accessibilityLabel = "row"
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func update(width: Double, transition: ListTransition) -> Double { 100 }
}

private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !opened { await withCheckedContinuation { waiters.append($0) } } }
    func open() { opened = true; let pending = waiters; waiters.removeAll(); for waiter in pending { waiter.resume() } }
}

/// Measured off the main thread, behind a gate when it has one.
private struct GatedRow: ListRow {
    var identity: String
    var revision: UInt64 = 0
    var gate: Gate?
    var measuresAsynchronously: Bool { gate != nil }
    func makeView() -> ListRowView { CountedRowView() }
    func measure(width: Double, environment: RenderEnvironment) async -> Double? { await gate?.wait(); return 100 }
}

/// A scroll builds the next row past the window on an idle turn, hidden, and
/// shows that view when it places the row. A row that leaves is hidden at
/// once and taken out of the hierarchy on an idle turn.
@MainActor
@Suite(.serialized) struct PremountTests {
    private func makeList(_ mode: ScrollEngineMode, made: MadeViews) -> (UIWindow, UltraListView) {
        let window = makeWindow()
        window.frame = .init(x: 0, y: 0, width: 390, height: 600)
        let list = UltraListView(engineMode: mode)
        list.frame = window.bounds; window.addSubview(list); window.isHidden = false
        list.layoutIfNeeded()
        list.applyChanges(items: rows(made), transition: .none)
        return (window, list)
    }
    private func rows(_ made: MadeViews, revisionAt changed: Int? = nil) -> [any ListRow] {
        (0..<60).map { CountedRow(identity: String($0), revision: $0 == changed ? 1 : 0, made: made) }
    }
    private func scroll(_ list: UltraListView, by distance: Double) {
        list.engine.setOffset(list.currentScrollOffset + distance)
        list.handleScroll(list.currentScrollOffset)
    }
    private func idle() async throws { try await Task.sleep(for: .milliseconds(80)) }
    /// Scroll turns that move nothing, so a measurement that arrives is seen.
    private func settle(_ list: UltraListView, turns: Int = 50, until done: () -> Bool = { false }) async throws {
        for _ in 0..<turns where !done() { list.handleScroll(list.currentScrollOffset); try await Task.sleep(for: .milliseconds(20)) }
    }
    private func nodeRow(_ identity: String, appearance: NodeRowAppearance?) -> NodeRow {
        NodeRow(identity: identity, animatesContent: true, appearance: appearance) {
            var style = Style(); style.height = .points(100)
            return UltraNode(style: style)
        }
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func thePremountedRowStaysHiddenUntilAScrollPlacesItAndIsTheViewShown(mode: ScrollEngineMode) async throws {
        let made = MadeViews()
        let (window, list) = makeList(mode, made: made)
        defer { list.engine.teardown(); window.isHidden = true }
        scroll(list, by: 30)
        try await idle()
        let premounted = try #require(list.premounted, "\(mode): nothing premounted")
        let view = premounted.view
        #expect(premounted.index == list.loadedIndexRange.upperBound)
        // Built, but not a loaded row: hidden, untouchable and out of reach of
        // every list reader.
        #expect(view.isHidden && view.superview != nil)
        #expect(list.loadedItemView(at: premounted.index) == nil)
        #expect(!list.loadedItemViews.contains { $0 === view })
        let point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: list)
        #expect(list.hitTest(point, with: nil).map { $0 === view || $0.isDescendant(of: view) } != true)
        #expect(view.readinessObserver == nil)

        // Placing it shows that view, without making another.
        let before = made.count, oldUpper = list.loadedIndexRange.upperBound
        scroll(list, by: 100)
        let mounted = list.loadedIndexRange.upperBound - oldUpper
        #expect(mounted >= 1)
        #expect(list.loadedItemView(at: premounted.index) === view, "\(mode): the premounted view wasn't used")
        #expect(!view.isHidden)
        #expect(made.count == before + mounted - 1)
        let frame = try #require(list.settledFrame(at: premounted.index))
        let shown = view.convert(view.bounds, to: list)
        #expect(abs(shown.minY - frame.minY) < 0.5 && abs(shown.height - frame.height) < 0.5, "\(mode): shown at \(shown), settled \(frame)")
        #expect(view.readinessObserver != nil)
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func aPremountGoesWhenTheItemsChangeTheScrollTurnsOrTheListJumps(mode: ScrollEngineMode) async throws {
        let made = MadeViews()
        let (window, list) = makeList(mode, made: made)
        defer { list.engine.teardown(); window.isHidden = true }
        scroll(list, by: 600)
        try await idle()
        // A pass, here a new revision of the premounted row, leaves no premount behind.
        var premounted = try #require(list.premounted)
        list.applyChanges(items: rows(made, revisionAt: premounted.index), transition: .none)
        #expect(list.premounted == nil || list.premounted?.view !== premounted.view)
        #expect(premounted.view.superview == nil, "\(mode): a premount outlived the pass")
        #expect(list.retired.isEmpty)

        // So does a premounted row whose content changes before it is shown.
        scroll(list, by: 30)
        try await idle()
        premounted = try #require(list.premounted)
        premounted.view.onContentDidChange?(false)
        #expect(list.premounted?.view !== premounted.view)
        #expect(premounted.view.isHidden)
        try await idle()
        #expect(premounted.view.superview == nil)

        // A scroll the other way gives the row on the other side instead.
        scroll(list, by: 30)
        try await idle()
        premounted = try #require(list.premounted)
        #expect(premounted.index == list.loadedIndexRange.upperBound)
        scroll(list, by: -30)
        #expect(list.premounted == nil)
        #expect(premounted.view.isHidden)
        try await idle()
        #expect(premounted.view.superview == nil)
        let other = try #require(list.premounted)
        #expect(other.index == list.loadedIndexRange.lowerBound - 1, "\(mode): premounted \(other.index), window \(list.loadedIndexRange)")

        // A jump is a pass too.
        list.scrollTo(.init(index: 45), transition: .immediate)
        #expect(other.view.superview == nil)
        #expect(list.loadedItemView(at: other.index) !== other.view)
    }

    /// A far jump waits for its destination's rows before it shows them;
    /// a scroll meanwhile builds nothing ahead of the window it leaves.
    @Test(arguments: ScrollEngineMode.allCases)
    func nothingIsPremountedWhileAFarJumpWaitsForItsRows(mode: ScrollEngineMode) async throws {
        let window = makeWindow()
        window.frame = .init(x: 0, y: 0, width: 320, height: 400)
        let list = UltraListView(engineMode: mode)
        list.frame = window.bounds; window.addSubview(list); window.isHidden = false
        defer { list.engine.teardown(); window.isHidden = true }
        list.layoutIfNeeded()
        var rows = (0..<6000).map { GatedRow(identity: "row-\($0)") }
        list.applyChanges(items: rows, transition: .none)
        list.scrollTo(.init(index: 5000), transition: .none)
        let gate = Gate()
        rows[3].revision = 1; rows[3].gate = gate
        list.applyChanges(items: rows, transition: .none)
        list.scrollTo(.init(index: 0), transition: .smoothDeceleration())
        try await Task.sleep(for: .milliseconds(35))
        #expect(list.loadedIndexRange.contains(5000), "\(mode): the jump didn't wait")
        scroll(list, by: 30)
        try await idle()
        #expect(list.premounted == nil, "\(mode): premounted \(list.premounted.map { "\($0.index)" } ?? "") during the hold")
        await gate.open()
        for _ in 0..<150 where !list.loadedIndexRange.contains(0) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(list.loadedIndexRange.contains(0))
        try await Task.sleep(for: .milliseconds(1300))
        scroll(list, by: 30)
        try await idle()
        #expect(list.premounted?.index == list.loadedIndexRange.upperBound, "\(mode): nothing premounted after the jump")
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func aRowThatLeavesIsHiddenAtOnceAndReleasedOnAnIdleTurn(mode: ScrollEngineMode) async throws {
        let made = MadeViews()
        let (window, list) = makeList(mode, made: made)
        defer { list.engine.teardown(); window.isHidden = true }
        let first = try #require(list.loadedItemView(at: 0))
        scroll(list, by: 400)
        #expect(!list.loadedIndexRange.contains(0))
        #expect(list.loadedItemView(at: 0) == nil)
        #expect(first.isHidden && first.superview != nil, "\(mode): left at once")
        #expect(first.readinessObserver == nil && first.onContentDidChange == nil)
        #expect(list.retired.contains { $0.view === first })
        try await idle()
        #expect(first.superview == nil, "\(mode): never released")
        #expect(list.retired.isEmpty)

        // Coming back before an idle turn: a new view, and the old one goes first.
        let second = try #require(list.loadedItemView(at: list.loadedIndexRange.lowerBound))
        let index = list.loadedIndexRange.lowerBound
        scroll(list, by: 400)
        #expect(second.isHidden && second.superview != nil)
        scroll(list, by: -400)
        let back = try #require(list.loadedItemView(at: index))
        #expect(back !== second && !back.isHidden)
        #expect(second.superview == nil)
        #expect(!list.retired.contains { $0.identity == list.items[index].identity })
    }

    /// A new revision that is still measuring leaves the old rows, and their
    /// premount, until its pass; that pass drops the old view, and the row
    /// is built again for the new revision.
    @Test(arguments: ScrollEngineMode.allCases)
    func aRevisionStillMeasuringNeverGetsTheViewBuiltForTheOldOne(mode: ScrollEngineMode) async throws {
        let window = makeWindow()
        window.frame = .init(x: 0, y: 0, width: 390, height: 600)
        let list = UltraListView(engineMode: mode)
        list.frame = window.bounds; window.addSubview(list); window.isHidden = false
        defer { list.engine.teardown(); window.isHidden = true }
        list.layoutIfNeeded()
        let open = Gate(); await open.open()
        var rows = (0..<60).map { GatedRow(identity: String($0), gate: open) }
        list.applyChanges(items: rows, transition: .none)
        for _ in 0..<100 where list.loadedIndexRange.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        scroll(list, by: 30)
        try await settle(list) { list.premounted != nil }
        let old = try #require(list.premounted, "\(mode): nothing premounted")
        let gate = Gate()
        rows[old.index].revision = 1; rows[old.index].gate = gate
        list.applyChanges(items: rows, transition: .none)
        try await settle(list, turns: 10)
        // Whatever is built ahead is for the revision the list shows.
        if let premounted = list.premounted { #expect(premounted.key.revision == list.items[premounted.index].revision) }
        #expect(list.items[old.index].revision == 0 || list.premounted == nil, "\(mode): premounted while its revision measures")
        await gate.open()
        for _ in 0..<100 where list.items[old.index].revision != 1 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(list.items[old.index].revision == 1)
        #expect(old.view.superview == nil, "\(mode): the old revision's view outlived its pass")
        try await settle(list) { list.premounted != nil }
        let next = try #require(list.premounted, "\(mode): the new revision wasn't premounted")
        #expect(next.index == old.index && next.key.revision == 1 && next.view !== old.view)
        scroll(list, by: 100)
        let shown = try #require(list.loadedItemView(at: old.index))
        #expect(shown === next.view && !shown.isHidden)
    }

    /// A row whose appearance is still to play plays it where it is seen, so
    /// it isn't built ahead and its appearance waits; the same row without
    /// one is built ahead.
    @Test(arguments: ScrollEngineMode.allCases)
    func aRowWhoseAppearanceIsStillToPlayIsNotBuiltAhead(mode: ScrollEngineMode) async throws {
        let made = MadeViews()
        let (window, list) = makeList(mode, made: made)
        defer { list.engine.teardown(); window.isHidden = true }
        scroll(list, by: 30)
        try await idle()
        let index = try #require(list.premounted).index
        var items = rows(made)
        items[index] = nodeRow("plain", appearance: nil)
        list.applyChanges(items: items, transition: .none)
        for _ in 0..<100 where list.items[index].identity != "plain" { try await Task.sleep(for: .milliseconds(20)) }
        try await settle(list) { list.premounted?.identity == "plain" }
        #expect(list.premounted?.identity == "plain", "\(mode): a node row wasn't premounted")

        let appearing = nodeRow("appearing", appearance: .appearing([]))
        items[index] = appearing
        list.applyChanges(items: items, transition: .none)
        for _ in 0..<100 where list.items[index].identity != "appearing" { try await Task.sleep(for: .milliseconds(20)) }
        #expect(list.items[index].identity == "appearing")
        try await settle(list, turns: 25)
        #expect(list.premounted == nil, "\(mode): premounted \(list.premounted?.identity ?? "") ahead of its appearance")
        #expect(!appearing.appearanceShown, "\(mode): the appearance played before the row was shown")

        scroll(list, by: 100)
        let view = try #require(list.loadedItemView(at: index), "\(mode): the row wasn't mounted")
        #expect(!view.isHidden)
        for _ in 0..<100 where !appearing.appearanceShown { try await Task.sleep(for: .milliseconds(20)) }
        #expect(appearing.appearanceShown, "\(mode): the appearance never played")
    }
}
#endif
