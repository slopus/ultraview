#if canImport(UIKit)
import QuartzCore
import Testing
import UIKit
@testable import UltraCore
import UltraView

/// Layout transitions on real views: where their layers go, and what the
/// presentation tree shows at points along one timing.
@MainActor
@Suite(.serialized) struct NodeTransitionTests {
    /// A bubble in a row: a filled box with 6 points above and below it,
    /// and text inside with 12 points of padding. Its corners differ, as a
    /// chat bubble's do, so it is drawn into a bitmap rather than shown with
    /// layer properties.
    private func bubble(_ text: String) -> (root: UltraNode, text: UltraTextNode) {
        let label = UltraTextNode(text, textStyle: TextStyle(fontSize: 17))
        label.transitionKey = "text"
        var box = Style()
        box.flex = 1
        box.marginVertical = 6
        box.padding = 12
        box.borderRadius = 18
        box.borderBottomLeftRadius = 4
        box.backgroundColor = Color(white: 0.9, alpha: 1)
        let bubble = UltraNode(style: box, children: [label])
        bubble.transitionKey = "bubble"
        return (UltraNode(children: [bubble]), label)
    }

    private func layer(_ host: NodeHostView, _ key: String) throws -> CALayer {
        try #require(host.view(forTransitionKey: key)).layer
    }

    @Test func anOldBitmapFadesOutBelowTheViewsChildren() async throws {
        let (root, _) = bubble("Hello")
        let hosted = Hosted(root, size: CGSize(width: 320, height: 100))
        defer { hosted.window.isHidden = true }
        await hosted.settle()
        let before = hosted.host.transitionSnapshot()
        hosted.host.frame.size.height = 160
        hosted.host.layoutIfNeeded()
        await hosted.settle()
        hosted.host.animateTransition(from: before, timing: NodeAnimationTiming(duration: 1))

        // The box was drawn again at its new size, so its bitmap crossfades;
        // the old one must not cover the text.
        let box = try layer(hosted.host, "bubble"), text = try layer(hosted.host, "text")
        let sublayers = box.sublayers ?? []
        let ghost = try #require(sublayers.firstIndex { $0.name == "ultraview.node.ghost" })
        let label = try #require(sublayers.firstIndex { $0 === text })
        #expect(ghost < label)
    }

