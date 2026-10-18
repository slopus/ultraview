#if canImport(UIKit)
import UIKit
import Testing
import UltraCore
@testable import UltraList

private struct PlainRow: ListRow {
    var identity: String
    func makeView() -> ListRowView { PlainRowView() }
    func apply(to view: ListRowView, transition: ListTransition) {}
}

private final class PlainRowView: ListRowView {
    override func update(width: Double, transition: ListTransition) -> Double { 100 }
}

/// A feed row holding a horizontal list, as the demo's carousels do.
private struct NestedRow: ListRow {
    var identity: String
    var mode: ScrollEngineMode
    func makeView() -> ListRowView { NestedRowView(mode: mode) }
    func apply(to view: ListRowView, transition: ListTransition) {}
}

private final class NestedRowView: ListRowView {
    let horizontal: HorizontalListView
    init(mode: ScrollEngineMode) {
        horizontal = HorizontalListView(engineMode: mode)
        super.init(frame: .zero)
        addSubview(horizontal)
        horizontal.list.applyChanges(items: (0..<10).map { HorizontalRow(PlainRow(identity: "card-\($0)"), width: 120) }, transition: .none)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func update(width: Double, transition: ListTransition) -> Double { 150 }
    override func layoutSubviews() { super.layoutSubviews(); horizontal.frame = bounds }
}

/// A row measured off the main thread, held back while its hold is closed.
@MainActor
private struct HeldRow: ListRow {
    var identity: String
    var revision: UInt64 = 0
    var hold: MeasurementHold?
    var measuresAsynchronously: Bool { true }
    func makeView() -> ListRowView { PlainRowView() }
    func apply(to view: ListRowView, transition: ListTransition) {}
    func measure(width: Double, environment: RenderEnvironment) async -> Double? {
        await hold?.wait()
        return 100
    }
}

private actor MeasurementHold {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if !opened { await withCheckedContinuation { waiters.append($0) } }
    }
    func open() { opened = true; let pending = waiters; waiters.removeAll(); for waiter in pending { waiter.resume() } }
}

