#if canImport(UIKit)
import UIKit
import QuartzCore
import Testing
import UltraCore
@testable import UltraList

@MainActor
private final class SwipeLog {
    var performed: [String] = []
    var rows: [SwipeRow] = []
    /// How much a delete resizes the row before the deleted one in the same pass.
    var resizesPrevious = 0.0
    weak var list: UltraListView?
    func delete(_ identity: String) {
        performed.append("delete:\(identity)")
        if let index = rows.firstIndex(where: { $0.identity == identity }), index > 0, resizesPrevious != 0 {
            rows[index - 1].height += resizesPrevious; rows[index - 1].revision += 1
        }
        rows.removeAll { $0.identity == identity }
        list?.applyChanges(items: rows)
    }
}

@MainActor
private struct SwipeRow: ListRow {
    var identity: String
    var revision: UInt64 = 0
    var height: Double = 80
    var inverted = false
    var leadingSwipeActions: [ListSwipeAction] = []
    var trailingSwipeActions: [ListSwipeAction] = []
    func makeView() -> ListRowView { SwipeRowView() }
    func apply(to view: ListRowView, transition: ListTransition) {
        (view as? SwipeRowView)?.height = height
        view.transform = inverted ? .init(scaleX: 1, y: -1) : .identity
        view.isAccessibilityElement = true; view.accessibilityLabel = identity
    }
}

@MainActor
private final class SwipeRowView: ListRowView {
    var height: Double = 80
    let fill = UIView()
    override init(frame: CGRect) {
        super.init(frame: frame)
        fill.backgroundColor = .systemBlue; addSubview(fill)
    }
    override func update(width: Double, transition: ListTransition) -> Double { height }
    override func layoutSubviews() { super.layoutSubviews(); fill.frame = bounds }
}

@MainActor
private final class SwipeFixture {
    let window = makeWindow()
    let list: UltraListView
    let log = SwipeLog()
    var controller: ListSwipeController { list.swipeActions }
    init(mode: ScrollEngineMode, inverted: Bool = false, count: Int = 30, leading: Bool = true) {
        window.frame = .init(x: 0, y: 0, width: 390, height: 700)
        list = UltraListView(engineMode: mode)
        list.frame = window.bounds
        if inverted { list.contentView.transform = .init(scaleX: 1, y: -1) }
        window.addSubview(list); window.isHidden = false
        log.list = list
        log.rows = (0..<count).map { index in
            let identity = "r\(index)"
            var row = SwipeRow(identity: identity, inverted: inverted)
            row.trailingSwipeActions = [
                ListSwipeAction(title: "Delete", isDestructive: true) { [log] in log.delete(identity) },
                ListSwipeAction(title: "Archive", color: .systemIndigo) { [log] in log.performed.append("archive:\(identity)") },
            ]
            if leading { row.leadingSwipeActions = [ListSwipeAction(title: "Pin", color: .systemOrange) { [log] in log.performed.append("pin:\(identity)") }] }
            return row
        }
        list.applyChanges(items: log.rows, transition: .none)
        list.layoutIfNeeded()
    }
    func view(_ identity: String) -> ListRowView? {
        list.loadedIndexRange.first { list.items[$0].identity == identity }.flatMap { list.loadedItemView(at: $0) }
    }
    func presentedOffset(_ identity: String) -> Double {
        guard let layer = view(identity)?.layer else { return .nan }
        return Double((layer.presentation() ?? layer).sublayerTransform.m41)
    }
    /// How far the shown buttons are from covering exactly the uncovered part of the row.
    static func detachment(_ view: UIView) -> Double {
        let layer = view.layer.presentation() ?? view.layer
        let offset = Double(layer.sublayerTransform.m41)
        let buttons = (layer.sublayers ?? []).filter { $0.name?.hasPrefix("swipe:") == true }
        guard abs(offset) > 1e-6 else { return 0 }
        guard !buttons.isEmpty else { return abs(offset) }
        let width = Double(layer.bounds.width)
        let spans = buttons.map { button -> (Double, Double) in
            let shown = button.presentation() ?? button
            let minX = Double(shown.position.x) + offset
            return (minX, minX + Double(shown.bounds.width))
        }.sorted { $0.0 < $1.0 }
        var union = spans[0], error = 0.0
        for span in spans.dropFirst() {
            if span.0 > union.1 + 0.01 { error = max(error, span.0 - union.1) }
            union = (union.0, max(union.1, span.1))
        }
        let expected = offset < 0 ? (width + offset, width) : (0, offset)
        return max(error, abs(union.0 - expected.0), abs(union.1 - expected.1))
    }
    /// Sampled rendering frames until `seconds` pass.
    func frames(_ seconds: Double, _ body: (Int) -> Void) async {
        let end = CACurrentMediaTime() + seconds
        var frame = 0
        while CACurrentMediaTime() < end {
            try? await Task.sleep(for: .milliseconds(8))
            body(frame); frame += 1
        }
    }
}

