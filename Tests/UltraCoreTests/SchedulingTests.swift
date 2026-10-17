import Foundation
import Testing
@testable import UltraCore
import UltraLayout

/// How the main thread's work is split into turns: what is on screen now,
/// views off screen later, parents before children.
@Suite struct CommitQueueTests {
    private func mount(_ node: UltraNode, parent: UltraNode?, depth: Int, visible: Bool) -> CommitEntry {
        var entry = CommitEntry(kind: .mount, node: node)
        entry.parent = parent
        entry.depth = depth
        entry.isVisible = visible
        return entry
    }

    private func commit(_ generation: UInt64, _ entries: [CommitEntry]) -> Commit {
        var commit = Commit(generation: generation, request: generation)
        entries.forEach { commit.record($0) }
        return commit
    }

    private func unmount(_ node: UltraNode, wasVisible: Bool) -> CommitEntry {
        var entry = CommitEntry(kind: .unmount, node: node)
        entry.isVisible = wasVisible
        return entry
    }

    @Test func onScreenWorkIsNowAndOffScreenViewsAreLater() throws {
        let root = UltraNode(), shown = UltraNode(), ahead = UltraNode(), aheadChild = UltraNode(), other = UltraNode()
        let leftScreen = UltraNode(), leftRange = UltraNode()
        var update = CommitEntry(kind: .update, node: other)
        update.frame = .zero
        var queue = CommitQueue()
        queue.add(commit(1, [
            mount(aheadChild, parent: ahead, depth: 2, visible: false),
            mount(root, parent: nil, depth: 0, visible: true),
            mount(ahead, parent: root, depth: 1, visible: false),
            update,
            mount(shown, parent: root, depth: 1, visible: true),
            unmount(leftScreen, wasVisible: true),
            unmount(leftRange, wasVisible: false),
        ]))

        let taken = queue.takeTurn()
        let turn = try #require(taken)
        #expect(Set(turn.now.map { ObjectIdentifier($0.node) }) == ids([root, other, shown, leftScreen]))
        // Removals first, then creations parents first.
        #expect(same(turn.later.map(\.node), [leftRange, ahead, aheadChild]))
        #expect(!queue.hasWork)
    }

    @Test func aViewOnScreenBringsItsAncestorsWithIt() throws {
        let root = UltraNode(), parent = UltraNode(), child = UltraNode(), sibling = UltraNode()
        var queue = CommitQueue()
        queue.add(commit(1, [
            mount(root, parent: nil, depth: 0, visible: false),
            mount(parent, parent: root, depth: 1, visible: false),
            mount(sibling, parent: root, depth: 1, visible: false),
            mount(child, parent: parent, depth: 2, visible: true),
        ]))

        let taken = queue.takeTurn()
        let turn = try #require(taken)
        #expect(Set(turn.now.map { ObjectIdentifier($0.node) }) == ids([root, parent, child]))
        #expect(same(turn.later.map(\.node), [sibling]))
    }

    @Test func leftoverMountsMergeWithNewerCommits() throws {
        let root = UltraNode(), a = UltraNode(), b = UltraNode(), c = UltraNode()
        var queue = CommitQueue()
        queue.add(commit(1, [
            mount(a, parent: root, depth: 1, visible: false),
            mount(b, parent: root, depth: 1, visible: false),
            mount(c, parent: root, depth: 1, visible: false),
        ]))
        let taken = queue.takeTurn()
        let first = try #require(taken)
        // The turn's budget ran out after one view.
        queue.putBack(first.later.dropFirst(1), of: first)
        #expect(queue.hasWork)

        // b left the range before its view was made; c came on screen.
        var cOnScreen = CommitEntry(kind: .update, node: c)
        cOnScreen.isVisible = true
        queue.add(commit(2, [CommitEntry(kind: .unmount, node: b), cOnScreen]))

        let takenAgain = queue.takeTurn()
        let second = try #require(takenAgain)
        #expect(second.generation == 2)
        #expect(same(second.later.map(\.node), [b]))
        #expect(second.later.first?.kind == .unmount)
        #expect(second.now.first { $0.node === c }?.kind == .mount, "still a mount, now on screen")
    }