@MainActor
@Suite(.serialized) struct ScrollToTopTests {
    private func proxies(in view: UIView) -> [ScrollToTopProxy] {
        view.subviews.flatMap { ($0 as? ScrollToTopProxy).map { [$0] } ?? proxies(in: $0) }
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func oneScrollViewPerWindowAcceptsTheStatusBarTap(mode: ScrollEngineMode) throws {
        let window = makeWindow()
        window.frame = .init(x: 0, y: 0, width: 390, height: 844)
        let feed = UltraListView(engineMode: mode), other = UltraListView(engineMode: mode)
        feed.frame = .init(x: 0, y: 0, width: 390, height: 700)
        other.frame = .init(x: 0, y: 700, width: 390, height: 144)
        window.addSubview(feed); window.addSubview(other); window.isHidden = false
        defer { window.isHidden = true }
        feed.keyboardDismissMode = .interactive
        feed.layoutIfNeeded(); other.layoutIfNeeded()
        feed.applyChanges(items: (0..<20).map { NestedRow(identity: "carousel-\($0)", mode: mode) }, transition: .none)
        other.applyChanges(items: (0..<20).map { PlainRow(identity: String($0)) }, transition: .none)
        let carousels = feed.loadedItemViews.compactMap { $0 as? NestedRowView }
        #expect(carousels.count >= 3)
        // A nested list stays out even when it asks to answer.
        carousels.first?.horizontal.list.scrollsToTop = true

        // Every system scroll view in the window: the engines' own, the
        // keyboard broker and the proxies. Only the feed's proxy accepts.
        func acceptors() -> [UIScrollView] {
            func all(_ view: UIView) -> [UIScrollView] { ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap(all) }
            return all(window).filter(\.scrollsToTop)
        }
        #expect(proxies(in: window).count >= 2 + carousels.count)
        #expect(acceptors().count == 1)
        #expect((acceptors().first as? ScrollToTopProxy)?.owner === feed)

        // The next largest list takes over when the feed leaves, or declines.
        feed.removeFromSuperview()
        #expect(acceptors().count == 1 && (acceptors().first as? ScrollToTopProxy)?.owner === other)
        window.addSubview(feed)
        #expect((acceptors().first as? ScrollToTopProxy)?.owner === feed)
        feed.scrollsToTop = false
        #expect(acceptors().count == 1 && (acceptors().first as? ScrollToTopProxy)?.owner === other)
        other.isHidden = true
        #expect(acceptors().isEmpty)
    }

    @Test(arguments: ScrollEngineMode.allCases, [false, true])
    func scrollingToTheTopLandsOnTheEdgeShownAtTheTop(mode: ScrollEngineMode, inverted: Bool) async throws {
        let window = makeWindow()
        window.frame = .init(x: 0, y: 0, width: 390, height: 600)
        let list = UltraListView(engineMode: mode)
        list.frame = window.bounds; window.addSubview(list); window.isHidden = false
        defer { list.engine.teardown(); window.isHidden = true }
        if inverted { list.contentView.transform = .init(scaleX: 1, y: -1) }
        list.layoutIfNeeded()
        list.applyChanges(items: (0..<50).map { PlainRow(identity: String($0)) }, newInsets: .init(top: 10, bottom: 20), transition: .none)
        list.scrollTo(.init(index: 25), transition: .immediate)
        var landed = 0
        list.didScrollToTop = { landed += 1 }

        // A declined tap leaves the list where it is.
        list.shouldScrollToTop = { false }
        list.statusBarTapped()
        #expect(list.loadedIndexRange.contains(25) && !list.loadedIndexRange.contains(0) && !list.loadedIndexRange.contains(49))

        list.shouldScrollToTop = nil
        list.statusBarTapped()
        for _ in 0..<100 where landed == 0 || list.isDecelerating { try await Task.sleep(for: .milliseconds(20)) }
        #expect(landed == 1)
        // Content coordinates: the inverted list shows its last row at the top.
        if inverted {
            let frame = try #require(list.settledFrame(at: 49))
            #expect(abs(frame.maxY - 580) < 0.5, "\(mode): last row ends at \(frame.maxY)")
        } else {
            let frame = try #require(list.settledFrame(at: 0))
            #expect(abs(frame.minY - 10) < 0.5, "\(mode): first row starts at \(frame.minY)")
        }
        #expect(abs(list.overscrollDistance) < 0.5)
        #expect(!list.holdsPinnedRow)
        // Once it rests, a keyboard's inset correction finishes at once again.
        list.applyChanges(newInsets: .init(top: 30, bottom: 20), transition: .keyboard(0.383))
        #expect(list.contentView.layer.animation(forKey: "ultraview.list.viewportOffset") != nil)
        list.finishViewportTransition()
        #expect(list.contentView.layer.animation(forKey: "ultraview.list.viewportOffset") == nil, "\(mode): the finish was skipped after landing")
    }

    /// A scroll to the top that waits for the first row's measurement
    /// reports landing once it rests there, not when its animation's time
    /// would have run out.
    @Test(arguments: ScrollEngineMode.allCases)
    func landingIsReportedOnceAScrollThatWaitedForMeasurementRests(mode: ScrollEngineMode) async throws {
        let window = makeWindow()
        window.frame = .init(x: 0, y: 0, width: 390, height: 600)
        let list = UltraListView(engineMode: mode)
        list.frame = window.bounds; window.addSubview(list); window.isHidden = false
        defer { list.engine.teardown(); window.isHidden = true }
        list.layoutIfNeeded()
        list.applyChanges(items: (0..<50).map { HeldRow(identity: String($0)) }, newInsets: .init(top: 10), transition: .none)
        for _ in 0..<150 where !list.loadedIndexRange.contains(0) { try await Task.sleep(for: .milliseconds(20)) }
        list.scrollTo(.init(index: 25), transition: .immediate)
        for _ in 0..<150 where !list.loadedIndexRange.contains(25) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!list.loadedIndexRange.contains(0))
        // The first rows change off screen, and their new measurements wait.
        let hold = MeasurementHold()
        list.applyChanges(items: (0..<50).map { HeldRow(identity: String($0), revision: $0 < 10 ? 1 : 0, hold: $0 < 10 ? hold : nil) }, transition: .none)
        var landed = 0
        list.didScrollToTop = { landed += 1 }
        list.statusBarTapped()
        try await Task.sleep(for: .milliseconds(700))
        #expect(landed == 0, "\(mode): reported landing before the first row was measured")
        #expect(!list.loadedIndexRange.contains(0))
        await hold.open()
        for _ in 0..<150 where landed == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(landed == 1)
        let frame = try #require(list.settledFrame(at: 0))
        #expect(abs(frame.minY - 10) < 0.5, "\(mode): first row starts at \(frame.minY)")
        try await Task.sleep(for: .milliseconds(200))
        #expect(landed == 1)
    }

