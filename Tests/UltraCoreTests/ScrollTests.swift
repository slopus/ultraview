import Foundation
import Testing
@testable import UltraCore
import UltraLayout

@Suite struct RangeTuningTests {
    let tuning = RangeTuning(preloadScreens: 2, displayScreens: 1)
    let viewport = CGRect(x: 0, y: 1000, width: 100, height: 100)

    @Test(arguments: [
        (1050.0, InterfaceState.all),
        (995.0, .all),
        (1100.0, [.preload, .display]),
        (899.0, [.preload, .display]),
        (1195.0, [.preload, .display]),
        (1200.0, [.preload]),
        (1299.0, [.preload]),
        (1300.0, []),
        (790.0, []),
    ] as [(CGFloat, InterfaceState)])
    func vertical(start: CGFloat, expected: InterfaceState) {
        let frame = CGRect(x: 0, y: start, width: 100, height: 10)
        #expect(tuning.state(for: frame, viewport: viewport, horizontal: false) == expected)
    }

    @Test func horizontalUsesTheXAxis() {
        let viewport = CGRect(x: 500, y: 0, width: 100, height: 100)
        #expect(tuning.state(for: CGRect(x: 550, y: 900, width: 10, height: 10), viewport: viewport, horizontal: true) == .all)
        #expect(tuning.state(for: CGRect(x: 0, y: 50, width: 10, height: 10), viewport: viewport, horizontal: true) == [])
    }

    @Test func preloadIsNeverSmallerThanDisplay() {
        #expect(RangeTuning(preloadScreens: 0.5, displayScreens: 1).preloadScreens == 1)
    }
}

@Suite struct ScrollNodeTests {
    /// A 100-point-tall scroll node with `count` 50-point rows of text.
    private func feed(count: Int = 100) -> (UltraNode, UltraScrollNode, [UltraTextNode]) {
        let rows = (0..<count).map { index in
            text("Row \(index)") { $0.height = 50 }
        }
        let scroll = UltraScrollNode(style: { var style = Style(); style.flexGrow = 1; return style }(), children: rows)
        scroll.rangeTuning = RangeTuning(preloadScreens: 3, displayScreens: 1.5)
        return (box(children: [scroll]), scroll, rows)
    }

    @Test func aHostSizedAfterItsFirstPassSizesTheScrollNode() throws {
        // A host appears in a window before it has a size: the first pass
        // has no height, the next one does.
        let rows = (0..<100).map { _ in box { $0.height = 50 } }
        let scroll = UltraScrollNode(style: { var style = Style(); style.flex = 1; return style }(), children: rows)
        let harness = Harness(root: box({ $0.flex = 1 }, children: [scroll]), width: nil, height: nil, inWindow: false)
        harness.pass()
        harness.update { $0.inWindow = true }
        harness.pass()
        harness.update {
            $0.width = 320
            $0.height = 400
        }
        harness.pass()
        #expect(harness.read { scroll.shadow.sentFrame } == CGRect(x: 0, y: 0, width: 320, height: 400))
        #expect(harness.read { rows[40].shadow.isMounted } == false)
    }

    @Test func automaticHostDoesNoUnboundedWorkBeforeItsViewportArrives() {
        let rows = (0..<100).map { index in text("Row \(index)") }
        let scroll = UltraScrollNode(children: rows)
        let harness = Harness(root: scroll, automatic: true, width: nil, height: nil, inWindow: true)
        harness.renderer.waitUntilIdle()
        #expect(harness.measurer.count == 0)
        #expect(harness.rasterizer.count == 0)
        #expect(harness.commits.isEmpty)

        harness.update { $0.width = 320; $0.height = 400 }
        harness.renderer.waitUntilIdle()
        #expect(harness.measurer.count > 0)
        #expect(harness.rasterizer.count > 0)
        #expect(harness.read { !rows[99].shadow.isMounted })
    }

    @Test func contentIsLaidOutWithoutALimit() throws {
        let (root, scroll, rows) = feed()
        let harness = Harness(root: root, height: 100)

        let commit = try #require(harness.pass())

        #expect(commit.entry(for: scroll)?.frame == CGRect(x: 0, y: 0, width: 300, height: 100))
        #expect(commit.entry(for: scroll)?.props?.scroll?.contentSize == CGSize(width: 300, height: 5000))
        #expect(commit.entry(for: scroll)?.props?.clipsToBounds == true)
        #expect(harness.read { rows[99].shadow.frame } == CGRect(x: 0, y: 4950, width: 300, height: 50))
        #expect(scroll.children.count == 100)
    }

    @Test func onlyChildrenNearTheViewportAreMountedAndDrawn() throws {
        let (root, scroll, rows) = feed()
        let harness = Harness(root: root, height: 100)

        let commit = try #require(harness.pass())

        // Viewport 0...100: preload reaches 400, display 250.
        let mounted = rows.filter { commit.entry(for: $0)?.kind == .mount }
        #expect(mounted.count == 8)
        let drawn = rows.filter { commit.entry(for: $0)?.contents?.contents != nil }
        #expect(drawn.count == 5)
        #expect(Set(harness.rasterizer.drawnTexts) == Set((0..<5).map { "Row \($0)" }))
        #expect(rows[0].interfaceState == .all)
        #expect(rows[3].interfaceState == [.preload, .display])
        #expect(rows[6].interfaceState == [.preload])
        #expect(rows[8].interfaceState == [])
        #expect(same(commit.entry(for: scroll.contentNode)?.children, Array(rows[0..<8])))
        #expect(harness.measurer.count == 100, "every row is measured: the content size needs it")
    }

