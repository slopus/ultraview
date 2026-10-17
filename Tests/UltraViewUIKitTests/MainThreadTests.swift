#if canImport(UIKit)
import Testing
import UIKit
@testable import UltraCore
import UltraList
import UltraView

/// The main thread applies commits and does nothing else: no layout pass,
/// text measurement or drawing ever runs on it.
@MainActor
@Suite struct MainThreadTests {
    private func makeTree() -> (UltraNode, [UltraTextNode], [UltraNode]) {
        var texts: [UltraTextNode] = []
        var boxes: [UltraNode] = []
        let rows = (0..<30).map { index -> UltraNode in
            let text = UltraTextNode(spans: [
                TextSpan("Row \(index) ", style: TextStyle(fontWeight: .bold)),
                TextSpan("with a nested span that wraps onto another line when it is narrow"),
            ], style: styled { $0.flex = 1 })
            let box = UltraNode(style: styled {
                $0.width = 24
                $0.height = 24
                $0.borderTopWidth = 2
                $0.borderTopColor = .red
                $0.backgroundColor = .yellow
            })
            texts.append(text)
            boxes.append(box)
            return UltraNode(style: styled { $0.flexDirection = .row; $0.gap = 8 }, children: [box, text])
        }
        return (UltraNode(style: styled { $0.padding = 8; $0.gap = 4 }, children: rows), texts, boxes)
    }

    @Test func noLayoutTextOrDrawingOnTheMainThread() async throws {
        let before = Diagnostics.shared.counts
        let (root, texts, boxes) = makeTree()
        let hosted = Hosted(root, size: CGSize(width: 320, height: 2000))
        await hosted.settle()
        #expect(texts.allSatisfy { $0.view?.layer.contents != nil })
        let afterFirst = Diagnostics.shared.counts
        let firstCommits = hosted.host.statistics.current.commits
        #expect(firstCommits >= 1)

        // Mutate from several threads at once.
        await withTaskGroup(of: Void.self) { group in
            for (index, text) in texts.enumerated() {
                let box = boxes[index]
                group.addTask {
                    text.text = "Changed \(index) from a background task, long enough to wrap"
                    box.updateStyle { $0.borderTopColor = .blue; $0.width = 30 }
                }
            }
        }
        await hosted.settle()
        #expect(texts[3].view?.accessibilityLabel == "Changed 3 from a background task, long enough to wrap")
        #expect(boxes[0].view?.bounds.width == 30)

        let work = Diagnostics.shared.counts - afterFirst
        #expect(work.passes >= 1)
        #expect(work.measurements >= texts.count)
        #expect(work.draws >= texts.count + boxes.count)
        #expect(Diagnostics.shared.counts.mainThreadWork == 0)
        #expect((afterFirst - before).mainThreadWork == 0)

        let statistics = hosted.host.statistics.current
        #expect(statistics.commits > firstCommits)
        print("main-thread apply: \(statistics.commits) commits, average \(statistics.averageMilliseconds) ms, max \(statistics.maxMilliseconds) ms, last \(statistics.lastEntries) entries")
    }

    @Test func changesCoalesceIntoOnePass() async throws {
        let (root, texts, _) = makeTree()
        let hosted = Hosted(root, size: CGSize(width: 320, height: 2000))
        await hosted.settle()
        // Let trait updates that follow a host's first appearance pass.
        try await Task.sleep(for: .milliseconds(100))
        await hosted.settle()
        let renderer = hosted.host.renderer
        let before = renderer.passCount.load(ordering: .relaxed)
        for round in 0..<50 {
            texts[round % texts.count].text = "Round \(round)"
        }
        await hosted.settle()
        // Fifty changes made in one main-thread turn become one pass.
        #expect(renderer.passCount.load(ordering: .relaxed) - before == 1)
        #expect(texts[49 % texts.count].view?.accessibilityLabel == "Round 49")
    }

    @Test func viewsWaitForAWindowWhenAskedTo() async throws {
        let child = UltraNode(style: styled { $0.height = 20 })
        let root = UltraNode(children: [child])
        let host = NodeHostView(rootNode: root)
        host.keepsContentOutsideWindow = false
        host.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        host.layoutIfNeeded()
        await host.settle()
        #expect(child.view == nil)
        #expect(child.interfaceState.isEmpty)

        let window = makeWindow()
        window.frame = host.frame
        window.addSubview(host)
        window.isHidden = false
        await host.settle()
        #expect(child.view != nil)
        #expect(child.interfaceState == .all)

        host.removeFromSuperview()
        await host.settle()
        #expect(child.view == nil)
    }

    @Test func listViewAcceptsAViewport() throws {
        let list = UltraListView()
        list.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        list.layoutIfNeeded()
        #expect(list.loadedIndexRange.isEmpty)
        #expect(list.currentScrollOffset == 0)
    }

    @Test func contentIsPreparedOutsideAWindowAndKept() async throws {
        let label = UltraTextNode("Prepared ahead")
        let root = UltraNode(children: [label])
        let host = NodeHostView(rootNode: root)
        host.prepare(size: CGSize(width: 200, height: 100))
        await host.settle()
        #expect(host.hasContent)
        #expect(label.interfaceState == [.preload, .display])
        let view = try #require(label.view)
        #expect(view.layer.contents != nil)

        // In a window, the prepared views are shown as they are, before any
        // pass runs.
        let window = makeWindow()
        window.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        host.frame = window.bounds
        window.addSubview(host)
        window.isHidden = false
        host.layoutIfNeeded()
        #expect(label.view === view)
        #expect(root.view?.superview === host)
        await host.settle()
        #expect(label.view === view)
        #expect(label.interfaceState == .all)

        host.removeFromSuperview()
        await host.settle()
        #expect(label.view === view)
        #expect(view.layer.contents != nil)
    }

    @Test func theHostNeverWaitsForThePipeline() async throws {
        let rasterizer = HeldRasterizer()
        let label = UltraTextNode("Held")
        let host = NodeHostView(rootNode: UltraNode(children: [label]), rasterizer: rasterizer)
        let window = makeWindow()
        window.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        host.frame = window.bounds
        window.addSubview(host)
        window.isHidden = false

        // Drawing is held, so no commit can arrive; layout returns anyway.
        let start = Date()
        host.layoutIfNeeded()
        #expect(Date().timeIntervalSince(start) < 0.1)
        #expect(!host.hasContent)
        #expect(label.view == nil)

        rasterizer.release.signal()
        await host.settle()
        #expect(host.hasContent)
        #expect(label.view?.layer.contents != nil)
    }

}
/// Holds the first drawing until released.
private final class HeldRasterizer: Rasterizer {
    let release = DispatchSemaphore(value: 0)
    private let base = BitmapRasterizer()

    func rasterize(_ drawing: any Drawing, size: CGSize, scale: CGFloat, isCancelled: () -> Bool) -> Contents? {
        release.wait()
        release.signal()
        return base.rasterize(drawing, size: size, scale: scale, isCancelled: isCancelled)
    }
}
#endif
