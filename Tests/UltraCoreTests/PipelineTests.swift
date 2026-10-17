import Dispatch
import Foundation
import Synchronization
import Testing
@testable import UltraCore
import UltraLayout

/// root (padding 10, gap 10)
///   a   (height 50, red)
///   b   (row, height 20)
///     c (flexGrow 1)
///     d (width 30)
private struct Tree {
    let root: UltraNode
    let a: UltraNode
    let b: UltraNode
    let c: UltraNode
    let d: UltraNode

    init() {
        a = box {
            $0.height = 50
            $0.backgroundColor = .red
        }
        c = box { $0.flexGrow = 1 }
        d = box { $0.width = 30 }
        b = box({
            $0.flexDirection = .row
            $0.height = 20
        }, children: [c, d])
        root = box({
            $0.padding = 10
            $0.gap = 10
            $0.backgroundColor = .white
        }, children: [a, b])
    }
}

@Suite struct PipelineTests {
    @Test func firstPassMountsEveryNodeWithFrames() throws {
        let tree = Tree()
        let harness = Harness(root: tree.root)

        let commit = try #require(harness.pass())

        #expect(commit.entries.count == 5)
        #expect(commit.entries.values.allSatisfy { $0.kind == .mount })
        let root = try #require(commit.entry(for: tree.root))
        #expect(root.parent == nil)
        #expect(root.depth == 0)
        #expect(root.frame == CGRect(x: 0, y: 0, width: 300, height: 600))
        #expect(same(root.children, [tree.a, tree.b]))
        #expect(commit.entry(for: tree.a)?.frame == CGRect(x: 10, y: 10, width: 280, height: 50))
        #expect(commit.entry(for: tree.b)?.frame == CGRect(x: 10, y: 70, width: 280, height: 20))
        #expect(commit.entry(for: tree.c)?.frame == CGRect(x: 0, y: 0, width: 250, height: 20))
        #expect(commit.entry(for: tree.d)?.frame == CGRect(x: 250, y: 0, width: 30, height: 20))
        #expect(commit.entry(for: tree.c)?.parent === tree.b)
        #expect(commit.entry(for: tree.c)?.depth == 2)
        #expect(same(commit.entry(for: tree.b)?.children, [tree.c, tree.d]))
        #expect(commit.entry(for: tree.a)?.props?.backgroundColor == Color.red.light)
        #expect(tree.d.interfaceState == .all)
        #expect(harness.rasterizer.count == 0, "plain boxes are layer properties, not bitmaps")
    }

    @Test func outOfWindowTreesAreLaidOutButNotMounted() throws {
        let tree = Tree()
        let harness = Harness(root: tree.root, inWindow: false)

        let first = try #require(harness.pass())
        #expect(first.isEmpty)
        #expect(harness.read { tree.a.shadow.frame } == CGRect(x: 10, y: 10, width: 280, height: 50))
        #expect(tree.a.interfaceState == [])

        harness.update { $0.inWindow = true }
        let second = try #require(harness.pass())
        #expect(second.nodes(.mount) == ids([tree.root, tree.a, tree.b, tree.c, tree.d]))

        harness.update { $0.inWindow = false }
        let third = try #require(harness.pass())
        #expect(third.nodes(.unmount) == ids([tree.root, tree.a, tree.b, tree.c, tree.d]))
        #expect(tree.root.interfaceState == [])
    }

    @Test func aColorChangeUpdatesOnlyThatNode() throws {
        let tree = Tree()
        let harness = Harness(root: tree.root)
        harness.pass()

        tree.a.updateStyle { $0.backgroundColor = .blue }
        let commit = try #require(harness.pass())

        #expect(commit.entries.count == 1)
        let entry = try #require(commit.entry(for: tree.a))
        #expect(entry.kind == .update)
        #expect(entry.props?.backgroundColor == Color.blue.light)
        #expect(entry.frame == nil)
        #expect(entry.contents == nil)
    }

    @Test func aSizeChangeUpdatesTheFramesThatMoved() throws {
        let tree = Tree()
        let harness = Harness(root: tree.root)
        harness.pass()

        tree.a.updateStyle { $0.height = 80 }
        let commit = try #require(harness.pass())

        #expect(Set(commit.entries.keys) == ids([tree.a, tree.b]))
        #expect(commit.entry(for: tree.a)?.frame == CGRect(x: 10, y: 10, width: 280, height: 80))
        #expect(commit.entry(for: tree.b)?.frame == CGRect(x: 10, y: 100, width: 280, height: 20))
        #expect(commit.entry(for: tree.b)?.props == nil)
    }