    @Test func scrollingMovesTheRangesFreesAndRedrawsBitmaps() throws {
        let (root, scroll, rows) = feed()
        let harness = Harness(root: root, height: 100)
        harness.pass()

        scroll.reportContentOffset(CGPoint(x: 0, y: 2000))
        let far = try #require(harness.pass())

        // Viewport 2000...2100: preload 1700...2400, display 1850...2250.
        #expect(far.nodes(.unmount) == ids(Array(rows[0..<8])))
        #expect(far.nodes(.mount) == ids(Array(rows[34..<48])))
        #expect(Set(rows.indices.filter { far.entry(for: rows[$0])?.contents?.contents != nil }) == Set(37..<45))
        #expect(harness.read { rows[0].shadow.contents == nil && rows[4].shadow.contents == nil })
        #expect(rows[0].interfaceState == [])
        #expect(rows[40].interfaceState == .all)
        #expect(harness.rasterizer.count == 5 + 8)

        scroll.reportContentOffset(.zero)
        let back = try #require(harness.pass())
        #expect(back.nodes(.mount) == ids(Array(rows[0..<8])))
        #expect(Set(rows.indices.filter { back.entry(for: rows[$0])?.contents?.contents != nil }) == Set(0..<5))
        #expect(harness.rasterizer.count == 5 + 8 + 5, "freed bitmaps are drawn again")
        #expect(harness.measurer.count == 100, "scrolling never re-measures")
    }

    @Test func aSmallScrollPreparesOnlyWhatEntersTheRanges() throws {
        let (root, scroll, rows) = feed()
        let harness = Harness(root: root, height: 100)
        harness.pass()

        // Viewport 10...110: preload reaches 410, display 260.
        scroll.reportContentOffset(CGPoint(x: 0, y: 10))
        let commit = try #require(harness.pass())

        #expect(commit.nodes(.mount) == ids([rows[8]]))
        #expect(commit.nodes(.unmount).isEmpty)
        #expect(Set(commit.entries.values.compactMap { $0.contents?.contents == nil ? nil : ObjectIdentifier($0.node) }) == ids([rows[5]]))
        #expect(harness.rasterizer.count == 6)

        scroll.reportContentOffset(CGPoint(x: 0, y: 10))
        #expect(harness.pass() == nil, "the same offset again is no change")
    }

    @Test func horizontalScrollLaysChildrenOutInARow() throws {
        let items = (0..<10).map { _ in box { $0.width = 80 } }
        let scroll = UltraScrollNode(horizontal: true, children: items)
        scroll.updateStyle { $0.height = 50 }
        let harness = Harness(root: box(children: [scroll]), width: 200)

        let commit = try #require(harness.pass())

        #expect(commit.entry(for: items[1])?.frame == CGRect(x: 80, y: 0, width: 80, height: 50))
        #expect(commit.entry(for: scroll)?.props?.scroll?.contentSize == CGSize(width: 800, height: 50))
        #expect(commit.entry(for: scroll)?.props?.scroll?.horizontal == true)
    }

    @Test func contentContainerStyleAppliesToTheContent() throws {
        let item = box { $0.height = 20 }
        let scroll = UltraScrollNode(contentContainerStyle: { var style = Style(); style.padding = 16; return style }(), children: [item])
        scroll.updateStyle { $0.height = 100 }
        let harness = Harness(root: box(children: [scroll]))

        let commit = try #require(harness.pass())

        #expect(commit.entry(for: item)?.frame == CGRect(x: 16, y: 16, width: 268, height: 20))
        #expect(commit.entry(for: scroll)?.props?.scroll?.contentSize == CGSize(width: 300, height: 52))
    }

    @Test func scrollConfigurationReachesTheProps() throws {
        let scroll = UltraScrollNode(children: [box { $0.height = 10 }])
        scroll.updateStyle { $0.height = 100 }
        scroll.contentInset = Insets(top: 4, left: 0, bottom: 8, right: 0)
        scroll.pagingEnabled = true
        scroll.bounces = false
        scroll.scrollEnabled = false
        scroll.showsVerticalScrollIndicator = false
        scroll.keyboardDismissMode = .onDrag
        let harness = Harness(root: box(children: [scroll]))

        let props = try #require(harness.pass()?.entry(for: scroll)?.props?.scroll)

        #expect(props.contentInset == Insets(top: 4, left: 0, bottom: 8, right: 0))
        #expect(props.pagingEnabled)
        #expect(!props.bounces)
        #expect(!props.scrollEnabled)
        #expect(!props.showsVerticalScrollIndicator)
        #expect(props.showsHorizontalScrollIndicator)
        #expect(props.keyboardDismissMode == .onDrag)
    }

    @Test func childrenAddedLaterGetStatesFromTheRanges() throws {
        let (root, scroll, rows) = feed(count: 2)
        let harness = Harness(root: root, height: 100)
        harness.pass()

        let near = text("near") { $0.height = 50 }
        let far = (0..<20).map { index in text("far \(index)") { $0.height = 50 } }
        scroll.setChildren(rows + [near] + far)
        let commit = try #require(harness.pass())

        #expect(commit.entry(for: near)?.kind == .mount)
        #expect(near.interfaceState == [.preload, .display])
        #expect(commit.entry(for: far[19]) == nil)
        #expect(far[19].interfaceState == [])
    }
}
