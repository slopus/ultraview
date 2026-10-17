import Dispatch
import Foundation
import Synchronization
import Testing
@testable import UltraCore
import UltraLayout

/// Views as the main thread would hold them, built only from commits. It
/// follows the same rules as the UIKit applier: unmounts first, then mounts
/// from the root down, then frames, properties, contents and child order.
private final class ViewModel {
    final class View {
        var frame: CGRect?
        var props: ViewProps?
        var contentsID: UInt64?
        var subviews: [ObjectIdentifier] = []
        var superview: ObjectIdentifier?
        var mountedChildren: [UltraNode] = []
    }

    static let host = ObjectIdentifier(ViewModel.self)
    var views: [ObjectIdentifier: View] = [:]
    var applied = 0

    func apply(_ commit: Commit, root: UltraNode) {
        applied += 1
        let entries = commit.orderedEntries
        for entry in entries where entry.kind == .unmount {
            unmount(entry.node)
        }
        let mounts = entries.filter { $0.kind == .mount }.sorted { $0.depth < $1.depth }
        for entry in mounts where views[ObjectIdentifier(entry.node)] == nil {
            views[ObjectIdentifier(entry.node)] = View()
        }
        for entry in entries where entry.kind != .unmount {
            guard let view = views[ObjectIdentifier(entry.node)] else { continue }
            if let frame = entry.frame { view.frame = frame }
            if let props = entry.props { view.props = props }
            switch entry.contents {
            case .set(let contents)?: view.contentsID = contents.id
            case .clear?: view.contentsID = nil
            case nil: if entry.kind == .mount { view.contentsID = nil }
            }
            if let children = entry.children {
                order(children, in: entry.node)
            }
        }
        let rootID = ObjectIdentifier(root)
        if let rootView = views[rootID], rootView.superview == nil {
            rootView.superview = Self.host
        }
        for entry in mounts where entry.node !== root && views[ObjectIdentifier(entry.node)]?.superview == nil {
            unmount(entry.node)
        }
    }

    private func unmount(_ node: UltraNode) {
        let id = ObjectIdentifier(node)
        guard let view = views[id] else { return }
        for child in view.mountedChildren where views[ObjectIdentifier(child)]?.superview == id {
            unmount(child)
        }
        detachFromSuperview(id)
        views[id] = nil
    }

    private func detachFromSuperview(_ id: ObjectIdentifier) {
        guard let view = views[id], let superID = view.superview else { return }
        views[superID]?.subviews.removeAll { $0 == id }
        view.superview = nil
    }

    private func order(_ children: [UltraNode], in parent: UltraNode) {
        let parentID = ObjectIdentifier(parent)
        guard let view = views[parentID] else { return }
        view.mountedChildren = children
        let wanted = children.map(ObjectIdentifier.init).filter { views[$0] != nil }
        for id in wanted where views[id]?.superview != parentID {
            detachFromSuperview(id)
            views[id]?.superview = parentID
        }
        let wantedSet = Set(wanted)
        view.subviews = wanted + view.subviews.filter { !wantedSet.contains($0) }
    }
}

/// A splittable, seeded generator so each thread's sequence of changes is
/// reproducible (the interleaving of threads is not).
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state ^ (state >> 29)
    }
}

