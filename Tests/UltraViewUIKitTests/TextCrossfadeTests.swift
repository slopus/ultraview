#if canImport(UIKit)
import QuartzCore
import Testing
import UIKit
@testable import UltraCore
import UltraView

/// A changed text in stopped time, read from the presentation tree as Core
/// Animation composites it: a layer shows its bitmap at its opacity times
/// its ancestors', times the alpha of every mask on the way. Where a line
/// changed, the old bitmap shows at `1 - p` and the new one at `p`, `p` the
/// transition's progress, so together they never leave the line blank;
/// where it didn't, the new bitmap shows whole.
@MainActor
@Suite(.serialized) struct TextCrossfadeTests {
    enum Change: String, CaseIterable, CustomTestStringConvertible {
        /// Every glyph of the line changes, as a card's subtitle does.
        case rewrite
        /// The first line stays and the next one changes, as in a rewrap.
        case newTail
        /// Words are added at the end, as a streamed reply's.
        case append

        var texts: (old: String, new: String) {
            switch self {
            case .rewrite: ("170 points wide", "260 points wide")
            case .newTail: ("Hello there,\nold friend", "Hello there,\nnew words here")
            case .append: ("Sure, here", "Sure, here is more")
            }
        }

        var testDescription: String { rawValue }
    }

    /// A text with 10 points around it.
    private func page(_ string: String) -> (root: UltraNode, text: UltraTextNode) {
        let text = UltraTextNode(string, textStyle: TextStyle(fontSize: 17))
        text.transitionKey = "text"
        var style = Style()
        style.padding = 10
        return (UltraNode(style: style, children: [text]), text)
    }

    /// A linear second from time 1, with the host's clock stopped at 1.
    private func stoppedSecond(_ host: NodeHostView) throws -> NodeAnimationTiming {
        host.layer.speed = 0
        host.layer.timeOffset = 1
        return try linearSecond(from: 1)
    }

    private func linearSecond(from begin: CFTimeInterval) throws -> NodeAnimationTiming {
        let template = CABasicAnimation()
        template.beginTime = begin
        template.duration = 1
        template.timingFunction = CAMediaTimingFunction(name: .linear)
        return try #require(NodeAnimationTiming(matching: template))
    }

    private func show(_ time: CFTimeInterval, on host: NodeHostView) async throws {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        host.layer.timeOffset = time
        CATransaction.commit(); CATransaction.flush()
        try await Task.sleep(for: .milliseconds(35))
    }

    @Test(arguments: Change.allCases) func theOldAndNewTextAddUpWhereTheyChange(_ change: Change) async throws {
        let (root, label) = page(change.texts.old)
        let hosted = Hosted(root, size: CGSize(width: 360, height: 120))
        defer { hosted.window.isHidden = true }
        await hosted.settle()
        let host = hosted.host
        let text = try #require(label.view).layer
        let oldImage = try #require(image(text)), oldLines = try #require(label.appliedProps?.text?.lines)
        let before = host.transitionSnapshot()
        label.text = change.texts.new
        await hosted.settle()
        let newImage = try #require(image(text)), newLines = try #require(label.appliedProps?.text?.lines)
        let redrawn = oldImage !== newImage
        #expect(redrawn)
        host.animateTransition(from: before, timing: try stoppedSecond(host))

        // A point where the text changed, and one where it stayed.
        let lines = newLines.lines.map(\.rect), first = try #require(lines.first)
        let start = CGPoint(x: first.minX + 4, y: first.midY)
        let changed: CGPoint
        switch change {
        case .rewrite:
            changed = start
        case .newTail:
            #expect(oldLines.lines.count == 2 && lines.count == 2)
            let second = try #require(lines.last)
            changed = CGPoint(x: second.minX + 4, y: second.midY)
        case .append:
            let kept = try #require(oldLines.lines.first).rect
            changed = CGPoint(x: kept.maxX + 4, y: first.midY)
            #expect(changed.x < first.maxX - 4)
        }
        for phase in [0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0] {
            try await show(1 + phase, on: host)
            let old = shown(oldImage, at: changed, in: text, under: host.layer)
            let new = shown(newImage, at: changed, in: text, under: host.layer)
            let context = "\(change) at \(phase): old \(old), new \(new)"
            #expect(abs(new - phase) < 0.01, "the new tail fades in: \(context)")
            if change == .append {
                // Nothing was there before.
                #expect(old < 0.001, "\(context)")
            } else {
                #expect(abs(old - (1 - phase)) < 0.01, "the old tail fades out: \(context)")
                #expect(old + new > 0.98, "the line is never blank: \(context)")
            }
            if change != .rewrite {
                // The part the line keeps shows whole, with nothing over it.
                let kept = shown(newImage, at: start, in: text, under: host.layer)
                let covered = shown(oldImage, at: start, in: text, under: host.layer)
                #expect(abs(kept - 1) < 0.001 && covered < 0.001, "\(change) at \(phase): kept \(kept), old over it \(covered)")
            }
        }
    }

