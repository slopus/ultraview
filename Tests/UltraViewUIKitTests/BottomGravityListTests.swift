#if canImport(UIKit)
import UIKit
import QuartzCore
import Testing
import UltraCore
@testable import UltraList

/// A row whose height is a given number of points at 320 points wide and
/// scales with the width, unless it is fixed.
@MainActor
private struct GravityRow: ListRow {
    var identity: String
    var revision: UInt64 = 0
    var height: Double = 50
    var fixed = true
    func makeView() -> ListRowView { GravityRowView() }
    func apply(to view: ListRowView, transition: ListTransition) {
        (view as? GravityRowView)?.height = height; (view as? GravityRowView)?.fixed = fixed
    }
    func isEqual(to other: any ListRow) -> Bool { identity == other.identity && revision == other.revision }
}
@MainActor
private final class GravityRowView: ListRowView {
    var height: Double = 50
    var fixed = true
    override func update(width: Double, transition: ListTransition) -> Double { fixed ? height : (height * 320 / width).rounded() }
}

@MainActor
private struct PreparedGravityRow: ListRow {
    var identity: String
    var measuresAsynchronously: Bool { true }
    func makeView() -> ListRowView { GravityRowView() }
    var slowAwayFrom: Double?
    /// 50 points at 320 wide, scaled with the width; slow at other widths when `slowAwayFrom` is set.
    func prepare(width: Double, environment: RenderEnvironment) async -> ListPreparation? {
        if let slowAwayFrom, width != slowAwayFrom { try? await Task.sleep(for: .milliseconds(150)) }
        return .init(height: (50 * 320 / width).rounded())
    }
}

/// A 320 × 400 chat list with a 20-point top inset and a 30-point composer:
/// the visible band is 20...370.
@MainActor
private final class Chat {
    let list: UltraListView
    let window = makeWindow()
    var rows: [GravityRow]
    static let line = 370.0

    init(_ mode: ScrollEngineMode = .keyframe, count: Int = 100, height: Double = 50, budget: Double = 44) {
        list = UltraListView(engineMode: mode)
        window.frame = .init(x: 0, y: 0, width: 320, height: 400)
        window.isHidden = false
        list.frame = window.bounds
        window.addSubview(list)
        list.bottomGravity = .init(followBudget: budget)
        list.layoutIfNeeded()
        rows = (0..<count).map { GravityRow(identity: "m\($0)", height: height) }
        list.applyChanges(items: rows, newInsets: .init(top: 20, bottom: 30), transition: .none)
    }
    deinit { MainActor.assumeIsolated { window.isHidden = true } }

    func apply(_ transition: ListTransition = .none, scrollTo: ListScrollTarget? = nil) {
        list.applyChanges(items: rows, scrollTo: scrollTo, transition: transition)
    }
    func grow(_ identity: String, by delta: Double, transition: ListTransition = .none) {
        let index = rows.firstIndex { $0.identity == identity }!
        rows[index].height += delta; rows[index].revision += 1
        apply(transition)
    }
    func frame(_ identity: String) -> CGRect? {
        list.items.firstIndex { $0.identity == identity }.flatMap { list.settledFrame(at: $0) }
    }
    func presented(_ identity: String) -> CGRect? {
        list.items.firstIndex { $0.identity == identity }.flatMap { list.presentedFrame(at: $0) }
    }
    /// The first row whose bottom is below the top inset.
    var firstVisible: String? {
        list.loadedIndexRange.first { (list.settledFrame(at: $0)?.maxY ?? 0) > 20 }.map { list.items[$0].identity }
    }
    var lastBottom: Double { Double(list.settledFrame(at: list.items.count - 1)?.maxY ?? .nan) }
    /// Scrolls so row `index` starts `y` points from the top of the list.
    func show(_ index: Int, at y: Double = 20) {
        list.scrollTo(.init(index: index, pointOffset: y - 20), transition: .none)
    }
    func drag(_ phase: GestureRecording.Event.Phase, _ translation: Double, at time: Double) {
        list.receiveScrollInput(.init(time: time, phase: phase, translation: .init(y: translation)))
    }
}

