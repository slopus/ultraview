#if canImport(UIKit)
import UIKit
import QuartzCore
import Testing
import UltraCore
import UltraLayout
import Synchronization
@testable import UltraList

@MainActor
private struct FixedRow: ListRow {
    var identity: String
    var revision: UInt64 = 0
    var height: Double = 50
    var pinsToBottomEdge = false
    var inverted = false
    var onApply: (() -> Void)?
    func makeView() -> ListRowView {
        let view = FixedRowView(); view.isAccessibilityElement = true; view.accessibilityLabel = identity
        return view
    }
    func apply(to view: ListRowView, transition: ListTransition) {
        (view as? FixedRowView)?.height = height
        view.transform = inverted ? .init(scaleX: 1, y: -1) : .identity
        onApply?()
    }
}
@MainActor
private final class FixedRowView: ListRowView {
    var height: Double = 50
    var visible: CGRect?
    override func update(width: Double, transition: ListTransition) -> Double { height }
    override func visibleRectUpdated(_ rect: CGRect?) { visible = rect }
}

@MainActor
private final class ObservedScrollView: UIScrollView {
    var explicitStops = 0
    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        if !animated { explicitStops += 1 }
        super.setContentOffset(contentOffset, animated: animated)
    }
}

@MainActor
private struct AsyncFixedRow: ListRow {
    var identity: String
    var revision: UInt64 = 0
    var height: Double = 50
    var measuresAsynchronously: Bool { true }
    func makeView() -> ListRowView { FixedRowView() }
    func measure(width: Double, environment: RenderEnvironment) async -> Double? {
        try? await Task.sleep(for: .milliseconds(25))
        return height
    }
}

@MainActor
private struct DelayedRevisionRow: ListRow {
    var identity: String
    var revision: UInt64
    var delay: Duration = .milliseconds(150)
    var measuresAsynchronously: Bool { true }
    func makeView() -> ListRowView { FixedRowView() }
    func measure(width: Double, environment: RenderEnvironment) async -> Double? {
        try? await Task.sleep(for: delay)
        return 50 + Double(revision)
    }
}

@MainActor
private struct UnavailableRow: ListRow {
    var identity: String
    var measuresAsynchronously: Bool { true }
    func makeView() -> ListRowView { FixedRowView() }
    func measure(width: Double, environment: RenderEnvironment) async -> Double? { nil }
}

@MainActor
private final class TransientRow: ListRow {
    let identity = "transient"
    var measuresAsynchronously: Bool { true }
    private(set) var attempts = 0
    func makeView() -> ListRowView { FixedRowView() }
    func measure(width: Double, environment: RenderEnvironment) async -> Double? {
        attempts += 1
        return attempts == 1 ? nil : 70
    }
}

private actor MeasurementGate: NodeRowMeasuring {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func measure(_ root: UltraNode, width: CGFloat, environment: RenderEnvironment) async -> CGSize {
        if !opened { await withCheckedContinuation { waiters.append($0) } }
        return .init(width: width, height: 60)
    }
    func open() { opened = true; let pending = waiters; waiters.removeAll(); for waiter in pending { waiter.resume() } }
}