    /// A list shows each revision of a row in a host of its own. Halfway
    /// through one text change the next arrives: the newest bitmap fades in
    /// while both older ones fade out from where they were shown, so the
    /// line neither blanks nor brightens.
    @Test func aTextChangedAgainHalfwayFadesInOverBothOlderBitmaps() async throws {
        let window = makeWindow()
        window.frame = CGRect(x: 0, y: 0, width: 360, height: 400)
        let clock = UIView(frame: window.bounds)
        window.addSubview(clock)
        window.isHidden = false
        defer { window.isHidden = true }
        func host(_ string: String) async throws -> (host: NodeHostView, text: CALayer, image: CGImage) {
            let (root, label) = page(string)
            let host = NodeHostView(rootNode: root)
            host.frame = CGRect(x: 0, y: 0, width: 360, height: 120)
            clock.addSubview(host)
            host.layoutIfNeeded()
            await host.settle()
            let text = try #require(label.view).layer
            return (host, text, try #require(image(text)))
        }
        let first = try await host("170 points wide"), second = try await host("260 points wide"), third = try await host("350 points wide")
        clock.layer.speed = 0
        clock.layer.timeOffset = 1
        second.host.animateTransition(from: first.host.transitionSnapshot(), timing: try linearSecond(from: 1))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        clock.layer.timeOffset = 1.5
        CATransaction.commit(); CATransaction.flush()
        try await Task.sleep(for: .milliseconds(35))
        third.host.animateTransition(from: second.host.transitionSnapshot(), timing: try linearSecond(from: 1.5))

        let point = CGPoint(x: 4, y: 10)
        for phase in [0.0, 0.25, 0.5, 0.75, 1.0] {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            clock.layer.timeOffset = 1.5 + phase
            CATransaction.commit(); CATransaction.flush()
            try await Task.sleep(for: .milliseconds(35))
            let newest = shown(third.image, at: point, in: third.text, under: third.host.layer)
            let older = shown(first.image, at: point, in: third.text, under: third.host.layer)
                + shown(second.image, at: point, in: third.text, under: third.host.layer)
            let context = "at \(phase): newest \(newest), older \(older)"
            #expect(abs(newest - phase) < 0.01, "\(context)")
            #expect(abs(newest + older - 1) < 0.02, "the line adds up to one text: \(context)")
        }
    }

    /// A bitmap drawn while the text still fades in, with no transition of
    /// its own (a redraw, or a change the list doesn't animate), takes the
    /// place of the one fading in, and stays when the transition ends.
    @Test func aBitmapAppliedWhileTextFadesInReplacesTheOneFadingIn() async throws {
        let (root, label) = page("170 points wide")
        let hosted = Hosted(root, size: CGSize(width: 360, height: 120))
        defer { hosted.window.isHidden = true }
        await hosted.settle()
        let host = hosted.host
        let text = try #require(label.view).layer
        let first = try #require(image(text))
        let before = host.transitionSnapshot()
        label.text = "260 points wide"
        await hosted.settle()
        let second = try #require(image(text))
        host.layer.speed = 0
        host.layer.timeOffset = 1
        host.animateTransition(from: before, timing: try linearSecond(from: 1))
        try await show(1.25, on: host)
        label.text = "350 points wide"
        await hosted.settle()
        let newer = images(under: text).first { $0 !== first && $0 !== second }
        let latest = try #require(newer)

        let point = CGPoint(x: 4, y: 10)
        for phase in [0.25, 0.5, 0.75] {
            try await show(1 + phase, on: host)
            let new = shown(latest, at: point, in: text, under: host.layer), old = shown(first, at: point, in: text, under: host.layer)
            let context = "at \(phase): latest \(new), old \(old)"
            #expect(abs(new - phase) < 0.01, "\(context)")
            #expect(new + old > 0.98, "the line is never blank: \(context)")
        }
        // Ended, the latest bitmap is on the text's own layer, alone.
        host.cancelTransitions()
        let restored = image(text) === latest
        #expect(restored)
        #expect((text.sublayers ?? []).isEmpty && text.mask == nil)
    }

    /// A layer's bitmap. Bitmaps are compared by identity outside `#expect`
    /// and `#require`: one Swift compiler crashes expanding them over
    /// `AnyObject` identity.
    private func image(_ layer: CALayer) -> CGImage? {
        guard let contents = layer.contents.map({ $0 as AnyObject }), CFGetTypeID(contents) == CGImage.typeID else { return nil }
        return unsafeDowncast(contents, to: CGImage.self)
    }

    private func images(under layer: CALayer) -> [CGImage] {
        (image(layer).map { [$0] } ?? []) + (layer.sublayers ?? []).flatMap { images(under: $0) }
    }

    /// How much `image` shows at `point` (in `text`'s coordinates) on the
    /// layers of `text`'s subtree that show it, together.
    private func shown(_ image: CGImage, at point: CGPoint, in text: CALayer, under top: CALayer) -> Double {
        guard let textShown = text.presentation() else { return 0 }
        var total = 0.0
        var stack = [text]
        while let layer = stack.popLast() {
            stack += layer.sublayers ?? []
            guard self.image(layer) === image, let presented = layer.presentation() else { continue }
            total += shownOpacity(layer, at: presented.convert(point, from: textShown), under: top)
        }
        return total
    }

    /// `layer`'s opacity at `point` (in its coordinates): its and its
    /// ancestors' opacities up to `top`, times their masks' alpha there.
    private func shownOpacity(_ layer: CALayer, at point: CGPoint, under top: CALayer) -> Double {
        var alpha = 1.0
        var point = point
        var current = layer
        while true {
            let presented = current.presentation() ?? current
            alpha *= Double(presented.opacity)
            if let mask = current.mask { alpha *= maskAlpha(mask, at: point) }
            guard current !== top, let parent = current.superlayer else { return alpha }
            point = (parent.presentation() ?? parent).convert(point, from: presented)
            current = parent
        }
    }

    /// A mask's alpha at `point` in the masked layer's coordinates: its
    /// opaque regions at their presented opacities, over each other.
    private func maskAlpha(_ mask: CALayer, at point: CGPoint) -> Double {
        let local = CGPoint(x: point.x - mask.frame.minX, y: point.y - mask.frame.minY)
        var clear = 1.0
        for region in mask.sublayers ?? [] where region.frame.contains(local) {
            clear *= 1 - Double((region.presentation() ?? region).opacity)
        }
        return 1 - clear
    }
}
#endif