@MainActor
@Suite(.serialized) struct BottomGravityListTests {
    @Test(arguments: ScrollEngineMode.allCases) func shortContentRestsOnTheComposerAndTallContentOpensOnItsEnd(mode: ScrollEngineMode) throws {
        let short = Chat(mode, count: 3)
        #expect(short.frame("m0")?.minY == 220 && short.lastBottom == Chat.line)
        #expect(short.list.isFollowingBottom && short.list.distanceFromBottom == 0)
        let tall = Chat(mode)
        #expect(tall.lastBottom == Chat.line && tall.list.isFollowingBottom)
        #expect(tall.list.loadedIndexRange.upperBound == 100 && !tall.list.loadedIndexRange.contains(0))
        // The first message of an empty chat sits on the composer too.
        let empty = Chat(mode, count: 0)
        #expect(empty.list.items.isEmpty)
        empty.rows = [GravityRow(identity: "first", height: 60)]
        empty.apply()
        #expect(empty.frame("first") == CGRect(x: 0, y: 310, width: 320, height: 60))
        #expect(empty.list.isFollowingBottom)
    }

    @Test(arguments: ScrollEngineMode.allCases) func growthAtTheEndIsFollowedByTheBudgetThenLeftBelowTheFold(mode: ScrollEngineMode) throws {
        let chat = Chat(mode)
        let reading = try #require(chat.firstVisible)
        let top = try #require(chat.frame(reading)).minY
        chat.grow("m99", by: 30)
        #expect(chat.lastBottom == Chat.line && chat.frame(reading)?.minY == top - 30)
        #expect(chat.list.isFollowingBottom && chat.list.remainingFollowBudget == 14)
        var changes: [Bool] = []
        chat.list.onBottomFollowChanged = { changes.append($0) }
        chat.grow("m99", by: 30)
        #expect(chat.lastBottom == Chat.line + 16 && chat.frame(reading)?.minY == top - 44)
        #expect(!chat.list.isFollowingBottom && chat.list.remainingFollowBudget == 0 && changes == [false])
        #expect(chat.list.distanceFromBottom == 16)
        // From here the reader's content holds still while the row grows.
        for _ in 0..<5 { chat.grow("m99", by: 25) }
        #expect(chat.frame(reading)?.minY == top - 44 && chat.lastBottom == Chat.line + 141)
        chat.list.scrollToBottom(animated: false)
        #expect(chat.lastBottom == Chat.line && chat.list.isFollowingBottom && chat.list.remainingFollowBudget == 44 && changes == [false, true])
    }

    @Test(arguments: ScrollEngineMode.allCases) func veryFastStreamingSpendsTheSameBudget(mode: ScrollEngineMode) throws {
        let chat = Chat(mode)
        let reading = try #require(chat.firstVisible)
        let top = try #require(chat.frame(reading)).minY
        // Many height changes in one turn, some of them shrinking.
        for step in 0..<60 { chat.grow("m99", by: step % 7 == 6 ? -1 : 4, transition: .easeInOut(0.15)) }
        let growth = 52.0 * 4 - 8
        #expect(chat.frame(reading)?.minY == top - 44)
        #expect(chat.lastBottom == Chat.line + growth - 44)
        #expect(!chat.list.isFollowingBottom)
    }

    @Test func aChangeThatReturnsWithinAFrameCostsNothing() throws {
        let chat = Chat()
        chat.grow("m99", by: 10)
        chat.grow("m99", by: 20); chat.grow("m99", by: -20)
        #expect(chat.lastBottom == Chat.line && chat.list.remainingFollowBudget == 34 && chat.list.isFollowingBottom)
        // A reconfigure that keeps the height moves nothing and animates nothing.
        let before = chat.list.loadedIndexRange.map { chat.list.settledFrame(at: $0) }
        chat.rows[99].revision += 1
        chat.apply(.easeInOut(0.3))
        #expect(chat.list.loadedIndexRange.map { chat.list.settledFrame(at: $0) } == before)
        for index in chat.list.loadedIndexRange {
            #expect(chat.list.loadedItemView(at: index)?.layer.animation(forKey: "ultraview.list.positionY") == nil)
        }
        #expect(chat.list.remainingFollowBudget == 34)
    }