@MainActor
@Suite(.serialized) struct ListIntegrationTests {
    @Test func streamingRevisionsMakeProgressWhileMeasurementsAreSlowerThanSubmissions() async throws {
        let list = list(count: 0)
        var displayed: Set<UInt64> = []
        for revision in 1...20 {
            list.applyChanges(items: [DelayedRevisionRow(identity: "stream", revision: UInt64(revision))], transition: .none)
            try await Task.sleep(for: .milliseconds(50))
            if let revision = list.items.first?.revision { displayed.insert(revision) }
        }
        #expect(displayed.count >= 5, "Streaming must advance before the producer stops: \(displayed)")
        for _ in 0..<100 where list.items.first?.revision != 20 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(list.items.first?.revision == 20)
    }
    @Test func aScrollTargetSubmittedBeforeTheFirstLayoutIsRetained() {
        let list = UltraListView()
        list.applyChanges(items: (0..<100).map { FixedRow(identity: "\($0)") }, scrollTo: .init(index: 25), transition: .none)
        list.frame = .init(x: 0, y: 0, width: 320, height: 400)
        list.layoutIfNeeded()
        #expect(abs((list.settledFrame(at: 25)?.minY ?? -1000) - list.viewportInsets.top) < 0.5)
    }
    @Test(arguments: [false, true]) func aSupersededSendKeepsItsIdentityTargetAndInsertedBlock(olderFinishesFirst: Bool) async throws {
        let list = list(count: 100)
        list.scrollTo(.init(index: 40), transition: .none)
        let old = list.items
        let sent: [any ListRow] = [DelayedRevisionRow(identity: "sent", revision: 1, delay: .milliseconds(olderFinishesFirst ? 75 : 200))]
        list.applyChanges(items: sent + old,
            scrollTo: .init(index: 0), animatesInsertions: false, transition: .easeInOut(1))
        list.animateInsertedBlock(identities: ["sent"], from: .top, transition: .easeInOut(1))
        let newest: [any ListRow] = [FixedRow(identity: "header"), DelayedRevisionRow(identity: "sent", revision: 2, delay: .milliseconds(olderFinishesFirst ? 200 : 75))]
        list.applyChanges(items: newest + old,
            transition: .easeInOut(1))
        for _ in 0..<100 where list.items.first?.identity != "header" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(list.items.first?.identity == "header")
        #expect(abs((list.settledFrame(at: 1)?.minY ?? -1000) - list.viewportInsets.top) < 0.5)
        #expect(list.loadedItemView(at: 1)?.layer.animation(forKey: "ultraview.list.positionY") != nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(list.items.first?.identity == "header")
        #expect(list.items[1].revision == 2)
    }
    @Test func anAwaitedMutationCannotReplayAnOlderKeyboardInset() async throws {
        let list = list(count: 10)
        list.applyChanges(items: [DelayedRevisionRow(identity: "stream", revision: 1)], newInsets: .init(top: 100), transition: .none)
        list.applyChanges(newInsets: .init(top: 200), transition: .none)
        for _ in 0..<100 where list.items.first?.identity != "stream" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(list.items.first?.identity == "stream")
        #expect(list.viewportInsets.top == 200)
    }
    @Test(arguments: ScrollEngineMode.allCases) func keyboardInsetsKeepTheViewportAndRowGeometryWhileCompensatingOnce(mode: ScrollEngineMode) throws {
        let list = list(mode, count: 1000)
        list.contentView.transform = .init(scaleX: 1, y: -1)
        let passes = list.appliedPassCount
        let host = try #require(list.loadedItemView(at: 0))
        list.applyChanges(newInsets: .init(top: 120), transition: .none)
        #expect(list.appliedPassCount == passes)
        #expect(list.loadedItemView(at: 0) === host)
        let first = try #require(list.settledFrame(at: 0))
        #expect(abs(first.minY - 120) < 0.5)
        #expect(list.bounds.height == 400)
        let offset = list.currentScrollOffset
        var durations: [Double] = []
        for step in 0..<120 {
            let start = CACurrentMediaTime()
            list.applyChanges(newInsets: .init(top: 120 + Double(step) / 2), compensatesInsetChange: false, transition: .none)
            durations.append((CACurrentMediaTime() - start) * 1000)
            #expect(list.currentScrollOffset == offset)
            #expect(list.loadedItemView(at: 0) === host)
            #expect(host.layer.animation(forKey: "ultraview.list.positionY") == nil)
        }
        #expect(list.appliedPassCount == passes)
        let p99 = durations.sorted()[Int(Double(durations.count - 1) * 0.99)]
        print("Keyboard inset \(mode): p99 \(p99) ms, no row reapplication")
        #expect(p99 < 2)
    }
    @Test func transientMissingMeasurementRecoversWithoutAnotherSnapshot() async throws {
        let list = list(count: 0), transient = TransientRow()
        list.applyChanges(items: [AsyncFixedRow(identity: "ready"), transient], transition: .none)
        for _ in 0..<100 where list.settledFrame(at: 1)?.height != 70 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(list.items.count == 2 && list.settledFrame(at: 1)?.height == 70)
        #expect(transient.attempts == 2)
    }
    @Test func farPrefetchCompletionsDoNotRepublishTheWindow() async throws {
        let list = list(count: 0)
        list.applyChanges(items: (0..<200).map { AsyncFixedRow(identity: "prefetch-\($0)") }, transition: .none)
        for _ in 0..<100 where list.items.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        var callbacks = 0
        list.onVisibleWindowChanged = { callbacks += 1 }
        try await Task.sleep(for: .milliseconds(150))
        #expect(callbacks == 0)
    }
    @Test func surroundingViewAnimationDoesNotAnimateDepartureCoordinates() async throws {
        let window = makeWindow()
        window.frame = .init(x: 0, y: 0, width: 320, height: 400)
        let controller = UIViewController(); window.rootViewController = controller; window.isHidden = false
        defer { window.isHidden = true }
        let list = list(count: 30); controller.view.addSubview(list)
        UIView.animate(withDuration: 1) {
            list.applyChanges(items: Array(list.items.dropFirst()), transition: .easeInOut(0.4))
        }
        try await Task.sleep(for: .milliseconds(20))
        func check(_ view: UIView) {
            #expect((view.layer.animationKeys() ?? []).allSatisfy { $0.hasPrefix("ultraview.") })
            for child in view.subviews { check(child) }
        }
        check(list)
    }
    @Test(arguments: ScrollEngineMode.allCases) func pinnedViewportHeightUpdatesKeepTheReadyViewAndDoNotReapplyRows(mode: ScrollEngineMode) throws {
        let list = list(mode, count: 0)
        var applications = 0
        let row = FixedRow(identity: "pinned", height: 600, pinsToBottomEdge: true, onApply: { applications += 1 })
        list.applyChanges(items: [row], scrollTo: .init(index: 0, resolve: { height, _ in 400 + max(0, height - 200) - height }), transition: .none)
        let host = try #require(list.loadedItemView(at: 0))
        let initial = applications
        var durations: [Double] = []
        for step in 0..<120 {
            let height = step < 60 ? 400 - Double(step) * 2 : 280 + Double(step - 60) * 2
            let start = CACurrentMediaTime()
            list.frame.size.height = height; list.setNeedsLayout(); list.layoutIfNeeded()
            durations.append((CACurrentMediaTime() - start) * 1000)
            #expect(list.loadedItemView(at: 0) === host)
            #expect(list.isStrictlyPinnedToBottomEdge)
            #expect(host.layer.animation(forKey: "ultraview.list.positionY") == nil)
        }
        #expect(applications == initial)
        let p99 = durations.sorted()[Int(Double(durations.count - 1) * 0.99)]
        print("Pinned viewport \(mode): p99 \(p99) ms, no row reapplication")
        #expect(p99 < 2)
    }
    @Test func unavailableMeasurementDoesNotHoldTheEntireMutation() async throws {
        let list = list(count: 1)
        let rows: [any ListRow] = [AsyncFixedRow(identity: "ready"), UnavailableRow(identity: "unavailable")]
        list.applyChanges(items: rows, transition: .none)
        for _ in 0..<100 where list.items.first?.identity != "ready" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(list.items.map(\.identity) == ["ready", "unavailable"])
        #expect(list.loadedItemView(at: 0) != nil)
        list.applyChanges(items: [AsyncFixedRow(identity: "unavailable", revision: 1)], transition: .none)
        for _ in 0..<100 where list.items.first?.revision != 1 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(list.items.first?.revision == 1 && list.loadedItemView(at: 0) != nil)
    }
    @Test func unmeasuredScrollTargetRetainsItsRequestedTransition() async throws {
        let list = list(count: 0)
        list.applyChanges(items: (0..<200).map { AsyncFixedRow(identity: "async-\($0)") }, transition: .none)
        for _ in 0..<100 where list.items.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        list.scrollTo(.init(index: 150), transition: .init(duration: 0.7, curve: .linear))
        for _ in 0..<100 where !list.loadedIndexRange.contains(150) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(list.loadedIndexRange.contains(150))
        #expect(list.contentView.layer.animation(forKey: "ultraview.list.viewportOffset")?.duration == 0.7)
    }
    @Test func supersededAsyncMutationCannotRestoreClearedRows() async throws {
        let list = list(count: 0)
        for revision in 0..<20 {
            list.applyChanges(items: [AsyncFixedRow(identity: "pending", revision: UInt64(revision), height: Double(50 + revision))])
        }
        list.applyChanges(items: [], transition: .none)
        try await Task.sleep(for: .milliseconds(100))
        #expect(list.items.isEmpty && list.loadedItemViews.isEmpty)
    }
    @Test(arguments: [UInt64(7), 643]) func mixedMutationScrollResizeAndInsetStress(seed: UInt64) {
        let list = list(count: 100)
        var rows = (0..<100).map { FixedRow(identity: String($0)) }
        var random = seed, serial = 100
        func next(_ count: Int) -> Int {
            random = random &* 6364136223846793005 &+ 1442695040888963407
            return Int((random >> 32) % UInt64(max(1, count)))
        }
        for _ in 0..<500 {
            switch next(7) {
            case 0: serial += 1; rows.insert(.init(identity: String(serial)), at: next(rows.count + 1))
            case 1: if rows.count > 1 { rows.remove(at: next(rows.count)) }
            case 2: let row = rows.remove(at: next(rows.count)); rows.insert(row, at: next(rows.count + 1))
            case 3: let index = next(rows.count); rows[index].height = Double(next(300)); rows[index].revision += 1
            case 4: list.scrollTo(.init(index: next(rows.count)), transition: .none)
            case 5: list.applyChanges(newInsets: .init(top: Double(next(300))), transition: .easeInOut(0.1))
            default: list.applyChanges(newSize: .init(width: CGFloat(280 + next(100)), height: CGFloat(300 + next(400))), transition: .spring(0.2, damping: 25))
            }
            list.applyChanges(items: rows, transition: .easeInOut(0.1))
            #expect(list.loadedIndexRange.upperBound <= rows.count)
            for index in list.loadedIndexRange {
                let frame = list.settledFrame(at: index)
                #expect(frame?.minY.isFinite == true && frame.map { Double($0.height) } == rows[index].height)
            }
        }
        list.haltScrolling()
    }
    @Test func asyncInsertionAndResizePreserveRequestedCoreAnimations() async throws {
        let list = list(count: 0)
        var rows = (0..<40).map { AsyncFixedRow(identity: "a\($0)") }
        list.applyChanges(items: rows, transition: .none)
        for _ in 0..<100 where list.items.count != rows.count { try await Task.sleep(for: .milliseconds(10)) }
        rows.insert(.init(identity: "inserted"), at: 0)
        list.applyChanges(items: rows, transition: .init(duration: 0.6, curve: .linear))
        // The old snapshot remains coherent until measurement is ready.
        #expect(list.items.count == 40)
        for _ in 0..<100 where list.items.count != rows.count { try await Task.sleep(for: .milliseconds(10)) }
        let inserted = try #require(list.loadedItemView(at: 0))
        #expect(inserted.layer.animation(forKey: "ultraview.list.opacity")?.duration == 0.6)
        #expect(list.loadedItemView(at: 1)?.layer.animation(forKey: "ultraview.list.positionY") != nil)
        rows.insert(.init(identity: "block"), at: 0)
        list.applyChanges(items: rows, animatesInsertions: false, transition: .easeInOut(0.3))
        list.animateInsertedBlock(identities: ["block"], from: .top, transition: .init(duration: 0.8, curve: .linear))
        for _ in 0..<100 where list.items.count != rows.count { try await Task.sleep(for: .milliseconds(10)) }
        #expect(list.loadedItemView(at: 0)?.layer.animation(forKey: "ultraview.list.positionY")?.duration == 0.8)
        list.defaultTransition = .spring(0.7, damping: 22)
        rows[1].height = 140; rows[1].revision += 1
        list.applyChanges(items: rows)
        for _ in 0..<100 where list.settledFrame(at: 1)?.height != 140 { try await Task.sleep(for: .milliseconds(10)) }
        let spring = try #require(inserted.layer.animation(forKey: "ultraview.list.height") as? CASpringAnimation)
        #expect(spring.duration == 0.7 && spring.damping == 22)
        #expect(list.loadedItemView(at: 2)?.layer.animation(forKey: "ultraview.list.positionY") != nil)
        rows[1].height = 80; rows[1].revision += 1
        list.applyChanges(items: rows, transition: .none)
        for _ in 0..<100 where list.settledFrame(at: 1)?.height != 80 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(inserted.layer.animation(forKey: "ultraview.list.height") == nil)
    }
    @Test func nativeWindowMaintenanceDoesNotExplicitlyStopMomentum() {
        let scroll = ObservedScrollView(frame: .init(x: 0, y: 0, width: 320, height: 400))
        let engine = PlatformEngine(scroll: scroll), edges = ScrollEdges(minimum: 0, maximum: 10_000)
        engine.setEdges(edges); engine.setOffset(100)
        engine.beginMomentum(velocity: 3500)
        scroll.explicitStops = 0
        engine.shift(by: 0); engine.setEdges(edges); engine.shift(by: 50)
        #expect(scroll.explicitStops == 0)
        engine.halt()
        #expect(scroll.explicitStops == 1)
    }
    @Test(arguments: [-9000.0, 9000.0]) func transferredPlatformMomentumReturnsInsideItsEdgesAfterAStall(velocity: Double) async throws {
        let engine = PlatformEngine(scroll: UIScrollView(frame: .init(x: 0, y: 0, width: 320, height: 157)))
        engine.setEdges(.init(minimum: 0, maximum: 300)); engine.setOffset(150)
        engine.beginMomentum(velocity: velocity)
        #expect(engine.decelerating)
        _ = try #require(engine.coveredOffsets(horizon: 0.3))
        let deadline = CACurrentMediaTime() + 0.1
        while CACurrentMediaTime() < deadline {}
        for _ in 0..<100 where engine.decelerating { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!engine.decelerating)
        #expect(abs(engine.offset - (velocity < 0 ? 0 : 300)) <= 0.5)
        #expect(engine.coveredOffsets(horizon: 0.3) == nil)
        engine.teardown()
    }
    @Test func transferredPlatformMomentumKeepsCoastingAndYieldsToNativeInput() async throws {
        let engine = PlatformEngine(scroll: UIScrollView(frame: .init(x: 0, y: 0, width: 320, height: 400)))
        engine.setEdges(.init(minimum: 0, maximum: 100_000)); engine.setOffset(10_000)
        engine.beginMomentum(velocity: 6000)
        try await Task.sleep(for: .milliseconds(500))
        #expect(engine.decelerating)
        let first = engine.offset
        try await Task.sleep(for: .milliseconds(200))
        #expect(engine.offset > first + 100)
        engine.scrollViewWillBeginDragging(engine.scroll)
        let stopped = engine.offset
        try await Task.sleep(for: .milliseconds(50))
        #expect(!engine.decelerating)
        #expect(engine.offset == stopped)
        engine.teardown()
    }
    @Test(arguments: ScrollEngineMode.allCases) func sharedReleaseKeepsMovingAcrossReparks(mode: ScrollEngineMode) async throws {
        let list = list(mode)
        list.receiveScrollInput(.init(time: 0, phase: .began, velocity: .init(y: -3000)))
        list.receiveScrollInput(.init(time: 0.02, phase: .changed, translation: .init(y: -80), velocity: .init(y: -3000)))
        list.receiveScrollInput(.init(time: 0.03, phase: .ended, translation: .init(y: -80), velocity: .init(y: -3000)))
        #expect(list.isDecelerating)
        func progress() -> Double {
            guard let index = list.loadedIndexRange.first, let frame = list.settledFrame(at: index) else { return 0 }
            return Double(index * 50) - Double(frame.minY)
        }
        let released = progress()
        try await Task.sleep(for: .milliseconds(120))
        #expect(progress() > released + 30)
        list.haltScrolling()
        #expect(!list.isDecelerating)
    }
    @Test(arguments: ScrollEngineMode.allCases) func verticalInsetsApplyBeforeADirtyRowIsRemeasured(mode: ScrollEngineMode) async throws {
        let list = list(mode, count: 50)
        let first = try #require(list.loadedItemView(at: 0) as? FixedRowView)
        let passes = list.appliedPassCount
        first.height = 80; first.onContentDidChange?(false)
        list.applyChanges(newInsets: .init(top: 100), transition: .easeInOut(0.18))
        #expect(list.viewportInsets.top == 100)
        #expect(list.appliedPassCount == passes)
        #expect(list.settledFrame(at: 0)?.height == 50)
        for _ in 0..<50 where list.settledFrame(at: 0)?.height != 80 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(list.settledFrame(at: 0)?.height == 80)
        #expect(list.appliedPassCount > passes)
    }
    @Test func insetExposureDoesNotAnimateRowsInFromTheWindowEdge() {
        let list = list()
        list.scrollTo(.init(index: 100), transition: .none)
        list.applyChanges(newInsets: .init(top: 240), transition: .easeInOut(0.5))
        let old = Set(list.loadedIndexRange)
        list.applyChanges(newInsets: .init(), transition: .easeInOut(0.5))
        for index in list.loadedIndexRange where !old.contains(index) {
            #expect(list.loadedItemView(at: index)?.layer.animation(forKey: "ultraview.list.positionY") == nil)
        }
    }
    @Test func delayedSamplerDoesNotHaltAnInvertedFlight() {
        let list = list()
        list.contentView.transform = .init(scaleX: 1, y: -1)
        list.beginMomentum(velocity: 9000)
        list.handleScroll(list.currentScrollOffset + 900)
        #expect(list.isScrollFlightActive)
        list.haltScrolling()
    }
    @Test(arguments: [-9_000.0, 9_000.0]) func releaseMountsTheStallIntervalBeforeAnyDisplayTick(velocity: Double) throws {
        let list = list(count: 2_000)
        list.scrollTo(.init(index: 500), transition: .none)
        list.beginMomentum(velocity: velocity)
        defer { list.haltScrolling() }
        let flight = try #require(list.engine.activeFlight)
        let initialOffset = list.currentScrollOffset
        let frames = list.loadedIndexRange.compactMap { list.settledFrame(at: $0) }
        let top = try #require(frames.map(\.minY).min()), bottom = try #require(frames.map(\.maxY).max())
        let allReady = list.loadedItemViews.allSatisfy { $0.isDisplayReady }
        #expect(allReady)
        #expect(list.loadedItemViews.count <= 84)
        for step in 0...36 {
            let displacement = flight.offset(at: flight.beginTime + Double(step) / 120) - initialOffset
            #expect(top - displacement <= 0)
            #expect(bottom - displacement >= list.bounds.height)
        }
        let deadline = CACurrentMediaTime() + 0.252
        while CACurrentMediaTime() < deadline {}
        #expect(list.isScrollFlightActive)
        #expect(list.loadedIndexRange.count == frames.count)
    }
    @Test func nativeReleaseReparkingMovesItsDestinationByTheSameAmount() throws {
        let engine = PlatformEngine(scroll: UIScrollView(frame: .init(x: 0, y: 0, width: 320, height: 400)))
        engine.setEdges(.init(minimum: 0, maximum: 10_000)); engine.setOffset(1_000)
        engine.onFlightChanged = { [weak engine] _ in engine?.shift(by: 300) }
        var destination = CGPoint(x: 0, y: 3_000)
        engine.scrollViewWillEndDragging(engine.scroll, withVelocity: .init(x: 0, y: 2), targetContentOffset: &destination)
        #expect(destination.y == 3_300)
        let coverage = try #require(engine.coveredOffsets(horizon: 0.3))
        #expect(coverage.lowerBound >= 1_300)
        engine.halt()
    }
    @Test func mountingTheFiniteEndUpdatesTheFlightBeforeItsFirstTick() throws {
        let list = list(count: 50)
        list.scrollTo(.init(index: 30), transition: .none)
        #expect(list.loadedIndexRange.upperBound < 50)
        list.beginMomentum(velocity: 12_000)
        defer { list.haltScrolling() }
        #expect(list.loadedIndexRange.upperBound == 50)
        let frame = try #require(list.settledFrame(at: 49))
        let maximum = list.currentScrollOffset + frame.maxY - list.bounds.height
        let flight = try #require(list.engine.activeFlight)
        #expect(abs(flight.settledOffset - maximum) <= 0.5)
    }
    func list(_ mode: ScrollEngineMode = .keyframe, count: Int = 1000) -> UltraListView {
        let list = UltraListView(engineMode: mode)
        list.frame = .init(x: 0, y: 0, width: 320, height: 400)
        list.layoutIfNeeded()
        list.applyChanges(items: (0..<count).map { FixedRow(identity: String($0)) }, transition: .none)
        return list
    }
    @Test(arguments: ScrollEngineMode.allCases) func initialWindowAndFarJump(mode: ScrollEngineMode) {
        let list = list(mode)
        #expect(list.loadedIndexRange.lowerBound == 0)
        #expect(list.loadedItemViews.count < 20)
        list.scrollTo(.init(index: 900))
        #expect(list.loadedIndexRange.contains(900))
        #expect(list.loadedItemViews.count < 25)
        #expect(abs(list.settledFrame(at: 900)!.minY) < 0.5)
        list.haltScrolling()
    }
    @Test func insertBeforeVisibleWitnessHoldsScreen() {
        let list = list()
        list.scrollTo(.init(index: 100), transition: .immediate)
        let old = list.settledFrame(at: 100)!.minY
        var items: [any ListRow] = list.items
        items.insert(FixedRow(identity: "new"), at: 0)
        list.applyChanges(items: items, anchorMode: .preserveVisibleContent)
        #expect(abs(list.settledFrame(at: 101)!.minY - old) < 1e-6)
    }
    @Test func immediateGrowthIsSettledAtOnce() {
        let list = list(count: 10)
        var items = (0..<10).map { FixedRow(identity: String($0)) }
        items[0].height = 120; items[0].revision = 1
        list.applyChanges(items: items, transition: .easeInOut(0))
        #expect(list.presentedFrame(at: 0)!.height == 120)
        #expect(list.settledFrame(at: 1)!.minY == 120)
    }
    @Test func invertedVariableRowsHaveTheirDeclaredFrames() {
        let list = list(count: 0)
        list.contentView.transform = .init(scaleX: 1, y: -1)
        let rows = (0..<30).map { FixedRow(identity: String($0), height: Double(92 + $0 % 3 * 24), inverted: true) }
        list.applyChanges(items: rows)
        for index in list.loadedIndexRange {
            let view = list.loadedItemView(at: index)!
            #expect(abs(view.frame.height - rows[index].height) < 1e-6)
            if index > list.loadedIndexRange.lowerBound {
                let previous = list.loadedItemView(at: index - 1)!
                #expect(abs(view.frame.minY - previous.frame.maxY) < 1e-6)
            }
        }
    }
    @Test func nodeMeasurementLeavesAnOpenFrontierWithoutBlockingMain() async {
        let gate = MeasurementGate(), calls = Mutex((count: 0, onMain: false))
        let rows = (0..<100).map { index in
            NodeRow(identity: "node-\(index)", measurer: gate) {
                calls.withLock { $0.count += 1; $0.onMain = $0.onMain || Thread.isMainThread }
                return UltraNode()
            }
        }
        let list = list(count: 0)
        list.applyChanges(items: rows)
        #expect(list.loadedItemViews.isEmpty)
        #expect(list.engine.offset == 0)
        for _ in 0..<20 {
            if calls.withLock({ $0.count > 0 }) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(calls.withLock { $0.count > 0 && !$0.onMain })
        await gate.open()
        for _ in 0..<40 {
            if !list.loadedItemViews.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(!list.loadedItemViews.isEmpty)
        #expect(list.loadedItemViews.count < 20)
        #expect(list.settledFrame(at: 0)?.height == 60)
        list.applyChanges(items: [])
    }
    @Test func invertedHeightAnimationPreservesTheSameRowBoundary() {
        let list = list(count: 0)
        var rows = (0..<10).map { FixedRow(identity: String($0), height: 100, inverted: true) }
        list.applyChanges(items: rows)
        rows[0].height = 160; rows[0].revision = 1
        list.applyChanges(items: rows, transition: .easeInOut(2))
        let first = list.presentedFrame(at: 0)!, second = list.presentedFrame(at: 1)!
        #expect(abs(first.minY) < 0.1)
        #expect(first.height < 101)
        #expect(abs(first.maxY - second.minY) < 0.1)
    }
    @Test func defaultNodeRowMeasuresDrawsAndSignalsReadinessOffMain() async {
        let before = Diagnostics.shared.counts
        let window = makeWindow()
        window.frame = .init(x: 0, y: 0, width: 320, height: 400)
        let list = list(count: 0)
        window.addSubview(list); window.isHidden = false
        defer { window.isHidden = true }
        var readySignals = 0
        list.onVisibleWindowChanged = { [weak list] in
            for view in list?.loadedItemViews ?? [] { view.onDisplayReady = { readySignals += 1 } }
        }
        list.applyChanges(items: [NodeRow(identity: "measured") {
            var style = Style(); style.padding = 8; style.backgroundColor = .white
            return UltraNode(style: style, children: [UltraTextNode("Text measured before mounting. " + String(repeating: "A longer paragraph. ", count: 8))])
        }])
        for _ in 0..<100 {
            if list.loadedItemViews.first?.isDisplayReady == true { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(list.loadedItemViews.first?.isDisplayReady == true)
        #expect(readySignals == 1)
        #expect((list.settledFrame(at: 0)?.height ?? 0) > 20)
        #expect((Diagnostics.shared.counts - before).mainThreadWork == 0)
        list.applyChanges(items: [])
    }
    @Test func animatedGrowthStartsFromOldHeight() {
        let list = list(count: 10)
        var items = (0..<10).map { FixedRow(identity: String($0)) }
        items[0].height = 120; items[0].revision = 1
        list.applyChanges(items: items, transition: .easeInOut(1))
        #expect(list.settledFrame(at: 0)!.height == 120)
        #expect(list.presentedFrame(at: 0)!.height < 52)
        #expect(abs(list.presentedFrame(at: 1)!.minY - list.presentedFrame(at: 0)!.maxY) < 1)
    }
    @Test func revisedNodeRowsKeepReadyContentAndAdvanceBeforeTheNewestCommit() async throws {
        func row(_ revision: UInt64) -> NodeRow {
            NodeRow(identity: "stream", revision: revision) {
                var style = Style(); style.height = .points(60 + Double(revision) * 20); style.backgroundColor = .white
                return UltraNode(style: style, children: [UltraTextNode("Revision \(revision)")])
            }
        }
        let environment = RenderEnvironment(), original = row(0), replacement = row(1), newest = row(2)
        _ = await original.measure(width: 320, environment: environment)
        // Measured before the row is on screen, so their content isn't drawn
        // ahead: this is the path where a revision arrives after its pass.
        _ = await replacement.measure(width: 320, environment: environment)
        _ = await newest.measure(width: 320, environment: environment)
        let view = original.makeView()
        view.frame = .init(x: 0, y: 0, width: 320, height: 60)
        let window = makeWindow(); window.addSubview(view); window.isHidden = false
        defer { window.isHidden = true }
        view.applyMeasurement(width: 320, height: 60, environment: environment)
        for _ in 0..<100 {
            if view.isDisplayReady { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let shown = try #require(view.subviews.first as? NodeHostView)
        #expect(view.isDisplayReady && !shown.isHidden)
        var displayed: [String] = []
        view.onDisplayReady = {
            if let host = view.subviews.compactMap({ $0 as? NodeHostView }).first(where: { !$0.isHidden }),
               let text = host.rootNode.children.first as? UltraTextNode { displayed.append(text.text) }
        }
        replacement.apply(to: view, transition: .easeInOut(0.3))
        view.applyMeasurement(width: 320, height: 80, environment: environment)
        let inFlight = try #require(view.subviews.last as? NodeHostView)
        #expect(shown.superview === view && !shown.isHidden)
        #expect(inFlight !== shown && inFlight.isHidden)
        view.bounds.size.height = 80; view.layoutIfNeeded()
        #expect(shown.bounds.height == 60 && shown.hasContent)
        newest.apply(to: view, transition: .easeInOut(0.3))
        view.applyMeasurement(width: 320, height: 100, environment: environment)
        #expect(inFlight.superview === view && inFlight.isHidden)
        #expect(view.subviews.last === inFlight)
        #expect(shown.superview === view && !shown.isHidden && view.isDisplayReady)
        for _ in 0..<100 {
            if displayed.last == "Revision 2" { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(displayed == ["Revision 1", "Revision 2"])
        #expect(shown.superview == nil)
        #expect(inFlight.superview == nil)
        let candidate = try #require(view.subviews.first as? NodeHostView)
        #expect(view.subviews.count == 1)
        #expect(!candidate.isHidden && candidate.hasContent)
    }
    @Test(arguments: [(88.0, 240.0), (240.0, 88.0)]) func aRowOnScreenShowsItsNewRevisionWithItsNewSizeAtOnce(from: Double, to: Double) async throws {
        func row(_ revision: UInt64, height: Double) -> NodeRow {
            NodeRow(identity: "resizing", revision: revision) {
                var style = Style(); style.height = .points(height); style.backgroundColor = .white
                let label = UltraTextNode("Revision \(revision)")
                label.transitionKey = "label"
                return UltraNode(style: style, children: [label])
            }
        }
        let list = list(count: 0)
        let window = makeWindow(); window.frame = .init(x: 0, y: 0, width: 320, height: 400)
        window.addSubview(list); window.isHidden = false
        defer { window.isHidden = true }
        list.applyChanges(items: [row(0, height: from)], transition: .none)
        for _ in 0..<100 where list.loadedItemViews.first?.isDisplayReady != true { try await Task.sleep(for: .milliseconds(10)) }
        let view = try #require(list.loadedItemViews.first)
        let old = try #require(view.subviews.compactMap { $0 as? NodeHostView }.first { !$0.isHidden })

        // At the end of the pass that gives the row its new size, in the
        // turn that commits that geometry, the row shows the new revision,
        // drawn: never the new size with the old content or none.
        struct Shown { var text: String?; var height: Double; var drawn: Bool; var hosts: Int }
        var atResize: Shown?
        list.onVisibleWindowChanged = {
            guard atResize == nil, list.settledFrame(at: 0).map({ Double($0.height) }) == to else { return }
            let hosts = view.subviews.compactMap { $0 as? NodeHostView }.filter { !$0.isHidden }
            let host = hosts.first
            atResize = Shown(
                text: (host?.rootNode.children.first as? UltraTextNode)?.text,
                height: host.map { Double($0.bounds.height) } ?? 0,
                drawn: host?.view(forTransitionKey: "label")?.layer.contents != nil,
                hosts: hosts.count
            )
        }
        list.applyChanges(items: [row(1, height: to)], transition: .none)
        for _ in 0..<200 where atResize == nil { try await Task.sleep(for: .milliseconds(5)) }
        let shown = try #require(atResize)
        #expect(shown.text == "Revision 1" && shown.height == to && shown.drawn && shown.hosts == 1, "\(shown)")
        #expect(old.superview == nil)
    }
    @Test func nodeRowShrinkKeepsTallReadyContentUntilTheClipFinishes() async throws {
        func row(_ revision: UInt64, height: Double) -> NodeRow {
            NodeRow(identity: "resizing", revision: revision) {
                var style = Style(); style.height = .points(height); style.backgroundColor = .white
                return UltraNode(style: style, children: [UltraTextNode("Ready content")])
            }
        }
        let list = list(count: 0)
        let window = makeWindow(); window.frame = .init(x: 0, y: 0, width: 320, height: 400)
        window.addSubview(list); window.isHidden = false
        defer { window.isHidden = true }
        list.applyChanges(items: [row(0, height: 180)], transition: .none)
        for _ in 0..<100 where list.loadedItemViews.first?.isDisplayReady != true { try await Task.sleep(for: .milliseconds(10)) }
        let view = try #require(list.loadedItemViews.first)
        let tall = try #require(view.subviews.first as? NodeHostView)
        list.applyChanges(items: [row(1, height: 70)], transition: .easeInOut(0.4))
        for _ in 0..<100 where list.settledFrame(at: 0)?.height != 70 { try await Task.sleep(for: .milliseconds(10)) }
        list.layoutIfNeeded(); view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        #expect(view.clipsToBounds)
        #expect(tall.superview === view && !tall.isHidden && tall.bounds.height == 180)
        #expect(view.layer.animation(forKey: "ultraview.list.height") != nil)
        try await Task.sleep(for: .milliseconds(450))
        #expect(tall.superview == nil)
        #expect(view.subviews.count == 1 && view.subviews[0].bounds.height == 70)
    }
    @Test(arguments: ScrollEngineMode.allCases) func accessibilityPagesUseTheVisibleHeightAndClamp(mode: ScrollEngineMode) throws {
        let list = list(mode, count: 100)
        list.applyChanges(newInsets: .init(top: 20, bottom: 30))
        let before = try #require(list.settledFrame(at: 10)).minY
        #expect(!list.accessibilityScroll(.previous))
        #expect(!list.accessibilityScroll(.left))
        #expect(list.accessibilityScroll(.next))
        #expect(abs(before - (try #require(list.settledFrame(at: 10))).minY - 350) < 0.01)
        #expect(list.accessibilityScroll(.previous))
        #expect(abs((try #require(list.settledFrame(at: 0))).minY - 20) < 0.01)
        #expect(!list.accessibilityScroll(.up))
        list.scrollTo(.init(index: 99), transition: .immediate)
        #expect(!list.accessibilityScroll(.down))
    }
    @Test func invertedAccessibilityDirectionsFollowTheScreen() throws {
        let list = list(count: 100)
        list.contentView.transform = .init(scaleX: 1, y: -1)
        #expect(!list.accessibilityScroll(.down))
        let before = try #require(list.settledFrame(at: 10)).minY
        #expect(list.accessibilityScroll(.up))
        #expect(abs(before - (try #require(list.settledFrame(at: 10))).minY - 400) < 0.01)
        #expect(list.accessibilityScroll(.next))
        #expect(abs((try #require(list.settledFrame(at: 0))).minY) < 0.01)
    }
    @Test func accessibilityFocusReturnsToTheRecreatedRow() throws {
        let list = list(count: 100)
        let first = try #require(list.loadedItemView(at: 0))
        var requested: [UIView] = []
        list.accessibilityCoordinator.notify = { kind, target in
            if kind == .layoutChanged, let view = target as? UIView { requested.append(view) }
        }
        list.accessibilityCoordinator.recordFocus(first)
        #expect(list.accessibilityScroll(.next))
        let fallback = try #require(requested.last)
        #expect(fallback !== first)
        list.accessibilityCoordinator.recordFocus(fallback)
        #expect(list.accessibilityCoordinator.preferredIdentity == "0")
        #expect(list.accessibilityScroll(.previous))
        let recreated = try #require(list.loadedItemView(at: 0))
        #expect(recreated !== first)
        #expect(requested.last === recreated)
        list.accessibilityCoordinator.recordFocus(recreated)
        list.applyChanges(items: Array(list.items.dropFirst()))
        #expect(list.accessibilityCoordinator.preferredIdentity != "0")
        #expect(requested.last !== recreated)
    }
    @Test func targetResolverUsesMeasuredHeightOnce() {
        let list = list(); var calls = 0
        list.scrollTo(.init(index: 500, resolve: { height, view in calls += 1; #expect(view != nil); return 200 - height / 2 }), transition: .immediate)
        #expect(calls == 1)
        #expect(list.settledFrame(at: 500)!.midY == 200)
    }
    @Test func pinLatchReleasesOnlyOnDrag() {
        let list = list(count: 3)
        let rows = [FixedRow(identity: "a", height: 100), FixedRow(identity: "b", height: 60, pinsToBottomEdge: true), FixedRow(identity: "c", height: 50)]
        list.applyChanges(items: rows, scrollTo: .init(index: 1), transition: .none)
        #expect(list.holdsPinnedRow)
        #expect(abs(list.presentedFrame(at: 1)!.maxY - 400) < 0.5)
        list.setScrollOffset(list.currentScrollOffset)
        #expect(list.holdsPinnedRow)
        list.handleDragBegin()
        #expect(!list.holdsPinnedRow)
        #expect(list.currentBottomEdgePinSlack > 0)
    }
    @Test func reentrantPassPreservesItsArguments() async {
        let list = list(count: 2)
        var changed = [FixedRow(identity: "0", revision: 1), FixedRow(identity: "1")]
        changed[0].onApply = { [weak list] in list?.applyChanges(newInsets: .init(top: 25), transition: .immediate) }
        list.applyChanges(items: changed)
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(abs(list.settledFrame(at: 0)!.minY - 25) < 0.5)
    }
    @Test func finiteInsetSurvivesPlatformLayout() {
        let list = list(.uiKit, count: 5)
        list.applyChanges(newInsets: .init(top: 100))
        let offset = list.currentScrollOffset
        list.setNeedsLayout(); list.layoutIfNeeded()
        #expect(abs(list.currentScrollOffset - offset) < 0.5)
    }
    @Test func visibilityUsesStrictPositiveIntersection() {
        let list = list(count: 20)
        let first = list.loadedItemView(at: 0) as! FixedRowView
        #expect(first.visible?.height == 50)
        list.setScrollOffset(50); list.handleScroll(50)
        #expect(first.visible == nil)
    }
    @Test func programmaticWritesDoNotPublishScroll() {
        let engine = PhysicsEngine(mode: .keyframe); var callbacks = 0
        engine.onScroll = { _ in callbacks += 1 }
        engine.setOffset(200); engine.shift(by: 50); engine.setEdges(.init()); engine.sync(); engine.halt(); engine.reanchorDrag()
        #expect(callbacks == 0)
        #expect(engine.offset == 250)
    }
    @Test func recognizerExcludesSimultaneityAndDoesNotDelayTouchUp() {
        let engine = PhysicsEngine(mode: .keyframe)
        #expect(!engine.pan.delaysTouchesEnded)
        #expect(!engine.gestureRecognizer(engine.pan, shouldRecognizeSimultaneouslyWith: UITapGestureRecognizer()))
        #expect(engine.pan.allowedScrollTypesMask == .continuous)
    }
    @Test func flightParksModelAndTeardownCatchesLivePosition() async {
        let engine = PhysicsEngine(mode: .keyframe)
        engine.host.frame = .init(x: 0, y: 0, width: 320, height: 400)
        engine.beginMomentum(velocity: 3000)
        #expect(engine.activeFlight != nil)
        #expect(engine.host.bounds.origin.y > engine.offset + 1000)
        try? await Task.sleep(for: .milliseconds(30))
        engine.teardown()
        #expect(engine.activeFlight == nil)
        #expect(engine.host.layer.animationKeys()?.isEmpty ?? true)
        #expect(engine.offset > 10)
    }
    @Test(arguments: [false, true]) func aFlightShowsItsStartingPositionBeforeItsLayerStart(repark: Bool) async throws {
        let window = makeWindow()
        window.frame = .init(x: 0, y: 0, width: 320, height: 400)
        let engine = PhysicsEngine(mode: .keyframe)
        engine.host.frame = window.bounds; window.addSubview(engine.host); window.isHidden = false
        defer { engine.teardown(); window.isHidden = true }
        engine.host.layer.speed = 0; engine.host.layer.timeOffset = 100
        engine.setOffset(1000); engine.beginMomentum(velocity: 3000)
        if repark { engine.shift(by: 500) }
        let flight = try #require(engine.activeFlight)
        let start = flight.offset(at: flight.beginTime)
        #expect(abs(engine.host.bounds.minY - start) > 1000)
        engine.host.layer.timeOffset = flight.beginTime - 0.01
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(35))
        let shown = try #require(engine.host.layer.presentation()?.bounds.minY)
        #expect(abs(shown - start) < 0.5)
    }
    @Test func frozenFlightMutationPreservesActualListGeometry() {
        let list = list(count: 1000)
        list.layer.speed = 0; list.layer.timeOffset = 100
        list.beginMomentum(velocity: 5000)
        let trajectory = list.engine.activeFlight!.trajectory
        let before = list.presentedFrame(at: 5)!
        var rows: [any ListRow] = list.items
        for insertion in 1...12 {
            rows.insert(FixedRow(identity: "inserted-\(insertion)", height: 70), at: 0)
            list.applyChanges(items: rows, anchorMode: .preserveVisibleContent, transition: .easeInOut(0.4))
            let after = list.presentedFrame(at: 5 + insertion)!
            #expect(abs(after.minY - before.minY) < 0.001)
            #expect(list.engine.activeFlight!.trajectory == trajectory)
            #expect(abs(after.minY + 5 - before.minY) > 4.9)
        }
        list.haltScrolling()
    }
    @Test func incomingUnmatchedSurvivorsKeepTheirSpacing() {
        let list = list(count: 1000)
        list.layer.speed = 0; list.layer.timeOffset = 100
        list.scrollTo(.init(index: 500), transition: .immediate)
        let next = list.items.filter { !(493...500).contains(Int($0.identity)!) }
        list.applyChanges(items: next, transition: .easeInOut(1))
        let incoming = list.loadedIndexRange.filter { index in
            let identity = Int(next[index].identity)!
            return identity < 493
        }
        #expect(incoming.count >= 2)
        for (a, b) in zip(incoming, incoming.dropFirst()) {
            let first = list.presentedFrame(at: a)!, second = list.presentedFrame(at: b)!
            #expect(abs(first.maxY - second.minY) < 0.001)
        }
    }
    @Test func departingRowsReceiveLaterHorizontalViewportChanges() {
        let list = list(count: 10)
        let departed = WeakReference(list.loadedItemView(at: 0))
        list.applyChanges(items: Array(list.items.dropFirst()), transition: .easeInOut(3))
        #expect(departed.value != nil)
        list.applyChanges(newInsets: .init(left: 20, right: 20), transition: .easeInOut(1))
        #expect(departed.value?.bounds.width == 280)
        #expect(departed.value?.frame.minX == 20)
        #expect(departed.value?.layer.animation(forKey: "ultraview.list.width") != nil)
    }
    @Test func overlayPassesEmptySpaceToRows() {
        let overlay = PassthroughView(frame: .init(x: 0, y: 0, width: 300, height: 400))
        #expect(!overlay.point(inside: .init(x: 100, y: 100), with: nil))
        let button = UIButton(frame: .init(x: 10, y: 10, width: 50, height: 30)); overlay.addSubview(button)
        #expect(overlay.point(inside: .init(x: 20, y: 20), with: nil))
        #expect(!overlay.point(inside: .init(x: 100, y: 100), with: nil))
    }
    @Test func compilerKeepsAdditiveAndAbsoluteKindsAndSlowFactor() {
        let transition = ListTransition(duration: 0.5, curve: .spring).scaled(by: 10)
        let track = AnimationTrack(generation: 7, from: 100, to: 0, startTime: 10, transition: transition)
        let position = AnimationController.compile(.positionY, track: track)
        #expect(position is CASpringAnimation)
        #expect(position.isAdditive)
        #expect(abs(Double(position.speed) - 0.1) < 1e-6)
        #expect(!AnimationController.compile(.height, track: track).isAdditive)
    }
    @Test func emptyAndFullReplaceDoNotRetainLiveViews() {
        let list = autoreleasepool { list(count: 10) }
        let old = WeakReference(list.loadedItemView(at: 0))
        autoreleasepool { list.applyChanges(items: [FixedRow(identity: "fresh")], transition: .none) }
        #expect(list.loadedItemViews.count == 1)
        #expect(old.value == nil)
        list.applyChanges(items: [])
        #expect(list.loadedItemViews.isEmpty && list.loadedIndexRange.isEmpty)
    }
}
#endif