    /// An immediate inset change during a scroll to the top (a line typed in
    /// the chat's composer, say) moves the content by its own change at once
    /// and leaves the rest of the scroll running on its clock.
    @Test(arguments: ScrollEngineMode.allCases, [true, false])
    func anImmediateInsetChangeDuringAScrollToTheTopLeavesItRunning(mode: ScrollEngineMode, compensates: Bool) async throws {
        let window = makeWindow()
        window.frame = .init(x: 0, y: 0, width: 390, height: 600)
        let list = UltraListView(engineMode: mode)
        list.frame = window.bounds; window.addSubview(list); window.isHidden = false
        defer { list.engine.teardown(); window.isHidden = true }
        list.layoutIfNeeded()
        list.applyChanges(items: (0..<50).map { PlainRow(identity: String($0)) }, newInsets: .init(top: 80), transition: .none)
        list.scrollTo(.init(index: 25), transition: .immediate)
        // Stopped time, committing each step as before.
        func at(_ time: Double) {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            list.layer.timeOffset = time
            CATransaction.commit(); CATransaction.flush()
        }
        list.layer.speed = 0; at(100)
        list.scrollToTop(animated: true)
        CATransaction.flush(); at(100.1)
        // What is left of the travel: where row 0 is shown against where it settles.
        func travel() throws -> Double {
            try #require(list.presentedFrame(at: 0)).minY - #require(list.settledFrame(at: 0)).minY
        }
        let before = try travel()
        #expect(abs(before) > 50, "\(mode): already at the top")
        list.applyChanges(newInsets: .init(top: 100), compensatesInsetChange: compensates, transition: .none)
        CATransaction.flush()
        let after = try travel()
        #expect(abs(after - before) < 0.5, "\(mode)/compensates=\(compensates): the travel left went from \(before) to \(after)")
        #expect(list.contentView.layer.animation(forKey: "ultraview.list.viewportOffset") != nil)
        // It ends where the list settles: the top edge when the change moves
        // the content with the inset, else where it already was.
        at(102)
        let landed = try #require(list.presentedFrame(at: 0)), settled = try #require(list.settledFrame(at: 0))
        #expect(abs(landed.minY - settled.minY) < 0.5, "\(mode): landed at \(landed.minY), settled at \(settled.minY)")
        #expect(abs(settled.minY - (compensates ? 100 : 80)) < 0.5, "\(mode)/compensates=\(compensates): settled at \(settled.minY)")
        // With no travel left, an immediate change still lands everything.
        list.applyChanges(newInsets: .init(top: 60), transition: .keyboard(0.383))
        CATransaction.flush(); at(102.1)
        list.applyChanges(newInsets: .init(top: 70), transition: .none)
        CATransaction.flush()
        #expect(list.contentView.layer.animation(forKey: "ultraview.list.viewportOffset") == nil)
    }

    /// The chat lands its keyboard's inset correction when the keyboard
    /// finishes hiding. A scroll to the top tapped while the keyboard goes
    /// down, or an inset change during the scroll, must not land with it.
    @Test(arguments: ScrollEngineMode.allCases, [false, true])
    func aKeyboardFinishingDuringAScrollToTheTopLeavesItRunning(mode: ScrollEngineMode, tapFirst: Bool) async throws {
        let window = makeWindow()
        window.frame = .init(x: 0, y: 0, width: 390, height: 600)
        let list = UltraListView(engineMode: mode)
        list.frame = window.bounds; window.addSubview(list); window.isHidden = false
        defer { list.engine.teardown(); window.isHidden = true }
        list.layoutIfNeeded()
        list.applyChanges(items: (0..<50).map { PlainRow(identity: String($0)) }, newInsets: .init(top: 80), transition: .none)
        list.scrollTo(.init(index: 25), transition: .immediate)
        // Stopped time: every presentation is read at a chosen moment. Each
        // step commits, so the animations it installs start at that moment.
        func at(_ time: Double) {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            list.layer.timeOffset = time
            CATransaction.commit(); CATransaction.flush()
        }
        list.layer.speed = 0; at(100)
        let keyboard = { list.applyChanges(newInsets: .init(top: tapFirst ? 120 : 40), transition: .keyboard(0.383)) }
        // The second starts while the first runs, and both are still running
        // when the keyboard finishes.
        let second = tapFirst ? 100.1 : 100.2
        if tapFirst { list.scrollToTop(animated: true) } else { keyboard() }
        CATransaction.flush(); at(second)
        if tapFirst { keyboard() } else { list.scrollToTop(animated: true) }
        CATransaction.flush(); at(second + 0.05)
        let before = try #require(list.presentedFrame(at: 0))
        let settled = try #require(list.settledFrame(at: 0))
        #expect(abs(before.minY - settled.minY) > 50, "\(mode): already at the top")
        list.finishViewportTransition()
        CATransaction.flush()
        let after = try #require(list.presentedFrame(at: 0))
        #expect(abs(after.minY - before.minY) < 0.5, "\(mode): jumped from \(before.minY) to \(after.minY)")
        #expect(list.contentView.layer.animation(forKey: "ultraview.list.viewportOffset") != nil)
        // It still lands on the top edge, under the final inset.
        at(102)
        let landed = try #require(list.presentedFrame(at: 0))
        #expect(abs(landed.minY - list.viewportInsets.top) < 0.5, "\(mode): landed at \(landed.minY)")
        // An inset correction that starts once the travel is over finishes at
        // once, though the landed track is still the last one installed.
        list.applyChanges(newInsets: .init(top: 60), transition: .keyboard(0.383))
        CATransaction.flush(); at(102.1)
        list.finishViewportTransition()
        #expect(list.contentView.layer.animation(forKey: "ultraview.list.viewportOffset") == nil)
    }
}
#endif