    @Test func deferredRemovalIsReplacedByANewerMount() throws {
        let root = UltraNode(), row = UltraNode()
        var queue = CommitQueue()
        queue.add(commit(1, [unmount(row, wasVisible: false)]))
        let taken = queue.takeTurn()
        let first = try #require(taken)
        #expect(first.now.isEmpty)
        queue.putBack(first.later, of: first)

        queue.add(commit(2, [mount(row, parent: root, depth: 1, visible: true)]))
        let takenAgain = queue.takeTurn()
        let second = try #require(takenAgain)
        #expect(second.later.isEmpty)
        #expect(second.now.count == 1)
        #expect(second.now.first?.kind == .mount)
        #expect(second.now.first?.parent === root)
    }
}

/// What the pipeline does for a host outside a window, and how host
/// requests turn into passes.
@Suite struct OffscreenTests {
    /// 40 rows of 50 points in a 100-point scroll node.
    private func feed() -> (UltraNode, UltraScrollNode, [UltraTextNode]) {
        let rows = (0..<40).map { index in text("Row \(index)") { $0.height = 50 } }
        let scroll = UltraScrollNode(style: { var style = Style(); style.flexGrow = 1; return style }(), children: rows)
        return (box(children: [scroll]), scroll, rows)
    }

    @Test func aHostOutsideAWindowCanPrepareViewsAndBitmaps() throws {
        let (root, scroll, rows) = feed()
        let harness = Harness(root: root, height: 100, inWindow: false)
        harness.update { $0.outsideWindow = [.preload, .display] }

        let prepared = try #require(harness.pass())
        #expect(prepared.entry(for: root)?.kind == .mount)
        #expect(prepared.entry(for: rows[0])?.contents?.contents != nil)
        #expect(prepared.orderedEntries.allSatisfy { !$0.isVisible }, "nothing is on screen yet")
        #expect(rows[0].interfaceState == [.preload, .display])
        let draws = harness.rasterizer.count

        // Entering the window draws and mounts nothing new: it only tells the
        // main thread which views are now on screen.
        harness.update { $0.inWindow = true }
        let shown = try #require(harness.pass())
        #expect(shown.nodes(.mount).isEmpty)
        #expect(shown.nodes(.unmount).isEmpty)
        #expect(harness.rasterizer.count == draws)
        #expect(shown.entry(for: rows[0])?.isVisible == true)
        #expect(shown.entry(for: scroll)?.isVisible == true)
        #expect(shown.entry(for: rows[3]) == nil, "drawn ahead and not on screen: nothing changes")
        #expect(rows[0].interfaceState == .all)

        // Leaving it again keeps everything.
        harness.update { $0.inWindow = false }
        let hidden = try #require(harness.pass())
        #expect(hidden.nodes(.unmount).isEmpty)
        #expect(hidden.entry(for: rows[0])?.isVisible == false)
        #expect(harness.read { rows[0].shadow.contents != nil })
    }

    @Test func droppingContentOutsideAWindowUnmountsIt() throws {
        let (root, _, rows) = feed()
        let harness = Harness(root: root, height: 100, inWindow: false)
        harness.update { $0.outsideWindow = [.preload, .display] }
        harness.pass()

        harness.update { $0.outsideWindow = [] }
        let commit = try #require(harness.pass())
        #expect(commit.entry(for: root)?.kind == .unmount)
        #expect(harness.read { rows[0].shadow.contents == nil })
    }

    @Test func requestsMadeTogetherShareOnePass() {
        let (root, _, _) = feed()
        let harness = Harness(root: root, automatic: true, height: 100)
        harness.renderer.waitUntilIdle()
        let before = harness.renderer.passCount.load(ordering: .relaxed)
        for width in stride(from: 200, through: 300, by: 10) {
            harness.update { $0.width = CGFloat(width) }
        }
        harness.renderer.waitUntilIdle()
        let passes = harness.renderer.passCount.load(ordering: .relaxed) - before
        #expect(passes >= 1 && passes <= 2, "at most the pass in flight and one more")
    }
}

/// Measuring a tree that isn't shown.
@Suite struct MeasurementTests {
    private func card() -> (UltraNode, UltraTextNode) {
        let body = text("A paragraph long enough to wrap onto a few lines", fontSize: 20)
        let root = box({
            $0.padding = 10
            $0.gap = 5
        }, children: [box { $0.height = 30 }, body])
        return (root, body)
    }