    @Test(arguments: ScrollEngineMode.allCases) func aNewLastRowGetsAFullBudgetOnlyWhileFollowing(mode: ScrollEngineMode) throws {
        let chat = Chat(mode)
        chat.grow("m99", by: 30)
        chat.rows.append(GravityRow(identity: "reply", height: 60))
        chat.apply()
        // A fresh 44 points: the reply's top 44 show above the composer.
        #expect(chat.frame("reply")?.minY == Chat.line - 44 && !chat.list.isFollowingBottom)
        let reading = try #require(chat.firstVisible)
        let top = try #require(chat.frame(reading)).minY
        chat.rows.append(GravityRow(identity: "later", height: 60))
        chat.apply()
        #expect(chat.frame(reading)?.minY == top && chat.frame("later")?.minY == Chat.line + 16)
    }

    @Test(arguments: ScrollEngineMode.allCases) func revealedNewRowsShowWholeThenFollowTheirGrowthByTheBudget(mode: ScrollEngineMode) throws {
        let chat = Chat(mode)
        chat.list.bottomGravity = .init(followBudget: 44, revealsNewRows: true)
        chat.rows.append(GravityRow(identity: "tool", height: 60))
        chat.apply(.easeInOut(0.2))
        #expect(chat.lastBottom == Chat.line && chat.list.isFollowingBottom && chat.list.remainingFollowBudget == 44)
        chat.grow("tool", by: 60)
        #expect(chat.frame("tool")?.maxY == 386 && !chat.list.isFollowingBottom)
        // Away from the bottom, a new row stays below.
        chat.rows.append(GravityRow(identity: "below", height: 60))
        chat.apply()
        #expect(chat.frame("below")?.minY == 386)
        // Back at the bottom, a row taller than the visible height stops with its top on the top inset.
        chat.list.scrollToBottom(animated: false)
        chat.rows.append(GravityRow(identity: "essay", height: 500))
        chat.rows.append(GravityRow(identity: "after", height: 50))
        chat.apply()
        #expect(chat.frame("essay")?.minY == 20 && !chat.list.isFollowingBottom)
    }

    @Test(arguments: ScrollEngineMode.allCases) func aTallFirstLoadOfPreparedRowsOpensOnItsEnd(mode: ScrollEngineMode) async throws {
        let list = UltraListView(engineMode: mode)
        let window = makeWindow()
        defer { window.isHidden = true }
        window.frame = .init(x: 0, y: 0, width: 320, height: 400); window.isHidden = false
        list.frame = window.bounds; window.addSubview(list)
        list.bottomGravity = .init(followBudget: 44)
        list.layoutIfNeeded()
        list.applyChanges(items: (0..<200).map { PreparedGravityRow(identity: "p\($0)") }, newInsets: .init(top: 20, bottom: 30), transition: .none)
        for _ in 0..<600 where list.loadedIndexRange.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(list.loadedIndexRange.upperBound == 200)
        #expect(list.settledFrame(at: 199)?.maxY == 370 && list.isFollowingBottom)
    }