    @Test func noChangeNoCommit() {
        let tree = Tree()
        let harness = Harness(root: tree.root)
        harness.pass()

        tree.a.style = tree.a.style
        #expect(harness.pass() == nil)
    }

    @Test func addingAndRemovingChildren() throws {
        let tree = Tree()
        let harness = Harness(root: tree.root)
        harness.pass()

        let e = box { $0.height = 5 }
        tree.root.addChild(e)
        let added = try #require(harness.pass())
        #expect(added.entry(for: e)?.kind == .mount)
        #expect(added.entry(for: e)?.parent === tree.root)
        #expect(added.entry(for: e)?.frame == CGRect(x: 10, y: 100, width: 280, height: 5))
        #expect(same(added.entry(for: tree.root)?.children, [tree.a, tree.b, e]))

        tree.root.removeChild(tree.a)
        let removed = try #require(harness.pass())
        #expect(removed.entry(for: tree.a)?.kind == .unmount)
        #expect(same(removed.entry(for: tree.root)?.children, [tree.b, e]))
        #expect(removed.entry(for: tree.b)?.frame?.minY == 10)
        #expect(tree.a.interfaceState == [])
        #expect(tree.a.parent == nil)
    }

    @Test func movingANodeRemountsItUnderTheNewParent() throws {
        let tree = Tree()
        let harness = Harness(root: tree.root)
        harness.pass()

        tree.root.addChild(tree.c)
        let commit = try #require(harness.pass())

        let entry = try #require(commit.entry(for: tree.c))
        #expect(entry.kind == .mount)
        #expect(entry.parent === tree.root)
        #expect(entry.depth == 1)
        #expect(same(commit.entry(for: tree.b)?.children, [tree.d]))
        #expect(same(commit.entry(for: tree.root)?.children, [tree.a, tree.b, tree.c]))
        #expect(tree.c.parent === tree.root)
        #expect(tree.b.children.count == 1)
    }

    @Test func setChildrenReordersInOneCommit() throws {
        let tree = Tree()
        let harness = Harness(root: tree.root)
        harness.pass()

        tree.root.setChildren([tree.b, tree.a])
        let commit = try #require(harness.pass())

        #expect(same(commit.entry(for: tree.root)?.children, [tree.b, tree.a]))
        #expect(commit.entry(for: tree.b)?.frame?.minY == 10)
        #expect(commit.entry(for: tree.a)?.frame?.minY == 40)
        #expect(commit.nodes(.mount).isEmpty)
    }

    @Test func sizeChangesComeFromTheHost() throws {
        let tree = Tree()
        let harness = Harness(root: tree.root)
        harness.pass()

        harness.update { $0.width = 200 }
        let commit = try #require(harness.pass())

        #expect(commit.entry(for: tree.root)?.frame?.width == 200)
        #expect(commit.entry(for: tree.c)?.frame?.width == 150)
        #expect(commit.entry(for: tree.d)?.frame?.minX == 150)
    }

    @Test func everyRequestIsAnswered() throws {
        let tree = Tree()
        let harness = Harness(root: tree.root)
        harness.pass()

        harness.update { _ in }
        let commit = try #require(harness.pass(), "a waiting host needs a commit even when nothing changed")
        #expect(commit.isEmpty)
        #expect(commit.request == harness.renderer.currentInputs.request)
    }

    @Test func boxStylesBecomeLayerPropertiesWhenTheyCan() throws {
        let uniform = box {
            $0.width = 40
            $0.height = 20
            $0.backgroundColor = .green
            $0.borderWidth = 2
            $0.borderColor = .blue
            $0.borderRadius = 100
        }
        let someCorners = box {
            $0.width = 40
            $0.height = 20
            $0.borderTopLeftRadius = 6
            $0.borderBottomRightRadius = 6
        }
        let mixedSides = box {
            $0.width = 40
            $0.height = 20
            $0.backgroundColor = .white
            $0.borderTopWidth = 4
            $0.borderColor = .red
        }
        let mixedRadii = box {
            $0.width = 40
            $0.height = 20
            $0.backgroundColor = .white
            $0.borderTopLeftRadius = 4
            $0.borderTopRightRadius = 8
        }
        let root = box({ $0.alignItems = .flexStart }, children: [uniform, someCorners, mixedSides, mixedRadii])
        let harness = Harness(root: root)

        let commit = try #require(harness.pass())

        let props = try #require(commit.entry(for: uniform)?.props)
        #expect(props.cornerRadius == 10, "clamped to half the shorter side")
        #expect(props.borderWidth == 2)
        #expect(props.borderColor == Color.blue.light)
        #expect(props.backgroundColor == Color.green.light)
        #expect(commit.entry(for: uniform)?.contents == nil)

        let corners = try #require(commit.entry(for: someCorners)?.props)
        #expect(corners.cornerRadius == 6)
        #expect(corners.maskedCorners == [.topLeft, .bottomRight])

        #expect(commit.entry(for: mixedSides)?.props?.backgroundColor == nil)
        #expect(commit.entry(for: mixedSides)?.props?.borderWidth == 0)
        #expect(commit.entry(for: mixedSides)?.contents?.contents != nil)
        #expect(commit.entry(for: mixedRadii)?.contents?.contents != nil)
        #expect(harness.rasterizer.draws.withLock { $0.filter(\.hasBox).count } == 2)
    }