    @Test func innerFramesKeepTheirInsetsAtEveryPointOfOneTiming() async throws {
        let (root, label) = bubble("Hello")
        let hosted = Hosted(root, size: CGSize(width: 320, height: 100))
        defer { hosted.window.isHidden = true }
        await hosted.settle()
        let before = hosted.host.transitionSnapshot()
        label.text = "Hello, with enough words now to wrap onto a second line and a third one"
        hosted.host.frame.size.height = 160
        hosted.host.layoutIfNeeded()
        await hosted.settle()

        // Paused time: the animations begin at 1 and are read at 1 + phase.
        let host = hosted.host
        host.layer.speed = 0
        host.layer.timeOffset = 1
        let template = CABasicAnimation()
        template.beginTime = 1
        template.duration = 1
        template.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        host.animateTransition(from: before, timing: try #require(NodeAnimationTiming(matching: template)))

        let rootLayer = try #require(root.view).layer, box = try layer(host, "bubble"), text = try layer(host, "text")
        var heights: [CGFloat] = []
        for phase in [0.0, 0.2, 0.45, 0.7, 0.9, 1.0] {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            host.layer.timeOffset = 1 + phase
            CATransaction.commit(); CATransaction.flush()
            try await Task.sleep(for: .milliseconds(35))
            let target = try #require(host.layer.presentation())
            func frame(_ layer: CALayer) throws -> CGRect {
                let shown = try #require(layer.presentation())
                return shown.convert(shown.bounds, to: target)
            }
            let row = try frame(rootLayer), bubble = try frame(box), words = try frame(text)
            heights.append(row.height)
            #expect(abs(row.maxY - bubble.maxY - 6) < 0.01, "phase \(phase): bubble bottom \(bubble.maxY), row bottom \(row.maxY)")
            #expect(abs(bubble.minY - row.minY - 6) < 0.01, "phase \(phase)")
            #expect(abs(words.minX - bubble.minX - 12) < 0.01 && abs(words.minY - bubble.minY - 12) < 0.01, "phase \(phase): text \(words) in \(bubble)")
        }
        // The row did move: from its old height to its new one.
        #expect(abs(heights[0] - 100) < 0.01 && abs(heights[heights.count - 1] - 160) < 0.01)
        #expect(heights[2] > 100.5 && heights[2] < 159.5)
    }

    @Test func eachAxisFollowsTheTimingOfTheRowsSizeAlongIt() async throws {
        let (root, _) = bubble("Hello")
        let hosted = Hosted(root, size: CGSize(width: 200, height: 100))
        defer { hosted.window.isHidden = true }
        await hosted.settle()
        let before = hosted.host.transitionSnapshot()
        hosted.host.frame.size = CGSize(width: 320, height: 160)
        hosted.host.layoutIfNeeded()
        await hosted.settle()
        let host = hosted.host
        host.layer.speed = 0
        host.layer.timeOffset = 1
        func timing(_ duration: CFTimeInterval) throws -> NodeAnimationTiming {
            let template = CABasicAnimation()
            template.beginTime = 1
            template.duration = duration
            return try #require(NodeAnimationTiming(matching: template))
        }
        // The height runs a second; the width, added later, two.
        host.animateTransition(from: before, timing: try timing(1))
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(35))
        host.retimeTransitions(try timing(2), axis: .horizontal)

        // The box changes along both axes. The one-line text widens with it
        // but keeps its height and its top inset, so it moves along x only.
        let box = try layer(host, "bubble"), text = try layer(host, "text")
        func duration(_ layer: CALayer, _ keyPath: String) -> CFTimeInterval? { layer.animation(forKey: "ultraview.node.\(keyPath)")?.duration }
        #expect(duration(box, "position.x") == 2 && duration(box, "bounds.size.width") == 2)
        #expect(duration(box, "position.y") == 1 && duration(box, "bounds.size.height") == 1)
        #expect(duration(text, "position.x") == 2 && duration(text, "bounds.size.width") == 2)
        #expect(duration(text, "position.y") == nil && duration(text, "bounds.size.height") == nil)
    }

    @Test func aChangeAtOnceKeepsRunningContentMovingWithItsRow() async throws {
        let window = makeWindow()
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        let clock = UIView(frame: window.bounds)
        window.addSubview(clock)
        window.isHidden = false
        defer { window.isHidden = true }
        // Three revisions of one row, as a list shows them in turn: 100
        // high, then 160 animating, then 200 at once while that runs.
        func host(height: CGFloat) async -> NodeHostView {
            let host = NodeHostView(rootNode: bubble("Hello").root)
            host.frame = CGRect(x: 0, y: 0, width: 320, height: height)
            clock.addSubview(host)
            host.layoutIfNeeded()
            await host.settle()
            return host
        }
        let first = await host(height: 100), second = await host(height: 160), third = await host(height: 200)
        clock.layer.speed = 0
        clock.layer.timeOffset = 1
        let template = CABasicAnimation()
        template.beginTime = 1
        template.duration = 1
        template.timingFunction = CAMediaTimingFunction(name: .linear)
        second.animateTransition(from: first.transitionSnapshot(), timing: try #require(NodeAnimationTiming(matching: template)))
        third.continueTransitions(from: second.transitionSnapshot())

        let box = try layer(third, "bubble")
        for phase in [0.0, 0.25, 0.5, 0.75, 1.0] {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            clock.layer.timeOffset = 1 + phase
            CATransaction.commit(); CATransaction.flush()
            try await Task.sleep(for: .milliseconds(35))
            let height = try #require(box.presentation()).bounds.height
            // The running 88 -> 148, moved 40 points with its destination.
            #expect(abs(height - (88 + 60 * phase + 40)) < 0.01, "phase \(phase): \(height)")
        }
    }
}
#endif
