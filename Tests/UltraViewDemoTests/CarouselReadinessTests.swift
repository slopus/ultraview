#if canImport(UIKit)
import Testing
import UIKit
import UltraView
@testable import UltraViewDemo

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
