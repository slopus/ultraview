#if canImport(UIKit)
import UIKit
import QuartzCore
import Testing
import UltraCore
@testable import UltraList

@MainActor
private struct CardRow: ListRow {
    var identity: String
    var revision: UInt64 = 0
    func makeView() -> ListRowView { CardView() }
    func apply(to view: ListRowView, transition: ListTransition) {
        view.isAccessibilityElement = true; view.accessibilityLabel = identity
    }
}

/// Lays out at any width; marks its top-left corner so orientation is visible.
@MainActor
private final class CardView: ListRowView {
    let corner = UIView()
    var laidOutWidth: Double = 0
    override init(frame: CGRect) { super.init(frame: frame); addSubview(corner) }
    override func update(width: Double, transition: ListTransition) -> Double { laidOutWidth = width; return 0 }
    override func layoutSubviews() { super.layoutSubviews(); corner.frame = .init(x: 0, y: 0, width: 10, height: 20) }
}

@MainActor
private final class HorizontalFixture {
    let window = makeWindow()
    let horizontal: HorizontalListView
    init(mode: ScrollEngineMode, rightToLeft: Bool = false, widths: [Double] = Array(repeating: 100, count: 40)) {
        window.frame = .init(x: 0, y: 0, width: 390, height: 600)
        horizontal = HorizontalListView(engineMode: mode)
        if rightToLeft { horizontal.semanticContentAttribute = .forceRightToLeft }
        horizontal.frame = .init(x: 0, y: 100, width: 390, height: 200)
        window.addSubview(horizontal); window.isHidden = false
        horizontal.layoutIfNeeded()
        horizontal.list.applyChanges(items: widths.enumerated().map { HorizontalRow(CardRow(identity: "c\($0.offset)"), width: $0.element) }, newInsets: .init(top: 12, left: 8, bottom: 12, right: 8), transition: .none)
        horizontal.list.layoutIfNeeded()
    }
    var list: UltraListView { horizontal.list }
    func content(_ index: Int) -> CardView? { (list.loadedItemView(at: index) as? HorizontalRowView)?.content as? CardView }
    /// The row's clip on screen, or with `presented` where it is drawn now.
    func screenRect(_ index: Int, presented: Bool = false) -> CGRect? {
        guard let view = presented ? list.loadedItemView(at: index) : content(index) else { return nil }
        if presented {
            let layer = view.layer.presentation() ?? view.layer
            return layer.convert(layer.bounds, to: horizontal.layer.presentation() ?? horizontal.layer)
        }
        return view.convert(view.bounds, to: horizontal)
    }
}

