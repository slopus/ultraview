#if canImport(UIKit)
import Testing
import UIKit
@testable import UltraCore
import UltraView

@MainActor
@Suite struct ScrollRangeTests {
    /// 100 rows of 50 points in a 400-point viewport: with the default
    /// tuning, rows within 1.5 screens are drawn and rows within 3 screens
    /// have views.
    private func makeFeed() -> (UltraScrollNode, [UltraTextNode]) {
        let rows = (0..<100).map { index in
            UltraTextNode("Row \(index)", style: styled { $0.height = 50 })
        }
        let scroll = UltraScrollNode(style: styled { $0.flex = 1 }, children: rows)
        return (scroll, rows)
    }

    @Test func rangesFollowTheViewport() async throws {
        let (scroll, rows) = makeFeed()
        let hosted = Hosted(UltraNode(style: styled { $0.flex = 1 }, children: [scroll]), size: CGSize(width: 320, height: 400))
        await hosted.settle()

        let scrollView = try #require(scroll.view as? UIScrollView)
        #expect(scrollView.contentSize == CGSize(width: 320, height: 5000))
        #expect(rows[0].interfaceState == .all)
        #expect(rows[0].view?.layer.contents != nil)
        #expect(rows[19].view?.layer.contents != nil)          // display range ends at 1000
        #expect(rows[25].view != nil)                           // preloaded
        #expect(rows[25].view?.layer.contents == nil)           // but not drawn
        #expect(rows[25].interfaceState == .preload)
        #expect(rows[40].view == nil)                           // beyond 1600
        #expect(rows[40].interfaceState.isEmpty)

        // Far down: the first rows give up views and bitmaps, rows near the
        // new viewport get them.
        let drawsBefore = Diagnostics.shared.counts.draws
        scroll.scrollTo(y: 2500, animated: false)
        await hosted.settle()
        #expect(rows[0].view == nil)
        #expect(rows[0].interfaceState.isEmpty)
        #expect(rows[50].interfaceState == .all)
        #expect(rows[50].view?.layer.contents != nil)
        #expect(rows[35].view != nil && rows[35].view?.layer.contents == nil)
        #expect(Diagnostics.shared.counts.draws - drawsBefore >= 20)

        // Back to the top: the first rows are mounted and drawn again.
        scroll.scrollTo(y: 0, animated: false)
        await hosted.settle()
        #expect(rows[0].view?.layer.contents != nil)
        #expect(rows[0].interfaceState == .all)
        #expect(rows[50].view == nil)
        #expect(Diagnostics.shared.counts.mainThreadWork == 0)
    }

    @Test func leavingTheDisplayRangeFreesTheBitmap() async throws {
        let (scroll, rows) = makeFeed()
        let hosted = Hosted(UltraNode(style: styled { $0.flex = 1 }, children: [scroll]), size: CGSize(width: 320, height: 400))
        await hosted.settle()
        let view = try #require(rows[0].view)
        #expect(view.layer.contents != nil)

        // 900 points down, row 0 is outside 1.5 screens but inside 3.
        scroll.scrollTo(y: 900, animated: false)
        await hosted.settle()
        #expect(rows[0].view === view)
        #expect(rows[0].interfaceState == .preload)
        #expect(view.layer.contents == nil)

        scroll.scrollTo(y: 0, animated: false)
        await hosted.settle()
        #expect(rows[0].view === view)
        #expect(view.layer.contents != nil)
    }

    @Test func onScrollReportsOffsetAndSizes() async throws {
        let (scroll, _) = makeFeed()
        let events = ScrollEvents()
        scroll.onScroll = { event in events.values.append(event) }
        let hosted = Hosted(UltraNode(style: styled { $0.flex = 1 }, children: [scroll]), size: CGSize(width: 320, height: 400))
        await hosted.settle()
        scroll.scrollTo(y: 120, animated: false)
        let event = try #require(events.values.last)
        #expect(event.contentOffset == CGPoint(x: 0, y: 120))
        #expect(event.contentSize == CGSize(width: 320, height: 5000))
        #expect(event.layoutMeasurement == CGSize(width: 320, height: 400))

        scroll.scrollToEnd(animated: false)
        #expect(events.values.last?.contentOffset == CGPoint(x: 0, y: 4600))
    }

    @Test func scrollPropsReachTheScrollView() async throws {
        let (scroll, _) = makeFeed()
        scroll.pagingEnabled = true
        scroll.bounces = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInset = Insets(top: 10, left: 0, bottom: 20, right: 0)
        scroll.keyboardDismissMode = .onDrag
        scroll.scrollEnabled = false
        let hosted = Hosted(UltraNode(style: styled { $0.flex = 1 }, children: [scroll]), size: CGSize(width: 320, height: 400))
        await hosted.settle()
        let view = try #require(scroll.view as? UIScrollView)
        #expect(view.isPagingEnabled)
        #expect(!view.bounces)
        #expect(!view.showsVerticalScrollIndicator)
        #expect(view.contentInset == UIEdgeInsets(top: 10, left: 0, bottom: 20, right: 0))
        #expect(view.keyboardDismissMode == .onDrag)
        #expect(!view.isScrollEnabled)
    }

    @Test func horizontalScrollLaysChildrenInARow() async throws {
        let items = (0..<20).map { _ in UltraNode(style: styled { $0.width = 100; $0.backgroundColor = .red }) }
        let scroll = UltraScrollNode(style: styled { $0.height = 80 }, horizontal: true, children: items)
        let hosted = Hosted(UltraNode(children: [scroll]), size: CGSize(width: 300, height: 400))
        await hosted.settle()
        let view = try #require(scroll.view as? UIScrollView)
        #expect(view.contentSize == CGSize(width: 2000, height: 80))
        #expect(items[1].view?.frame == CGRect(x: 100, y: 0, width: 100, height: 80))
        #expect(items[19].view == nil)
    }
}

@MainActor
private final class ScrollEvents {
    var values: [ScrollEvent] = []
    nonisolated init() {}
}
#endif