    @Test(arguments: ScrollEngineMode.allCases) func rowsMeasuredAgainAfterAWidthChangeKeepAFollowingEnd(mode: ScrollEngineMode) async throws {
        let list = UltraListView(engineMode: mode)
        let window = makeWindow()
        defer { window.isHidden = true }
        window.frame = .init(x: 0, y: 0, width: 320, height: 400); window.isHidden = false
        list.frame = window.bounds; window.addSubview(list)
        list.bottomGravity = .init(followBudget: 44)
        list.layoutIfNeeded()
        list.applyChanges(items: (0..<200).map { PreparedGravityRow(identity: "p\($0)", slowAwayFrom: 320) }, newInsets: .init(top: 20, bottom: 30), transition: .none)
        for _ in 0..<600 where list.loadedIndexRange.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(list.settledFrame(at: 199)?.maxY == 370)
        // Narrower, the rows grow to 67 points as their measurements arrive.
        list.frame.size.width = 240
        list.layoutIfNeeded()
        for _ in 0..<600 where list.settledFrame(at: 199)?.height != 67 { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(list.settledFrame(at: 199)?.height == 67 && list.settledFrame(at: 199)?.maxY == 370)
        #expect(list.isFollowingBottom && list.remainingFollowBudget == 44)
    }

    /// A rotation as a host applies it: the bars' insets at the old size,
    /// then the new size, then the rows' measurements arriving. The end
    /// stays on the bottom inset in every sample, and the budget is untouched.
    @Test(arguments: ScrollEngineMode.allCases, [false, true]) func aRotationAtTheEndKeepsItOnTheComposer(mode: ScrollEngineMode, byFrame: Bool) async throws {
        let list = UltraListView(engineMode: mode)
        let window = makeWindow()
        defer { window.isHidden = true }
        window.frame = .init(x: 0, y: 0, width: 480, height: 480); window.isHidden = false
        list.frame = .init(x: 0, y: 0, width: 320, height: 400); window.addSubview(list)
        list.bottomGravity = .init(followBudget: 50)
        list.layoutIfNeeded()
        list.applyChanges(items: (0..<200).map { PreparedGravityRow(identity: "p\($0)", slowAwayFrom: 320) }, newInsets: .init(top: 128, bottom: 30), transition: .none)
        for _ in 0..<600 where list.loadedIndexRange.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        var worst = 0.0
        func sample(_ line: Double) {
            guard let settled = list.settledFrame(at: 199), let shown = list.presentedFrame(at: 199) else { return }
            worst = max(worst, abs(Double(settled.maxY) - line), abs(Double(shown.maxY) - line))
        }
        for (size, top, bottom) in [(CGSize(width: 480, height: 300), 90.0, 20.0), (CGSize(width: 320, height: 400), 128.0, 30.0)] {
            list.applyChanges(newInsets: .init(top: top, bottom: bottom), anchorMode: .preserveVisibleContent, compensatesInsetChange: false, transition: .none)
            var log: [String] = []
            list.onBottomFollowChanged = { log.append("follow \($0) at \(list.currentScrollOffset)") }
            // A host that sizes the list itself tells it first; the frame then matches.
            if !byFrame { list.applyChanges(newSize: size, transition: .none) }
            list.frame.size = size; list.layoutIfNeeded()
            let line = Double(size.height) - bottom
            for _ in 0..<150 {
                sample(line)
                if log.count < 12, let frame = list.settledFrame(at: 199) { log.append("\(frame.maxY)/\(list.presentedFrame(at: 199)?.maxY ?? -1)") }
                try await Task.sleep(for: .milliseconds(2))
            }
            #expect(worst < 0.5, "\(mode) by frame \(byFrame) to \(size): \(worst) \(log)")
            #expect(list.isFollowingBottom && list.remainingFollowBudget == 50)
        }
    }

    @Test(arguments: ScrollEngineMode.allCases) func theSentMessageIsBroughtIntoViewAndFollowedAfresh(mode: ScrollEngineMode) throws {
        let chat = Chat(mode)
        chat.show(40)
        #expect(!chat.list.isFollowingBottom)
        chat.rows.append(GravityRow(identity: "sent", height: 90))
        chat.apply(.easeInOut(0.3), scrollTo: .bottom)
        #expect(chat.frame("sent").map { Double($0.maxY) } == Chat.line && chat.list.isFollowingBottom && chat.list.remainingFollowBudget == 44)
        // A message taller than the screen shows its end.
        chat.rows.append(GravityRow(identity: "long", height: 900))
        chat.apply(scrollTo: .bottom)
        #expect(chat.frame("long").map { Double($0.maxY) } == Chat.line && chat.list.isFollowingBottom)
        // A reply then follows by the budget.
        chat.rows.append(GravityRow(identity: "reply", height: 30))
        chat.apply()
        #expect(chat.lastBottom == Chat.line)
        chat.grow("reply", by: 30)
        #expect(chat.lastBottom == Chat.line + 16)
    }

    @Test(arguments: ScrollEngineMode.allCases) func changesAroundTheReadRowNeverMoveIt(mode: ScrollEngineMode) throws {
        let chat = Chat(mode)
        chat.show(40)
        #expect(chat.firstVisible == "m40" && chat.frame("m40")?.minY == 20)
        func expectStill(_ label: String, _ change: () -> Void) {
            change()
            #expect(chat.frame("m40")?.minY == 20, "\(mode) \(label): \(String(describing: chat.frame("m40")))")
        }
        expectStill("row above grows") { chat.grow("m38", by: 70) }
        expectStill("row below grows") { chat.grow("m42", by: 70) }
        expectStill("the end grows") { chat.grow("m99", by: 300) }
        expectStill("row above collapses") { chat.grow("m39", by: -50) }
        expectStill("row above deleted") { chat.rows.removeAll { $0.identity == "m37" }; chat.apply(.easeInOut(0.3)) }
        expectStill("older page prepended") {
            chat.rows.insert(contentsOf: (0..<30).map { GravityRow(identity: "old\($0)", height: 44) }, at: 0)
            chat.apply(.easeInOut(0.3))
        }
        expectStill("rows below deleted") { chat.rows.removeAll { $0.identity == "m41" || $0.identity == "m43" }; chat.apply() }
        expectStill("new row at the end") { chat.rows.append(GravityRow(identity: "new", height: 80)); chat.apply(.easeInOut(0.3)) }
        // The read row itself keeps its top and grows down.
        chat.grow("m40", by: 120, transition: .easeInOut(0.3))
        #expect(chat.frame("m40")?.minY == 20 && chat.frame("m40")?.height == 170)
        #expect(!chat.list.isFollowingBottom)
    }

    @Test(arguments: ScrollEngineMode.allCases) func aRowAboveTheAnchorAnimatesWithoutMovingIt(mode: ScrollEngineMode) async throws {
        let chat = Chat(mode)
        chat.show(40)
        chat.grow("m38", by: 80, transition: .easeInOut(0.3))
        var worst = 0.0
        for _ in 0..<20 {
            if let frame = chat.presented("m40") { worst = max(worst, abs(frame.minY - 20)) }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(worst < 0.5, "\(mode): the read row moved \(worst) while a row above it grew")
    }

    @Test(arguments: ScrollEngineMode.allCases) func aFollowedGrowthKeepsTheEndOnTheComposerThroughItsAnimation(mode: ScrollEngineMode) async throws {
        let chat = Chat(mode, budget: 400)
        chat.grow("m99", by: 120, transition: .easeInOut(0.3))
        var worst = 0.0, samples = 0
        for _ in 0..<20 {
            if let frame = chat.presented("m99") { worst = max(worst, abs(frame.maxY - Chat.line)); samples += 1 }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(samples > 0 && worst < 0.5, "\(mode): the end left the composer by \(worst)")
    }

    @Test(arguments: ScrollEngineMode.allCases) func aDragHoldsTheContentUnderTheFinger(mode: ScrollEngineMode) throws {
        let chat = Chat(mode)
        chat.show(40, at: 35)
        let now = CACurrentMediaTime()
        chat.drag(.touchDown, 0, at: now)
        chat.drag(.began, 0, at: now + 0.01)
        chat.drag(.changed, 30, at: now + 0.02)
        #expect(chat.frame("m40")?.minY == 65)
        #expect(!chat.list.isFollowingBottom)
        // Older history, growth above and a new row at the end, mid-drag.
        chat.rows.insert(contentsOf: (0..<20).map { GravityRow(identity: "old\($0)", height: 44) }, at: 0)
        chat.rows[chat.rows.firstIndex { $0.identity == "m38" }!].height += 60
        chat.rows.append(GravityRow(identity: "new", height: 80))
        chat.apply(.easeInOut(0.3))
        #expect(chat.frame("m40")?.minY == 65)
        // The next finger sample moves it by exactly the finger's travel.
        chat.drag(.changed, 50, at: now + 0.03)
        #expect(chat.frame("m40")?.minY == 85)
        chat.drag(.ended, 50, at: now + 0.04)
        #expect(!chat.list.isFollowingBottom)
    }

    @Test(arguments: ScrollEngineMode.allCases) func theRowUnderTheFingerIsTheAnchor(mode: ScrollEngineMode) throws {
        let chat = Chat(mode)
        chat.show(40, at: 20)
        let now = CACurrentMediaTime()
        chat.drag(.touchDown, 0, at: now)
        chat.list.touchLocationOverride = CGPoint(x: 100, y: 230)
        defer { chat.list.touchLocationOverride = nil }
        let touched = try #require(chat.list.loadedIndexRange.first { index in
            chat.list.settledFrame(at: index).map { $0.minY <= 230 && 230 < $0.maxY } == true
        }).description
        let id = "m\(touched)"
        let top = try #require(chat.frame(id)).minY
        // A row between the top of the screen and the finger grows.
        chat.grow("m41", by: 100)
        #expect(chat.frame(id)?.minY == top, "\(mode): \(String(describing: chat.frame(id))) was \(top)")
        #expect(chat.frame("m40")?.minY == -80, "\(mode): \(String(describing: chat.frame("m40"))) \(chat.list.loadedIndexRange)")
    }

    @Test(arguments: ScrollEngineMode.allCases) func growthAtTheEndUnderAFingerAtTheBottomGoesBelowTheFold(mode: ScrollEngineMode) throws {
        let chat = Chat(mode)
        let reading = try #require(chat.firstVisible)
        let top = try #require(chat.frame(reading)).minY
        chat.drag(.touchDown, 0, at: CACurrentMediaTime())
        #expect(!chat.list.isFollowingBottom)
        chat.grow("m99", by: 40)
        #expect(chat.frame(reading)?.minY == top && chat.lastBottom == Chat.line + 40)
        // The finger lifts without having dragged: still away from the bottom.
        chat.list.engine.didTouchUp?()
        #expect(!chat.list.isFollowingBottom)
    }

    @Test func aTapResumesFollowingWithWhatWasLeft() throws {
        let chat = Chat()
        chat.grow("m99", by: 20)
        chat.drag(.touchDown, 0, at: CACurrentMediaTime())
        #expect(!chat.list.isFollowingBottom)
        chat.list.engine.didTouchUp?()
        #expect(chat.list.isFollowingBottom && chat.list.remainingFollowBudget == 24)
        chat.grow("m99", by: 40)
        #expect(chat.lastBottom == Chat.line + 16)
    }

    /// The platform engine's rubber band belongs to UIKit, which can't take
    /// a new anchor mid-drag; its recorded-input driver isn't checked here.
    @Test(arguments: [ScrollEngineMode.keyframe, .stepped]) func overscrollUnderTheFingerAbsorbsGrowthAtTheEnd(mode: ScrollEngineMode) throws {
        let chat = Chat(mode)
        let now = CACurrentMediaTime()
        chat.drag(.touchDown, 0, at: now)
        chat.drag(.began, 0, at: now + 0.01)
        chat.drag(.changed, -120, at: now + 0.02)
        let pulled = try #require(chat.frame("m99"))
        #expect(pulled.maxY < Chat.line - 1)
        chat.grow("m99", by: 30)
        #expect(chat.frame("m99")?.minY == pulled.minY)
        // The rubber band continues from where the content is.
        chat.drag(.changed, -121, at: now + 0.03)
        let next = try #require(chat.frame("m99"))
        #expect(next.minY < pulled.minY && pulled.minY - next.minY < 1, "\(mode): \(pulled) → \(next)")
        chat.drag(.ended, -121, at: now + 0.04)
    }

    @Test(arguments: [ScrollEngineMode.keyframe, .stepped]) func aFlightKeepsItsLandingAcrossChangesAbove(mode: ScrollEngineMode) async throws {
        let chat = Chat(mode, count: 300)
        chat.show(150)
        chat.list.beginMomentum(velocity: -1500)
        try await Task.sleep(for: .milliseconds(50))
        let flying = chat.list.isScrollFlightActive || chat.list.isDecelerating
        #expect(flying)
        let reading = try #require(chat.firstVisible)
        chat.list.engine.sync()
        let before = try #require(chat.frame(reading)).minY
        chat.rows.insert(contentsOf: (0..<40).map { GravityRow(identity: "old\($0)", height: 44) }, at: 0)
        chat.grow("m120", by: 0)
        let after = try #require(chat.frame(reading)).minY
        // Only the flight's own motion between the two reads moves it.
        #expect(abs(after - before) < 3, "\(mode): \(before) → \(after)")
        #expect(chat.list.isScrollFlightActive || chat.list.isDecelerating)
        for _ in 0..<300 where chat.list.isScrollFlightActive || chat.list.isDecelerating { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!chat.list.isFollowingBottom)
    }

    @Test(arguments: ScrollEngineMode.allCases) func theKeyboardKeepsAFollowingEndOnTheComposer(mode: ScrollEngineMode) throws {
        let chat = Chat(mode)
        chat.list.applyChanges(newInsets: .init(top: 20, bottom: 280), transition: .keyboard(0.3))
        #expect(chat.lastBottom == 120 && chat.list.isFollowingBottom)
        chat.list.applyChanges(newInsets: .init(top: 20, bottom: 30), compensatesInsetChange: false, transition: .keyboard(0.3))
        #expect(chat.lastBottom == Chat.line && chat.list.isFollowingBottom)
        // Scrolled away, the content moves with the composer only when asked.
        chat.show(40, at: 100)
        chat.list.applyChanges(newInsets: .init(top: 20, bottom: 280), transition: .keyboard(0.3))
        #expect(chat.frame("m40")?.minY == -150)
        chat.list.applyChanges(newInsets: .init(top: 20, bottom: 30), compensatesInsetChange: false, transition: .none)
        #expect(chat.frame("m40")?.minY == -150)
        // A composer that grows while away moves nothing it isn't asked to.
        chat.list.applyChanges(newInsets: .init(top: 20, bottom: 60), compensatesInsetChange: false, transition: .none)
        #expect(chat.frame("m40")?.minY == -150 && !chat.list.isFollowingBottom)
    }

    @Test func shortContentStaysOnTheComposerThroughTheKeyboard() throws {
        let chat = Chat(count: 2)
        chat.list.applyChanges(newInsets: .init(top: 20, bottom: 280), compensatesInsetChange: false, transition: .none)
        #expect(chat.lastBottom == 120 && chat.frame("m0")?.minY == 20)
    }

    @Test(arguments: ScrollEngineMode.allCases) func aContentChangeDuringAKeyboardTransitionStillHoldsTheReadRow(mode: ScrollEngineMode) throws {
        let chat = Chat(mode)
        chat.show(40, at: 100)
        chat.list.applyChanges(newInsets: .init(top: 20, bottom: 280), transition: .keyboard(0.5))
        let top = try #require(chat.frame("m40")).minY
        chat.grow("m38", by: 50, transition: .easeInOut(0.3))
        chat.grow("m99", by: 50, transition: .easeInOut(0.3))
        #expect(chat.frame("m40")?.minY == top)
    }

    @Test(arguments: ScrollEngineMode.allCases) func awayFromTheEndTheContentMovesWithTheInsetItFollows(mode: ScrollEngineMode) throws {
        let chat = Chat(mode)
        chat.show(40, at: 100)
        // Not compensating, it keeps its distance from a taller top bar.
        chat.list.applyChanges(newInsets: .init(top: 60, bottom: 30), compensatesInsetChange: false, transition: .none)
        #expect(chat.frame("m40")?.minY == 140)
        // Compensating, it moves with the composer instead.
        chat.list.applyChanges(newInsets: .init(top: 20, bottom: 80), compensatesInsetChange: true, transition: .none)
        #expect(chat.frame("m40")?.minY == 90)
        // Both, then the width, in a rotation's order.
        chat.list.applyChanges(newInsets: .init(top: 40, bottom: 80), compensatesInsetChange: false, transition: .none)
        chat.list.frame.size.width = 480
        chat.list.layoutIfNeeded()
        #expect(chat.frame("m40")?.minY == 110)
    }

    @Test(arguments: ScrollEngineMode.allCases) func aWidthChangeKeepsTheReadRowAndTheEnd(mode: ScrollEngineMode) throws {
        let chat = Chat(mode)
        for index in chat.rows.indices { chat.rows[index].fixed = false; chat.rows[index].height = 64 }
        chat.apply()
        chat.show(40, at: -12)
        #expect(chat.firstVisible == "m40")
        chat.list.frame.size.width = 480
        chat.list.layoutIfNeeded()
        // 64 → 43 points: the half above the top inset stays above it.
        let frame = try #require(chat.frame("m40"))
        #expect(frame.height == 43)
        #expect(abs(frame.minY - (20 - 43.0 / 2)) < 0.01, "\(mode): \(frame)")
        chat.list.scrollToBottom(animated: false)
        chat.list.frame.size.width = 320
        chat.list.layoutIfNeeded()
        #expect(chat.lastBottom == Chat.line && chat.list.isFollowingBottom)
        // A height change of the list keeps a following end on the composer.
        chat.list.frame.size.height = 300
        chat.list.layoutIfNeeded()
        #expect(chat.lastBottom == 270 && chat.list.isFollowingBottom)
    }

    @Test(arguments: ScrollEngineMode.allCases) func scrollingToTheTopStopsFollowing(mode: ScrollEngineMode) throws {
        let chat = Chat(mode)
        chat.list.scrollToTop(animated: false)
        #expect(chat.frame("m0")?.minY == 20 && !chat.list.isFollowingBottom)
        chat.grow("m99", by: 100)
        #expect(chat.frame("m0")?.minY == 20)
        chat.list.stopFollowingBottom()
        chat.list.scrollToBottom(animated: true)
        #expect(chat.list.isFollowingBottom && chat.lastBottom == Chat.line)
        chat.list.stopFollowingBottom()
        #expect(!chat.list.isFollowingBottom)
        chat.grow("m99", by: 30)
        #expect(chat.lastBottom == Chat.line + 30)
    }

    @Test func shortContentCrossingTheViewportFillsItThenStops() throws {
        let chat = Chat(count: 3, height: 100)
        #expect(chat.frame("m0")?.minY == 70)
        chat.grow("m2", by: 50)
        #expect(chat.frame("m0")?.minY == 20 && chat.lastBottom == Chat.line)
        chat.grow("m2", by: 50)
        #expect(chat.frame("m0")?.minY == 20 && chat.lastBottom == Chat.line + 50 && !chat.list.isFollowingBottom)
        // Back down to short, the end rests on the composer again.
        chat.grow("m2", by: -150)
        #expect(chat.lastBottom == Chat.line && chat.frame("m0")?.minY == 120)
    }

    @Test func aRowThatGrowsPastAFullScreenKeepsItsTop() throws {
        let chat = Chat()
        chat.rows.append(GravityRow(identity: "essay", height: 40))
        chat.apply()
        let top = try #require(chat.frame("essay")).minY
        for _ in 0..<40 { chat.grow("essay", by: 30) }
        #expect(chat.frame("essay")?.minY == top - 4 && chat.frame("essay")?.height == 1240)
    }

    /// The largest distance, over about half a second, between adjacent
    /// loaded rows as shown: they touch in their settled frames.
    private func widestSeam(_ chat: Chat, during steps: [(delay: Int, change: () -> Void)]) async throws -> (Double, String) {
        var worst = 0.0, at = ""
        var pending = steps, elapsed = 0
        while elapsed < 600 {
            while let next = pending.first, next.delay <= elapsed { pending.removeFirst(); next.change() }
            var previous: (String, CGRect)?
            for index in chat.list.loadedIndexRange {
                guard let rect = chat.list.presentedFrame(at: index) else { previous = nil; continue }
                let id = chat.list.items[index].identity
                if let (above, aboveRect) = previous, rect.maxY > 20, aboveRect.minY < Chat.line {
                    let seam = abs(Double(rect.minY - aboveRect.maxY))
                    if seam > worst { worst = seam; at = "\(above)|\(id) at \(elapsed) ms: \(aboveRect) \(rect)" }
                }
                previous = (id, rect)
            }
            try await Task.sleep(for: .milliseconds(4)); elapsed += 4
        }
        return (worst, at)
    }

    @Test(arguments: ScrollEngineMode.allCases, [false, true]) func aRowAppendedAsItsNeighbourResizesStaysAgainstIt(mode: ScrollEngineMode, sent: Bool) async throws {
        let chat = Chat(mode)
        // The previous last row loses its group spacing as the new row arrives.
        let (seam, at) = try await widestSeam(chat, during: [(0, {
            chat.rows[99].height -= 5; chat.rows[99].revision += 1
            chat.rows.append(GravityRow(identity: "new", height: 46))
            chat.apply(.easeInOut(0.3), scrollTo: sent ? .bottom : nil)
        })])
        #expect(seam < 0.5, "\(at)")
        #expect(chat.lastBottom == Chat.line)
    }

    @Test(arguments: ScrollEngineMode.allCases) func aMessageSentWhileAReplyGrowsStaysAgainstIt(mode: ScrollEngineMode) async throws {
        let chat = Chat(mode, budget: 400)
        func grow() {
            let index = chat.rows.firstIndex { $0.identity == "m99" }!
            chat.rows[index].height += 6; chat.rows[index].revision += 1
            chat.apply(.easeInOut(0.3))
        }
        var steps: [(delay: Int, change: () -> Void)] = (0..<12).map { ($0 * 33, grow) }
        steps.append((100, {
            chat.rows.append(GravityRow(identity: "sent", height: 46))
            chat.apply(.easeInOut(0.3), scrollTo: .bottom)
        }))
        steps.append((250, {
            chat.rows.append(GravityRow(identity: "reply", height: 46))
            chat.apply(.easeInOut(0.3))
        }))
        let (seam, at) = try await widestSeam(chat, during: steps.sorted { $0.delay < $1.delay })
        #expect(seam < 0.5, "\(at)")
    }
}
#endif
