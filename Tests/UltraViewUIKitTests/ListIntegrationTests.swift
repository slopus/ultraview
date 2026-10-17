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
    func makeView() -> ListRowView { FixedRowView() }
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
    func list(_ mode: ScrollEngineMode = .keyframe, count: Int = 1000) -> UltraListView {
        let list = UltraListView(engineMode: mode)
        list.frame = .init(x: 0, y: 0, width: 320, height: 400)
        list.layoutIfNeeded()
        list.applyChanges(items: (0..<count).map { FixedRow(identity: String($0)) })
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
    @Test func targetResolverUsesMeasuredHeightOnce() {
        let list = list(); var calls = 0
        list.scrollTo(.init(index: 500, resolve: { height, view in calls += 1; #expect(view != nil); return 200 - height / 2 }), transition: .immediate)
        #expect(calls == 1)
        #expect(list.settledFrame(at: 500)!.midY == 200)
    }
    @Test func pinLatchReleasesOnlyOnDrag() {
        let list = list(count: 3)
        let rows = [FixedRow(identity: "a", height: 100), FixedRow(identity: "b", height: 60, pinsToBottomEdge: true), FixedRow(identity: "c", height: 50)]
        list.applyChanges(items: rows, scrollTo: .init(index: 1))
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
        autoreleasepool { list.applyChanges(items: [FixedRow(identity: "fresh")]) }
        #expect(list.loadedItemViews.count == 1)
        #expect(old.value == nil)
        list.applyChanges(items: [])
        #expect(list.loadedItemViews.isEmpty && list.loadedIndexRange.isEmpty)
    }
}
#endif