    @Test func measuresAtAWidthWithoutAHeightLimit() async {
        let (root, _) = card()
        let measurer = CountingMeasurer()
        let size = await NodeMeasurement.measure(root, width: 200, environment: RenderEnvironment(scale: 2), measurer: measurer)
        // 180 points of text at 10 points a character: 18 per line, three
        // lines of 24 points. 10 + 30 + 5 + 72 + 10.
        #expect(size == CGSize(width: 200, height: 127))
        #expect(measurer.count >= 1)
        #expect(root.parent == nil)
    }

    @Test func aHostAtTheMeasuredSizeMeasuresNothingAgain() async throws {
        let (root, body) = card()
        let size = await NodeMeasurement.measure(root, width: 200, environment: RenderEnvironment(scale: 2), measurer: CountingMeasurer())

        let harness = Harness(root: root, width: size.width, height: size.height)
        let commit = try #require(harness.pass())
        #expect(harness.measurer.count == 0, "the measurement's text layouts are reused")
        #expect(commit.entry(for: root)?.kind == .mount)
        #expect(commit.entry(for: body)?.frame == CGRect(x: 10, y: 45, width: 180, height: 72))
        #expect(commit.entry(for: body)?.contents?.contents != nil)
    }

    @Test func measuringAgainAfterAChangeSeesTheChange() async {
        let (root, body) = card()
        let environment = RenderEnvironment(scale: 2)
        _ = await NodeMeasurement.measure(root, width: 200, environment: environment, measurer: CountingMeasurer())
        body.text = "Short"
        let size = await NodeMeasurement.measure(root, width: 200, environment: environment, measurer: CountingMeasurer())
        #expect(size == CGSize(width: 200, height: 79))
    }
}

/// Results that must not depend on how the tree got to its state.
@Suite struct IncrementalLayoutTests {
    @Test func percentagePaddingMovesTextInsideAnUnchangedFrame() throws {
        func label() -> UltraTextNode {
            UltraTextNode(
                spans: [TextSpan("ab"), TextSpan("cd", onPress: {})],
                style: {
                    var style = Style()
                    style.width = 100
                    style.height = 50
                    style.paddingLeft = .percent(10)
                    return style
                }(),
                textStyle: TextStyle(fontSize: 20)
            )
        }
        let resized = label()
        let harness = Harness(root: box({ $0.alignItems = .flexStart }, children: [resized]), width: 300)
        harness.pass()
        harness.update { $0.width = 200 }
        let commit = try #require(harness.pass())
        #expect(commit.entry(for: resized)?.frame == nil, "the frame stays")

        let fresh = label()
        let freshHarness = Harness(root: box({ $0.alignItems = .flexStart }, children: [fresh]), width: 200)
        freshHarness.pass()
        let expected = freshHarness.read { fresh.shadow.sentProps?.text?.links }
        #expect(expected?.first?.rects.first?.minX == 40)
        #expect(harness.read { resized.shadow.sentProps?.text?.links } == expected)
        #expect(commit.entry(for: resized)?.contents?.contents != nil, "redrawn at the new inset")
    }

    @Test func aNodeMovedWhileItsOldParentChangesKeepsItsNewParentsState() throws {
        let moved = box { $0.height = 10 }
        let rows = (0..<100).map { _ in box { $0.height = 50 } }
        rows[0].addChild(moved)
        let scroll = UltraScrollNode(style: { var style = Style(); style.height = 100; return style }(), children: rows)
        let newParent = box { $0.height = 20 }
        let harness = Harness(root: box(children: [scroll, newParent]))
        harness.pass()

        // The move is seen by the pass through the new parent only: the old
        // parent's mark comes after the pass started. In the same pass the
        // old parent leaves every range.
        newParent.addChild(moved)
        rows[0].needsSync.store(false, ordering: .sequentiallyConsistent)
        scroll.reportContentOffset(CGPoint(x: 0, y: 2000))
        harness.pass()
        rows[0].setNeedsSync()
        harness.pass()

        #expect(newParent.interfaceState == .all)
        #expect(moved.interfaceState == .all)
        #expect(harness.read { moved.shadow.isMounted && moved.shadow.parent === newParent })
    }
}