    @Test func visualStyleResolvesToViewProps() throws {
        let node = box {
            $0.height = 40
            $0.width = 40
            $0.opacity = 0.5
            $0.transform = [.translateX(10), .scale(2)]
            $0.overflow = .hidden
            $0.backgroundColor = .white
            $0.borderRadius = 4
            $0.shadowColor = .black
            $0.shadowOpacity = 0.3
            $0.shadowRadius = 6
            $0.shadowOffset = CGSize(width: 0, height: 2)
            $0.pointerEvents = .boxNone
            $0.hitSlop = Insets(all: 8)
        }
        node.pressedOpacity = 0.4
        node.accessibility = Accessibility(label: "Card", role: .button)
        let hidden = box { $0.display = .none }
        let harness = Harness(root: box({ $0.alignItems = .flexStart }, children: [node, hidden]))

        let commit = try #require(harness.pass())
        let props = try #require(commit.entry(for: node)?.props)

        #expect(props.opacity == 0.5)
        #expect(props.transform == Transform3D([.translateX(10), .scale(2)]))
        #expect(props.clipsToBounds)
        #expect(props.shadow == ShadowProps(
            color: Color.black.light,
            opacity: 0.3,
            offset: CGSize(width: 0, height: 2),
            radius: 6,
            path: RoundedRect(rect: CGRect(x: 0, y: 0, width: 40, height: 40), cornerRadius: 4)
        ))
        #expect(props.pointerEvents == .boxNone)
        #expect(props.hitSlop == Insets(all: 8))
        #expect(props.pressedOpacity == 0.4)
        #expect(!props.isPressable)
        #expect(props.accessibility == AccessibilityProps(isElement: true, label: "Card", role: .button))
        #expect(commit.entry(for: hidden)?.props?.isHidden == true)
    }

    @Test func pressHandlersMakeANodePressable() throws {
        let node = box { $0.height = 10 }
        let harness = Harness(root: box(children: [node]))
        harness.pass()

        node.onPress = {}
        let commit = try #require(harness.pass())
        #expect(commit.entry(for: node)?.props?.isPressable == true)

        node.onLongPress = {}
        #expect(harness.pass() == nil, "still pressable: nothing to send")
    }

    @Test func darkAppearanceResolvesDynamicColors() throws {
        let dynamic = Color.dynamic(light: .white, dark: .black)
        let node = box {
            $0.height = 10
            $0.backgroundColor = dynamic
        }
        let harness = Harness(root: box(children: [node]))
        #expect(harness.pass()?.entry(for: node)?.props?.backgroundColor == Color.white.light)

        harness.update { $0.environment.isDark = true }
        let commit = try #require(harness.pass())
        #expect(commit.entry(for: node)?.props?.backgroundColor == Color.black.light)
    }

    @Test func customDrawingsAreDrawnAndRedrawnWhenReplaced() throws {
        struct Stripes: Drawing {}
        let node = box { $0.height = 10 }
        node.drawing = Stripes()
        let harness = Harness(root: box(children: [node]))

        let first = try #require(harness.pass())
        #expect(first.entry(for: node)?.contents?.contents != nil)
        #expect(harness.rasterizer.count == 1)

        node.updateStyle { $0.opacity = 0.5 }
        harness.pass()
        #expect(harness.rasterizer.count == 1, "opacity is a layer property")

        node.drawing = Stripes()
        let second = try #require(harness.pass())
        #expect(second.entry(for: node)?.contents?.contents != nil)
        #expect(harness.rasterizer.count == 2)
    }

    @Test func pipelineWorkStaysOffTheMainThread() {
        let before = Diagnostics.shared.counts
        let tree = Tree()
        let label = text("Hello")
        tree.root.addChild(label)
        let harness = Harness(root: tree.root)
        harness.pass()
        label.text = "Changed"
        harness.pass()

        let counts = Diagnostics.shared.counts - before
        #expect(counts.passes >= 2)
        #expect(counts.measurements >= 2)
        #expect(counts.draws >= 2)
        #expect(Diagnostics.shared.counts.mainThreadWork == 0)
        #expect(harness.measurer.calls.withLock { $0.allSatisfy { !$0.onMain } })
        #expect(harness.rasterizer.draws.withLock { $0.allSatisfy { !$0.onMain } })
    }
}