@MainActor
@Suite(.serialized) struct HorizontalListTests {
    @Test(arguments: ScrollEngineMode.allCases)
    func cardsRunLeftToRightUprightAtTheirWidth(mode: ScrollEngineMode) throws {
        let fixture = HorizontalFixture(mode: mode)
        let list = fixture.list
        #expect(list.bounds.size == CGSize(width: 200, height: 390))
        #expect(list.loadedIndexRange.lowerBound == 0 && list.loadedIndexRange.count >= 4)
        for index in 0..<4 {
            let rect = try #require(fixture.screenRect(index))
            #expect(abs(rect.minX - (12 + Double(index) * 100)) < 1e-6, "\(index): \(rect)")
            #expect(abs(rect.minY - 8) < 1e-6 && abs(rect.width - 100) < 1e-6 && abs(rect.height - 184) < 1e-6, "\(rect)")
            #expect(fixture.horizontal.screenFrame(try #require(list.settledFrame(at: index))).equalTo(rect))
            let content = try #require(fixture.content(index))
            #expect(content.laidOutWidth == 100)
            // Upright, unmirrored: content x runs along screen x and content y down the screen.
            let origin = content.convert(CGPoint.zero, to: nil), right = content.convert(CGPoint(x: 10, y: 0), to: nil), down = content.convert(CGPoint(x: 0, y: 10), to: nil)
            #expect(abs(right.x - origin.x - 10) < 1e-9 && abs(right.y - origin.y) < 1e-9)
            #expect(abs(down.y - origin.y - 10) < 1e-9 && abs(down.x - origin.x) < 1e-9)
            let corner = content.corner.convert(content.corner.bounds, to: fixture.horizontal)
            #expect(corner.equalTo(.init(x: rect.minX, y: rect.minY, width: 10, height: 20)))
            // The window rectangle VoiceOver converts to the screen: no turn is left in it.
            #expect(content.convert(content.bounds, to: nil).equalTo(fixture.horizontal.convert(rect, to: nil)))
        }
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func rightToLeftStartsAtTheRightEdge(mode: ScrollEngineMode) throws {
        let fixture = HorizontalFixture(mode: mode, rightToLeft: true)
        for index in 0..<3 {
            let rect = try #require(fixture.screenRect(index))
            #expect(abs(rect.maxX - (390 - 12 - Double(index) * 100)) < 1e-6, "\(index): \(rect)")
            #expect(abs(rect.minY - 8) < 1e-6 && abs(rect.height - 184) < 1e-6)
            #expect(fixture.horizontal.screenFrame(try #require(fixture.list.settledFrame(at: index))).equalTo(rect))
            let content = try #require(fixture.content(index))
            let origin = content.convert(CGPoint.zero, to: nil), right = content.convert(CGPoint(x: 10, y: 0), to: nil), down = content.convert(CGPoint(x: 0, y: 10), to: nil)
            #expect(abs(right.x - origin.x - 10) < 1e-9 && abs(down.y - origin.y - 10) < 1e-9)
        }
    }

    @Test(arguments: [false, true])
    func voiceOverScrollsPageAlongTheScreen(rightToLeft: Bool) throws {
        let fixture = HorizontalFixture(mode: .keyframe, rightToLeft: rightToLeft)
        let list = fixture.list
        let before = try #require(fixture.screenRect(0)).minX
        // Vertical scrolls belong to an enclosing scroller.
        #expect(list.accessibilityScroll(.down) == false)
        #expect(list.accessibilityScroll(.up) == false)
        // Showing the next page moves the cards against the reading direction.
        #expect(list.accessibilityScroll(rightToLeft ? .left : .right))
        list.layoutIfNeeded()
        let firstAfter = list.loadedIndexRange.lowerBound
        let moved = (fixture.screenRect(firstAfter)?.minX ?? 0) - (before + Double(firstAfter) * (rightToLeft ? -100 : 100))
        #expect(rightToLeft ? moved > 100 : moved < -100, "moved \(moved)")
        #expect(list.accessibilityScroll(rightToLeft ? .right : .left))
        list.layoutIfNeeded()
        #expect(abs((fixture.screenRect(0)?.minX ?? .nan) - before) < 0.5)
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func scrollInputMovesCardsAlongTheScreenAxis(mode: ScrollEngineMode) async throws {
        let fixture = HorizontalFixture(mode: mode)
        let list = fixture.list, before = try #require(fixture.screenRect(0)).minX
        // The list's own coordinates: a leftward finger is an upward one for the inner list.
        let time = CACurrentMediaTime()
        list.receiveScrollInput(.init(time: time, phase: .touchDown))
        list.receiveScrollInput(.init(time: time, phase: .began, translation: .init(x: 0, y: 0)))
        list.receiveScrollInput(.init(time: time + 0.016, phase: .changed, translation: .init(x: 0, y: -150), velocity: .init(x: 0, y: -10)))
        list.receiveScrollInput(.init(time: time + 0.032, phase: .ended, translation: .init(x: 0, y: -150), velocity: .zero))
        list.layoutIfNeeded()
        let first = list.loadedIndexRange.lowerBound
        let after = try #require(fixture.screenRect(first)).minX - Double(first) * 100
        #expect(abs(after - (before - 150)) < 1, "\(mode): \(before) → \(after)")
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func insertionSlidesNeighboursContiguously(mode: ScrollEngineMode) async throws {
        let fixture = HorizontalFixture(mode: mode)
        let list = fixture.list
        var items = (0..<40).map { HorizontalRow(CardRow(identity: "c\($0)"), width: 100) }
        items.insert(HorizontalRow(CardRow(identity: "new"), width: 140), at: 1)
        items[3] = HorizontalRow(CardRow(identity: "c2", revision: 1), width: 160)
        list.applyChanges(items: items, transition: .easeInOut(0.3))
        var frames = 0, maximumGap = 0.0, opening = 0.0
        let end = CACurrentMediaTime() + 0.35
        while CACurrentMediaTime() < end {
            try await Task.sleep(for: .milliseconds(8))
            frames += 1
            // The inserted card fades in where c0 and c1 make room; every other pair stays together,
            // including across the resizing c2.
            let shown = list.loadedIndexRange.filter { list.items[$0].identity != "new" }.compactMap { index in fixture.screenRect(index, presented: true).map { (list.items[index].identity, $0) } }.sorted { $0.1.minX < $1.1.minX }
            for (a, b) in zip(shown, shown.dropFirst()) where b.1.minX < 390 {
                let gap = b.1.minX - a.1.maxX
                if a.0 == "c0" { opening = max(opening, gap); maximumGap = max(maximumGap, -gap, gap - 140) }
                else { maximumGap = max(maximumGap, abs(gap)) }
            }
        }
        #expect(frames > 15)
        #expect(maximumGap <= 0.5, "\(mode): \(maximumGap)")
        #expect(opening > 100)
        let settled = (0..<5).compactMap { list.settledFrame(at: $0) }.map { fixture.horizontal.screenFrame($0) }
        #expect(settled.map(\.width) == [100, 140, 100, 160, 100])
        for (a, b) in zip(settled, settled.dropFirst()) { #expect(abs(b.minX - a.maxX) < 1e-6) }
    }

    @Test func nodeCardsAreLaidOutUprightAtCardSize() async throws {
        let window = makeWindow()
        window.frame = .init(x: 0, y: 0, width: 390, height: 600)
        let horizontal = HorizontalListView(engineMode: .keyframe)
        horizontal.frame = .init(x: 0, y: 0, width: 390, height: 180)
        window.addSubview(horizontal); window.isHidden = false
        horizontal.layoutIfNeeded()
        let rows = (0..<12).map { index in
            HorizontalRow(NodeRow(identity: "n\(index)") {
                var style = Style(); style.flex = 1; style.backgroundColor = .indigo
                return UltraNode(style: style)
            }, width: 150)
        }
        horizontal.list.applyChanges(items: rows)
        for _ in 0..<100 where !(horizontal.list.loadedItemViews.first?.isDisplayReady ?? false) { try await Task.sleep(for: .milliseconds(20)) }
        let row = try #require(horizontal.list.loadedItemView(at: 0) as? HorizontalRowView)
        #expect(row.isDisplayReady)
        let host = try #require(row.content.subviews.compactMap { $0 as? NodeHostView }.first)
        #expect(host.bounds.size == CGSize(width: 150, height: 180))
        let rect = host.convert(host.bounds, to: horizontal)
        #expect(rect.equalTo(.init(x: 0, y: 0, width: 150, height: 180)))
    }
}
#endif
