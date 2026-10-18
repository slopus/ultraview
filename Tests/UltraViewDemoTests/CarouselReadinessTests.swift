#if canImport(UIKit)
import Testing
import UIKit
import UltraView
@testable import UltraViewDemo

@MainActor
private final class CardPreparationGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !open else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        let waiting = waiters; waiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }
}

@MainActor
private struct ReadyCardRow: ListRow {
    let identity: String
    var gate: CardPreparationGate?
    var measuresAsynchronously: Bool { gate != nil }
    func makeView() -> ListRowView { ReadyCardView() }
    func prepare(width: Double, environment: RenderEnvironment) async -> ListPreparation? {
        await gate?.wait()
        return .init(height: 80)
    }
}

@MainActor
private final class ReadyCardView: ListRowView {
    override func update(width: Double, transition: ListTransition) -> Double { 80 }
}

/// The feed's carousel row, a horizontal list of node rows, is ready once
/// the cards it shows are drawn. A jump back to the top waits for it, so the
/// carousel shows with its cards in the pass that places it.
@MainActor
@Suite(.serialized) struct CarouselReadinessTests {
    private func makeWindow() -> UIWindow {
        (UIWindow.self as NSObject.Type).init() as! UIWindow
    }

    private func feedRow(_ index: Int) -> NodeRow {
        NodeRow(identity: "row-\(index)") {
            var style = Style(); style.height = .points(80); style.backgroundColor = .white
            return UltraNode(style: style, children: [UltraTextNode("Row \(index)")])
        }
    }

    /// Whether each card the carousel shows has a visible host with a drawn bitmap.
    private func cardsDrawn(_ carousel: DemoCarouselView) -> [Bool] {
        carousel.horizontal.list.loadedItemViews.map { card in
            var stack: [UIView] = [card], hosts: [NodeHostView] = []
            while let view = stack.popLast() {
                if let host = view as? NodeHostView, !host.isHidden { hosts.append(host) } else { stack += view.subviews }
            }
            return hosts.count == 1 && hosts[0].view(forTransitionKey: "title")?.layer.contents != nil
        }
    }

    @Test(arguments: ScrollEngineMode.allCases, [false, true])
    func aPartialBandOfReadyCardsWaitsForTheMissingVisibleCards(mode: ScrollEngineMode, restoresAnchor: Bool) async throws {
        for rightToLeft in [false, true] {
            let gate = CardPreparationGate()
            defer { gate.release() }
            let readyCount = restoresAnchor ? 3 : 1
            let state = CarouselState(cards: (0..<(restoresAnchor ? 40 : 3)).map { index in
                HorizontalRow(ReadyCardRow(identity: "card-\(index)", gate: index < readyCount ? nil : gate), width: 148)
            })
            if restoresAnchor { state.anchor = (10, 12) }
            let carousel = DemoCarouselView(identity: "partial", mode: mode, state: state)
            carousel.horizontal.semanticContentAttribute = rightToLeft ? .forceRightToLeft : .forceLeftToRight
            #expect(carousel.horizontal.effectiveUserInterfaceLayoutDirection == (rightToLeft ? .rightToLeft : .leftToRight))
            var readySignals = 0
            carousel.onDisplayReady = { readySignals += 1 }
            if restoresAnchor {
                // Place a ready leading band before the outer row restores its
                // missing anchor; the attempted restore must keep that band.
                carousel.horizontal.frame = .init(x: 0, y: 0, width: 390, height: DemoCarouselRow.height)
                carousel.horizontal.layoutIfNeeded()
                carousel.horizontal.list.layoutIfNeeded()
            }
            _ = carousel.update(width: 390, transition: .immediate)

            // Only synchronous leading cards can be placed before the gate opens.
            let list = carousel.horizontal.list
            #expect(list.loadedIndexRange == 0..<readyCount)
            #expect(list.loadedItemViews.count == readyCount)
            let allCardsReady = list.loadedItemViews.allSatisfy { $0.isDisplayReady }
            #expect(allCardsReady)
            #expect(!carousel.isDisplayReady)
            #expect(readySignals == 0)

            gate.release()
            let target = restoresAnchor ? 10 : 2
            for _ in 0..<300 where !list.loadedIndexRange.contains(target) || !carousel.isDisplayReady {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(list.loadedIndexRange.contains(target))
            #expect(carousel.isDisplayReady)
            #expect(readySignals == 1)
        }
    }

    @Test(arguments: ScrollEngineMode.allCases, [0, 1, 2, 3])
    func aCarouselWithAllOfItsCardsReadyDoesNotWaitForEmptySpace(mode: ScrollEngineMode, count: Int) {
        let state = CarouselState(cards: (0..<count).map { index in
            HorizontalRow(ReadyCardRow(identity: "card-\(index)"), width: 148)
        })
        let carousel = DemoCarouselView(identity: "complete", mode: mode, state: state)
        _ = carousel.update(width: 390, transition: .immediate)
        #expect(carousel.horizontal.list.loadedIndexRange.count == count)
        #expect(carousel.isDisplayReady)
    }

    @Test(arguments: [ScrollEngineMode.keyframe, .stepped, .uiKit]) func aJumpToTheTopShowsTheCarouselWithItsCardsDrawn(mode: ScrollEngineMode) async throws {
        let list = UltraListView(engineMode: mode)
        let window = makeWindow(); window.frame = .init(x: 0, y: 0, width: 390, height: 700)
        list.frame = window.bounds
        window.addSubview(list); window.isHidden = false
        defer { window.isHidden = true }
        var rows: [any ListRow] = (0..<1000).map { feedRow($0) }
        rows[3] = DemoCarouselRow(identity: "carousel", mode: mode, count: 40)
        list.applyChanges(items: rows, transition: .none)
        for _ in 0..<300 where list.loadedIndexRange.isEmpty || !list.loadedItemViews.allSatisfy(\.isDisplayReady) { try await Task.sleep(for: .milliseconds(10)) }
        list.scrollTo(.init(index: 900), transition: .immediate)
        for _ in 0..<300 where !(list.loadedIndexRange.contains(900) && list.loadedItemViews.allSatisfy(\.isDisplayReady)) { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(500))
        #expect(!list.loadedIndexRange.contains(3))

        // At the end of the pass that places the carousel again, every card
        // it shows is drawn.
        var atTop: [Bool]?
        let jumped = CACurrentMediaTime()
        var waited = 0.0
        list.onVisibleWindowChanged = {
            guard atTop == nil, list.loadedIndexRange.contains(3), let carousel = list.loadedItemView(at: 3) as? DemoCarouselView else { return }
            atTop = cardsDrawn(carousel)
            waited = CACurrentMediaTime() - jumped
        }
        list.scrollTo(.init(index: 0), transition: .immediate)
        for _ in 0..<300 where atTop == nil { try await Task.sleep(for: .milliseconds(5)) }
        let shown = try #require(atTop)
        #expect(shown.count >= 2 && shown.allSatisfy { $0 }, "\(shown) after \(waited) s")
    }
}
#endif