@Suite struct StressTests {
    /// Threads change styles, text and the tree's shape while passes run,
    /// and a consumer applies commits as they arrive, the way the main
    /// thread does. Once everything settles, the views built from commits
    /// alone must match the tree exactly: the right views, frames,
    /// properties, bitmaps and order, and nothing left over.
    @Test(arguments: [1, 2, 3])
    func viewsBuiltFromCommitsMatchTheTree(seed: Int) throws {
        let containers = (0..<4).map { _ in
            box {
                $0.flexDirection = .row
                $0.flexWrap = .wrap
                $0.padding = 4
            }
        }
        let boxes = (0..<24).map { index in
            box {
                $0.width = .points(CGFloat(10 + index))
                $0.height = 12
                $0.backgroundColor = .red
            }
        }
        let texts = (0..<8).map { text("label \($0)", fontSize: 10) }
        let leaves: [UltraNode] = boxes + texts
        for (index, leaf) in leaves.enumerated() {
            containers[index % containers.count].addChild(leaf)
        }
        let root = box(children: containers)
        let harness = Harness(root: root, automatic: true, width: 320, height: 2000)

        let model = ViewModel()
        let done = Atomic<Bool>(false)
        let consumerFinished = DispatchSemaphore(value: 0)
        let modelBox = UncheckedBox(model)
        Thread.detachNewThread {
            while !done.load(ordering: .acquiring) {
                if let commit = harness.mailbox.take() {
                    modelBox.value.apply(commit, root: root)
                    // Slower than the passes, as a main thread busy with
                    // frames is, so commits pile up and merge.
                    usleep(1_000)
                } else {
                    _ = harness.mailbox.waitForPost(until: .now() + .milliseconds(5))
                }
            }
            consumerFinished.signal()
        }

        let colors: [Color] = [.red, .blue, .green, .clear]
        DispatchQueue.concurrentPerform(iterations: 6) { thread in
            var random = SeededGenerator(state: UInt64(seed * 1000 + thread))
            for step in 0..<300 {
                // Spread the changes out so many passes run among them.
                usleep(100)
                let leaf = leaves.randomElement(using: &random)!
                switch Int.random(in: 0..<100, using: &random) {
                case 0..<35:
                    leaf.updateStyle {
                        $0.height = .points(CGFloat(Int.random(in: 8...30, using: &random)))
                        $0.backgroundColor = colors.randomElement(using: &random)
                        // Per-side borders are drawn rather than set on the layer.
                        $0.borderTopWidth = Bool.random(using: &random) ? 2 : nil
                        $0.borderTopColor = .black
                    }
                case 35..<50:
                    texts.randomElement(using: &random)!.text = String(repeating: "w", count: Int.random(in: 0...40, using: &random))
                case 50..<70:
                    let container = containers.randomElement(using: &random)!
                    container.insertChild(leaf, at: Int.random(in: 0...10, using: &random))
                case 70..<80:
                    leaf.removeFromParent()
                case 80..<90:
                    let container = containers.randomElement(using: &random)!
                    var children = container.children
                    children.shuffle(using: &random)
                    if Bool.random(using: &random), !children.isEmpty {
                        children.removeLast()
                    }
                    container.setChildren(children)
                case 90..<96:
                    containers.randomElement(using: &random)!.updateStyle {
                        $0.display = Bool.random(using: &random) ? .flex : .none
                        $0.opacity = CGFloat(step % 4) / 4
                    }
                default:
                    let width = CGFloat(Int.random(in: 200...400, using: &random))
                    let inWindow = Int.random(in: 0..<4, using: &random) != 0
                    harness.update {
                        $0.width = width
                        $0.inWindow = inWindow
                    }
                }
            }
        }
        // Back in a window at a known size, then let everything finish.
        harness.update {
            $0.width = 320
            $0.inWindow = true
        }
        harness.renderer.waitUntilIdle()
        done.store(true, ordering: .releasing)
        consumerFinished.wait()
        if let last = harness.mailbox.take() {
            model.apply(last, root: root)
        }
        #expect(model.applied > 1)

        // The truth, read where it lives.
        struct Expected: Sendable {
            var frame: CGRect
            var props: ViewProps?
            var contentsID: UInt64?
            var children: [ObjectIdentifier]
        }
        let expected: [ObjectIdentifier: Expected] = harness.read {
            var result: [ObjectIdentifier: Expected] = [:]
            func visit(_ node: UltraNode) {
                let shadow = node.shadow
                result[ObjectIdentifier(node)] = Expected(
                    frame: shadow.frame,
                    props: shadow.sentProps,
                    contentsID: shadow.contents?.id,
                    children: shadow.children.map(ObjectIdentifier.init)
                )
                shadow.children.forEach(visit)
            }
            visit(root)
            return result
        }

        // The pipeline saw the final tree.
        func treeIDs(_ node: UltraNode) -> [ObjectIdentifier] {
            [ObjectIdentifier(node)] + node.children.flatMap(treeIDs)
        }
        #expect(Set(treeIDs(root)) == Set(expected.keys))

        // The views match it, with nothing extra.
        #expect(Set(model.views.keys) == Set(expected.keys))
        for (id, truth) in expected {
            guard let view = model.views[id] else { continue }
            #expect(view.frame == truth.frame)
            #expect(view.props == truth.props)
            #expect(view.contentsID == truth.contentsID)
            #expect(view.subviews == truth.children)
            for child in truth.children {
                #expect(model.views[child]?.superview == id)
            }
        }
        // Every text with room in the tree is laid out and drawn from its
        // current text.
        for label in texts {
            guard let truth = expected[ObjectIdentifier(label)], truth.frame.width > 0, truth.frame.height > 0 else { continue }
            #expect(harness.read { label.currentTextLayout?.text.string } == label.text)
            #expect(truth.contentsID != nil)
        }
        #expect(Diagnostics.shared.counts.mainThreadWork == 0)
    }
}

/// Hands the model to the consumer thread. The test thread touches it only
/// after the consumer has signalled that it finished.
private final class UncheckedBox<Value>: @unchecked Sendable {
    // @unchecked Sendable: used by one thread at a time, handed over through
    // a semaphore.
    let value: Value
    init(_ value: Value) { self.value = value }
}