@Suite struct SchedulingTests {
    @Test func mutationsFromManyThreadsCoalesce() throws {
        let leaves = (0..<16).map { _ in box { $0.height = 10 } }
        let root = box(children: leaves)
        let harness = Harness(root: root, automatic: true)
        harness.renderer.waitUntilIdle()
        _ = harness.mailbox.take()
        let passesBefore = harness.renderer.passCount.load(ordering: .relaxed)

        let threads = 8
        let changesPerThread = 200
        DispatchQueue.concurrentPerform(iterations: threads) { thread in
            for step in 0..<changesPerThread {
                let leaf = leaves[(thread * 2 + step) % leaves.count]
                leaf.updateStyle { $0.opacity = CGFloat(step % 10) / 10 }
            }
        }
        // Make the final values known: one last write per leaf.
        for (index, leaf) in leaves.enumerated() {
            leaf.updateStyle { $0.opacity = CGFloat(index) / 100 }
        }
        harness.renderer.waitUntilIdle()

        let passes = harness.renderer.passCount.load(ordering: .relaxed) - passesBefore
        #expect(passes >= 1)
        #expect(passes < threads * changesPerThread / 4, "\(passes) passes for \(threads * changesPerThread) changes")

        // Every commit landed in the mailbox and merged; its newest values
        // are the final ones.
        let merged = try #require(harness.mailbox.take())
        for (index, leaf) in leaves.enumerated() {
            #expect(merged.entry(for: leaf)?.props?.opacity == CGFloat(index) / 100)
        }
        #expect(harness.mailbox.take() == nil)
    }

    @Test func aChangeAfterAPassSchedulesAnother() {
        let leaf = box { $0.height = 10 }
        let harness = Harness(root: box(children: [leaf]), automatic: true)
        harness.renderer.waitUntilIdle()
        let before = harness.renderer.passCount.load(ordering: .relaxed)

        leaf.updateStyle { $0.height = 20 }
        harness.renderer.waitUntilIdle()

        #expect(harness.renderer.passCount.load(ordering: .relaxed) == before + 1)
        #expect(harness.read { leaf.shadow.frame.height } == 20)
    }

    @Test func detachedTreesScheduleNothing() {
        let leaf = box { $0.height = 10 }
        let root = box(children: [leaf])
        let harness = Harness(root: root, automatic: true)
        harness.renderer.waitUntilIdle()
        let before = harness.renderer.passCount.load(ordering: .relaxed)

        let orphan = box(children: [box()])
        orphan.children[0].updateStyle { $0.height = 3 }
        harness.renderer.waitUntilIdle()
        #expect(harness.renderer.passCount.load(ordering: .relaxed) == before)

        root.addChild(orphan)
        harness.renderer.waitUntilIdle()
        #expect(harness.read { orphan.children[0].shadow.frame.height } == 3)
    }

    @Test func generationsIncreaseAndTheMailboxKeepsTheNewestValues() throws {
        let a = box {
            $0.height = 10
            $0.backgroundColor = .red
        }
        let b = box { $0.height = 10 }
        let harness = Harness(root: box(children: [a, b]))
        harness.pass()
        _ = harness.mailbox.take()

        a.updateStyle { $0.backgroundColor = .blue }
        let first = try #require(harness.pass())
        a.updateStyle { $0.backgroundColor = .green }
        b.updateStyle { $0.height = 30 }
        let second = try #require(harness.pass())
        #expect(second.generation > first.generation)

        let merged = try #require(harness.mailbox.take())
        #expect(merged.generation == second.generation)
        #expect(merged.entry(for: a)?.props?.backgroundColor == Color.green.light)
        #expect(merged.entry(for: b)?.frame?.height == 30)
        #expect(merged.entries.count == 2)
    }

    @Test func displayWorkForANodeThatChangesIsCancelled() throws {
        let label = text("first")
        let harness = Harness(root: box(children: [label]))
        harness.rasterizer.gate.withLock { $0 = RecordingRasterizer.Gate(text: "first") }
        let gate = try #require(harness.rasterizer.gate.withLock { $0 })

        let passDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            harness.renderer.runPassNow()
            passDone.signal()
        }
        gate.started.wait()
        label.text = "second"
        gate.release.signal()
        passDone.wait()