@MainActor
@Suite(.serialized) struct SwipeActionTests {
    nonisolated static let configurations: [(ScrollEngineMode, Bool)] = ScrollEngineMode.allCases.flatMap { [($0, false), ($0, true)] }

    @Test(arguments: configurations)
    func trackingFollowsTheFingerAndButtonsStayOnTheEdge(mode: ScrollEngineMode, inverted: Bool) async throws {
        let fixture = SwipeFixture(mode: mode, inverted: inverted)
        let controller = fixture.controller
        controller.simulateBegin("r3")
        var maximumError = 0.0, maximumDetach = 0.0
        for step in 0...40 {
            let dx = -Double(step) * 9.5
            controller.simulateDrag(dx)
            try await Task.sleep(for: .milliseconds(9))
            // One to one up to the row width, so these presentation values are exact.
            maximumError = max(maximumError, abs(fixture.presentedOffset("r3") - dx))
            maximumDetach = max(maximumDetach, SwipeFixture.detachment(try #require(fixture.view("r3"))))
        }
        #expect(maximumError < 1e-6, "\(mode) inverted \(inverted)")
        #expect(maximumDetach <= 0.5, "\(mode) inverted \(inverted): \(maximumDetach)")
        // Past the row width the reveal rubber-bands and stays below the finger.
        controller.simulateDrag(-500)
        let banded = try #require(controller.revealOffset("r3"))
        #expect(banded < -390 && banded > -500)
        // Haptic: one tick for the one crossing, however many moves follow.
        #expect(controller.hapticCount == 1)
        for dx in stride(from: -500.0, through: -260, by: 20) { controller.simulateDrag(dx) }
        #expect(controller.hapticCount == 1)
        controller.simulateDrag(-100)
        controller.simulateDrag(-300)
        #expect(controller.hapticCount == 2)
        controller.simulateDrag(-100)
        controller.simulateRelease(velocity: 0)
        await fixture.frames(0.7) { _ in }
    }

    @Test(arguments: configurations)
    func releaseSpringsSettleExactlyOpenAndClosedWithButtonsAttached(mode: ScrollEngineMode, inverted: Bool) async throws {
        let fixture = SwipeFixture(mode: mode, inverted: inverted)
        let controller = fixture.controller
        let view = try #require(fixture.view("r4"))
        #expect(view.layer.masksToBounds == false)
        controller.simulateBegin("r4")
        controller.simulateDrag(-90)
        controller.simulateRelease(velocity: -400)
        #expect(controller.revealOffset("r4") == -152)
        var previous = -90.0, maximumDetach = 0.0, samples = 0, overshoot = 0.0
        await fixture.frames(0.7) { _ in
            let shown = fixture.presentedOffset("r4")
            overshoot = max(overshoot, -152 - shown)
            // Toward −152 without passing it; never backwards past the release point.
            #expect(shown <= previous + 1e-6)
            previous = shown; samples += 1
            maximumDetach = max(maximumDetach, SwipeFixture.detachment(view))
        }
        #expect(samples > 20)
        #expect(overshoot <= 1e-6)
        #expect(maximumDetach <= 0.5, "\(mode) \(inverted): \(maximumDetach)")
        #expect(fixture.presentedOffset("r4") == -152)
        #expect(view.layer.animationKeys()?.contains { $0.hasPrefix("ultraview.swipe") } != true)
        #expect(controller.revealedIdentity == "r4")
        // A tap outside the buttons closes it, again exactly.
        controller.simulateTap(button: nil)
        maximumDetach = 0
        await fixture.frames(0.7) { _ in maximumDetach = max(maximumDetach, SwipeFixture.detachment(view)) }
        #expect(maximumDetach <= 0.5)
        #expect(fixture.presentedOffset("r4") == 0)
        #expect(controller.revealedIdentity == nil)
        #expect(CATransform3DIsIdentity(view.layer.sublayerTransform))
        #expect(view.layer.sublayers?.contains { $0.name?.hasPrefix("swipe:") == true } != true)
        #expect(view.layer.masksToBounds == false, "the row's own clipping is given back")
        // Leading side: the pin button sits at the left edge.
        controller.simulateBegin("r6")
        controller.simulateDrag(60)
        let leading = try #require(fixture.view("r6"))
        #expect(SwipeFixture.detachment(leading) <= 0.5)
        controller.simulateRelease(velocity: 300)
        await fixture.frames(0.6) { _ in maximumDetach = max(maximumDetach, SwipeFixture.detachment(leading)) }
        #expect(fixture.presentedOffset("r6") == 76)
        #expect(maximumDetach <= 0.5)
        controller.simulateTap(button: 0)
        #expect(fixture.log.performed == ["pin:r6"])
        await fixture.frames(0.6) { _ in }
        #expect(controller.revealedIdentity == nil)
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func onlyOneRowIsOpen(mode: ScrollEngineMode) async throws {
        let fixture = SwipeFixture(mode: mode)
        let controller = fixture.controller
        controller.simulateBegin("r2"); controller.simulateDrag(-200); controller.simulateRelease(velocity: 0)
        await fixture.frames(0.6) { _ in }
        #expect(controller.revealedIdentity == "r2")
        controller.simulateBegin("r5")
        #expect(controller.revealedIdentity == "r5")
        controller.simulateDrag(-100); controller.simulateRelease(velocity: 0)
        await fixture.frames(0.7) { _ in
            let open = ["r2", "r5"].filter { abs(fixture.presentedOffset($0)) > 0.5 }
            #expect(open.count <= 2)
        }
        #expect(fixture.presentedOffset("r2") == 0)
        #expect(fixture.presentedOffset("r5") == -152)
        #expect(controller.revealedIdentity == "r5")
    }

    @Test(arguments: configurations)
    func fullSwipeDeleteKeepsNeighboursAgainstTheCollapsingRow(mode: ScrollEngineMode, inverted: Bool) async throws {
        try await checkFullSwipeDelete(mode: mode, inverted: inverted, resizesPrevious: 0)
    }

    /// A chat delete can change the look, and so the height, of the message
    /// before it in the same pass: both neighbours then move.
    @Test(arguments: configurations)
    func fullSwipeDeleteThatResizesTheRowBeforeKeepsTheSeams(mode: ScrollEngineMode, inverted: Bool) async throws {
        try await checkFullSwipeDelete(mode: mode, inverted: inverted, resizesPrevious: 5)
        try await checkFullSwipeDelete(mode: mode, inverted: inverted, resizesPrevious: -5)
    }

    private func checkFullSwipeDelete(mode: ScrollEngineMode, inverted: Bool, resizesPrevious: Double) async throws {
        let fixture = SwipeFixture(mode: mode, inverted: inverted)
        fixture.log.resizesPrevious = resizesPrevious
        let controller = fixture.controller, list = fixture.list
        let ghost = try #require(fixture.view("r3"))
        let space = list.contentView.layer
        func shown(_ view: UIView) -> CGRect {
            let layer = view.layer.presentation() ?? view.layer
            return layer.convert(layer.bounds, to: space.presentation() ?? space)
        }
        controller.simulateBegin("r3")
        for dx in stride(from: 0.0, through: -320, by: -20) { controller.simulateDrag(dx) }
        #expect(controller.hapticCount == 1)
        controller.simulateRelease(velocity: -800)
        #expect(fixture.log.performed == ["delete:r3"])
        #expect(!list.items.contains { $0.identity == "r3" })
        #expect(ghost.superview != nil, "the departing row stays on screen while it collapses")
        var maximumSeam = 0.0, maximumDrift = 0.0, maximumDetach = 0.0, frames = 0, straddled = 0
        var worst: [String: Double] = [:]
        await fixture.frames(0.45) { frame in
            let rows = list.loadedIndexRange.compactMap { list.loadedItemView(at: $0) }.map { (model: $0.convert($0.bounds, to: list.contentView), shown: shown($0)) }.sorted { $0.shown.minY < $1.shown.minY }
            let departing = shown(ghost)
            maximumDetach = max(maximumDetach, SwipeFixture.detachment(ghost))
            for (a, b) in zip(rows, rows.dropFirst()) {
                if departing.height > 0.25, departing.midY > a.shown.midY, departing.midY < b.shown.midY {
                    straddled += 1
                    let seam = max(abs(departing.minY - a.shown.maxY), abs(b.shown.minY - departing.maxY))
                    if seam > maximumSeam { maximumSeam = seam; worst = ["frame": Double(frame), "previous": a.shown.maxY, "top": departing.minY, "bottom": departing.maxY, "next": b.shown.minY] }
                } else {
                    // No row the ghost isn't between may open or close a gap.
                    let gap = b.shown.minY - a.shown.maxY, settled = b.model.minY - a.model.maxY
                    if departing.height <= 0.25 || departing.maxY <= a.shown.minY || departing.minY >= b.shown.maxY { maximumDrift = max(maximumDrift, abs(gap - settled)) }
                }
            }
            frames += 1
        }
        let label = "\(mode) inverted \(inverted) resizing \(resizesPrevious)"
        #expect(frames > 20)
        #expect(straddled > 15, "the collapsing row was seen between its neighbours")
        #expect(maximumSeam <= 0.5, "\(label): \(worst)")
        #expect(maximumDrift <= 0.5, "\(label)")
        #expect(maximumDetach <= 0.5, "\(label)")
        await fixture.frames(0.3) { _ in }
        #expect(ghost.superview == nil)
        #expect(controller.revealedIdentity == nil)
        // Settled: contiguous rows and nothing left of the reveal.
        let rows = list.loadedIndexRange.compactMap { list.settledFrame(at: $0) }
        for (a, b) in zip(rows, rows.dropFirst()) { #expect(abs(b.minY - a.maxY) <= 0.5) }
    }

    @Test func handlersAndCustomActionsFollowTheNewestRevision() async throws {
        let fixture = SwipeFixture(mode: .keyframe)
        let list = fixture.list, log = fixture.log
        let view = try #require(fixture.view("r1"))
        #expect(view.accessibilityCustomActions?.map(\.name) == ["Pin", "Delete", "Archive"])
        var rows = log.rows
        rows[1].revision = 1
        rows[1].trailingSwipeActions = [ListSwipeAction(title: "Archive", color: .systemIndigo) { [log] in log.performed.append("archive-v1:r1") }]
        log.rows = rows
        list.applyChanges(items: rows, transition: .none)
        #expect(view.accessibilityCustomActions?.map(\.name) == ["Pin", "Archive"])
        let archive = try #require(view.accessibilityCustomActions?.last)
        _ = archive.actionHandler?(archive)
        #expect(log.performed == ["archive-v1:r1"])
        // A row that loses its actions loses its custom actions.
        rows[1].revision = 2; rows[1].leadingSwipeActions = []; rows[1].trailingSwipeActions = []
        log.rows = rows
        list.applyChanges(items: rows, transition: .none)
        #expect(view.accessibilityCustomActions?.isEmpty ?? true)
        // Custom actions a row sets itself are left alone.
        let own = UIAccessibilityCustomAction(name: "Own") { _ in true }
        view.accessibilityCustomActions = [own]
        rows[1].revision = 3; log.rows = rows
        list.applyChanges(items: rows, transition: .none)
        #expect(view.accessibilityCustomActions?.map(\.name) == ["Own"])
    }

    @Test func listPassesAndScrollingLeaveTheRevealAlone() async throws {
        let fixture = SwipeFixture(mode: .keyframe)
        let list = fixture.list, controller = fixture.controller
        controller.simulateBegin("r2"); controller.simulateDrag(-120); controller.simulateRelease(velocity: 0)
        await fixture.frames(0.6) { _ in }
        let view = try #require(fixture.view("r2"))
        #expect(view.layer.sublayerTransform.m41 == -152)
        // A revision of the open row, a resize of another and a short scroll.
        var rows = fixture.log.rows
        rows[2].revision = 1; rows[5].height = 140; rows[5].revision = 1
        fixture.log.rows = rows
        list.applyChanges(items: rows, transition: .easeInOut(0.2))
        list.setScrollOffset(list.currentScrollOffset + 30)
        await fixture.frames(0.4) { _ in #expect(SwipeFixture.detachment(view) <= 0.5) }
        #expect(view.layer.sublayerTransform.m41 == -152)
        #expect(controller.revealedIdentity == "r2")
        // A row scrolled out of the window is closed and released.
        list.scrollTo(.init(index: 25), transition: .none)
        list.layoutIfNeeded()
        #expect(controller.revealedIdentity == nil)
        #expect(CATransform3DIsIdentity(view.layer.sublayerTransform))
    }

    @Test func rowsWithoutActionsAreUntouched() async throws {
        let window = makeWindow()
        window.frame = .init(x: 0, y: 0, width: 390, height: 600)
        let list = UltraListView(engineMode: .keyframe)
        list.frame = window.bounds; window.addSubview(list); window.isHidden = false
        list.applyChanges(items: (0..<10).map { SwipeRow(identity: "p\($0)") }, transition: .none)
        list.layoutIfNeeded()
        let view = try #require(list.loadedItemView(at: 1))
        #expect(view.accessibilityCustomActions?.isEmpty ?? true)
        list.swipeActions.simulateBegin("p1"); list.swipeActions.simulateDrag(-200)
        #expect(list.swipeActions.revealOffset("p1") == nil)
        #expect(CATransform3DIsIdentity(view.layer.sublayerTransform))
        list.swipeActions.simulateRelease(velocity: 0)
        #expect(list.swipeActions.revealedIdentity == nil)
        // The reveal pan fails at once for touches on these rows, so the list pan never waits.
        #expect(list.swipeActions.tap.isEnabled == false)
    }

    /// Found by the chaos soak: a gesture that outlived its row's reveal opened
    /// the row again without making it the revealed one.
    @Test(arguments: ScrollEngineMode.allCases)
    func closingARowMidGestureEndsTheGesturesHoldOnIt(mode: ScrollEngineMode) async throws {
        let fixture = SwipeFixture(mode: mode)
        let controller = fixture.controller
        func openRows() -> [String] {
            fixture.list.loadedIndexRange.compactMap { index in
                abs(fixture.list.loadedItemView(at: index)?.layer.sublayerTransform.m41 ?? 0) > 0.5 ? fixture.list.items[index].identity : nil
            }
        }
        // close() while the finger is down.
        controller.simulateBegin("r2"); controller.simulateDrag(-60)
        controller.close()
        controller.simulateDrag(-90); controller.simulateRelease(velocity: -400)
        await fixture.frames(0.8) { _ in }
        #expect(controller.revealedIdentity == nil)
        #expect(openRows().isEmpty)
        // A VoiceOver action on the tracked row, then the gesture continues.
        controller.simulateBegin("r3"); controller.simulateDrag(-60)
        let view = try #require(fixture.view("r3"))
        let archive = try #require(view.accessibilityCustomActions?.first { $0.name == "Archive" })
        _ = archive.actionHandler?(archive)
        controller.simulateDrag(-120); controller.simulateRelease(velocity: 0)
        await fixture.frames(0.8) { _ in }
        #expect(controller.revealedIdentity == nil && openRows().isEmpty)
        // The row loses its actions mid-gesture.
        controller.simulateBegin("r4"); controller.simulateDrag(-60)
        fixture.log.rows[4].trailingSwipeActions = []; fixture.log.rows[4].leadingSwipeActions = []; fixture.log.rows[4].revision += 1
        fixture.list.applyChanges(items: fixture.log.rows, transition: .none)
        fixture.list.layoutIfNeeded()
        controller.simulateDrag(-120); controller.simulateRelease(velocity: 0)
        await fixture.frames(0.8) { _ in }
        #expect(controller.revealedIdentity == nil && openRows().isEmpty)
        #expect(fixture.log.performed == ["archive:r3"])
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func externalInputRevealsAndFullSwipesUnderTouchRules(mode: ScrollEngineMode) async throws {
        let fixture = SwipeFixture(mode: mode)
        let controller = fixture.controller
        func send(_ phase: GestureRecording.Event.Phase, _ dx: Double, _ velocity: Double = 0, row: String) {
            controller.receiveInput(.init(time: CACurrentMediaTime(), phase: phase, translation: .init(x: dx), velocity: .init(x: velocity)), row: row)
        }
        // Tracks one to one, then opens on release.
        send(.touchDown, 0, row: "r2"); send(.began, -10, row: "r2")
        for dx in stride(from: -20.0, through: -120, by: -20) { send(.changed, dx, row: "r2") }
        #expect(controller.revealOffset("r2") == -120)
        // A second gesture on another row is ignored while one tracks.
        send(.began, -30, row: "r5")
        #expect(controller.revealOffset("r5") == nil)
        send(.ended, -120, 0, row: "r2")
        await fixture.frames(0.8) { _ in }
        #expect(controller.revealedIdentity == "r2")
        #expect(abs(fixture.presentedOffset("r2") + 152) < 0.01)
        // Rows without actions never begin; a moving list never begins either.
        fixture.log.rows[7].trailingSwipeActions = []; fixture.log.rows[7].leadingSwipeActions = []; fixture.log.rows[7].revision += 1
        fixture.list.applyChanges(items: fixture.log.rows, transition: .none)
        send(.began, -40, row: "r7")
        #expect(controller.revealOffset("r7") == nil && controller.revealedIdentity == "r2")
        fixture.list.beginMomentum(velocity: 2000)
        send(.began, -40, row: "r4")
        #expect(controller.revealOffset("r4") == nil)
        fixture.list.haltScrolling()
        await fixture.frames(0.3) { _ in }
        // A full swipe on another row closes the first and performs the edge action.
        send(.began, -10, row: "r4")
        #expect(controller.revealedIdentity == "r4")
        for dx in stride(from: -60.0, through: -360, by: -60) { send(.changed, dx, row: "r4") }
        send(.ended, -360, -800, row: "r4")
        #expect(fixture.log.performed == ["delete:r4"])
        await fixture.frames(0.8) { _ in }
        #expect(controller.revealedIdentity == nil)
        #expect(abs(fixture.presentedOffset("r2")) < 0.01)
        // A cancel releases without velocity: a short reveal closes and nothing is performed.
        send(.began, 10, row: "r3"); send(.changed, 30, row: "r3"); send(.cancelled, 30, 3000, row: "r3")
        await fixture.frames(0.8) { _ in }
        #expect(controller.revealedIdentity == nil && fixture.log.performed == ["delete:r4"])
    }
}
#endif