        #expect(harness.rasterizer.cancelled.withLock { $0 } == ["first"])
        let first = try #require(harness.commits.last)
        #expect(first.entry(for: label)?.kind == .mount)
        #expect(first.entry(for: label)?.contents == nil, "the cancelled bitmap is dropped")

        let second = try #require(harness.pass())
        #expect(second.entry(for: label)?.contents?.contents != nil)
        #expect(harness.rasterizer.drawnTexts == ["first", "second"])
    }

    @Test func displayWorkForANodeThatLeavesIsCancelled() throws {
        let label = text("leaving")
        let root = box(children: [label])
        let harness = Harness(root: root)
        harness.rasterizer.gate.withLock { $0 = RecordingRasterizer.Gate(text: "leaving") }
        let gate = try #require(harness.rasterizer.gate.withLock { $0 })

        let passDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            harness.renderer.runPassNow()
            passDone.signal()
        }
        gate.started.wait()
        root.removeChild(label)
        gate.release.signal()
        passDone.wait()

        #expect(harness.rasterizer.cancelled.withLock { $0 } == ["leaving"])
        let next = try #require(harness.pass())
        #expect(next.entry(for: label)?.kind == .unmount)
    }
}

@Suite struct CommitMergeTests {
    private func commit(_ generation: UInt64, _ entries: [CommitEntry]) -> Commit {
        var commit = Commit(generation: generation, request: generation)
        entries.forEach { commit.record($0) }
        return commit
    }

    private func entry(_ kind: CommitEntry.Kind, _ node: UltraNode, frame: CGRect? = nil, opacity: CGFloat? = nil) -> CommitEntry {
        var entry = CommitEntry(kind: kind, node: node)
        entry.frame = frame
        if let opacity {
            var props = ViewProps()
            props.opacity = opacity
            entry.props = props
        }
        return entry
    }

    @Test func newerFieldsWinAndOlderOnesStay() {
        let node = UltraNode()
        var merged = commit(1, [entry(.update, node, frame: CGRect(x: 0, y: 0, width: 1, height: 1), opacity: 0.1)])
        merged.merge(commit(2, [entry(.update, node, opacity: 0.9)]))

        #expect(merged.generation == 2)
        #expect(merged.entry(for: node)?.props?.opacity == 0.9)
        #expect(merged.entry(for: node)?.frame == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test func aMountStaysAMountWhenUpdated() {
        let node = UltraNode()
        var merged = commit(1, [entry(.mount, node, frame: .zero, opacity: 1)])
        merged.merge(commit(2, [entry(.update, node, opacity: 0.5)]))

        #expect(merged.entry(for: node)?.kind == .mount)
        #expect(merged.entry(for: node)?.props?.opacity == 0.5)
    }

    @Test func anUnmountReplacesEverything() {
        let node = UltraNode()
        var merged = commit(1, [entry(.mount, node, frame: .zero, opacity: 1)])
        merged.merge(commit(2, [entry(.unmount, node)]))

        #expect(merged.entry(for: node)?.kind == .unmount)
        #expect(merged.entry(for: node)?.props == nil)
    }

    @Test func aRemountReplacesTheUnmount() {
        let node = UltraNode()
        var merged = commit(1, [entry(.unmount, node)])
        merged.merge(commit(2, [entry(.mount, node, frame: .zero, opacity: 1)]))

        #expect(merged.entry(for: node)?.kind == .mount)
    }

    @Test func mailboxMergesUntilTaken() {
        let node = UltraNode()
        let mailbox = CommitMailbox()
        #expect(mailbox.post(commit(1, [entry(.update, node, opacity: 0.1)])))
        #expect(!mailbox.post(commit(2, [entry(.update, node, opacity: 0.2)])))
        #expect(mailbox.take(servingRequest: 3) == nil)
        #expect(!mailbox.post(commit(3, [entry(.update, node, opacity: 0.3)])))

        let taken = mailbox.take(servingRequest: 3)
        #expect(taken?.generation == 3)
        #expect(taken?.entry(for: node)?.props?.opacity == 0.3)
        #expect(mailbox.take() == nil)
        #expect(mailbox.post(commit(4, [])))
    }
}

extension Commit: Equatable {
    public static func == (lhs: Commit, rhs: Commit) -> Bool {
        lhs.generation == rhs.generation
    }
}
