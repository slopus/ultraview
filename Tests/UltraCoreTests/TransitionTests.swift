import Foundation
import Testing
@testable import UltraCore
import UltraLayout

@Suite struct TrailingAccessoryFitTests {
    private func layout(_ widths: [CGFloat], alignment: TextLayout.Alignment = .left, maxWidth: CGFloat? = 200) -> TextLayout {
        var top: CGFloat = 0
        var start = 0
        let lines = widths.map { width -> TextLayout.Line in
            defer { top += 24; start += 10 }
            return TextLayout.Line(range: start..<(start + 10), top: top, height: 24, baseline: top + 19, width: width)
        }
        return TextLayout(
            text: AttributedText(string: String(repeating: "x", count: start), runs: [], paragraph: .init(), linkCount: 0),
            maxWidth: maxWidth,
            size: CGSize(width: widths.max() ?? 0, height: top),
            lines: lines,
            alignment: alignment,
            isTruncated: false,
            didWrap: widths.count > 1
        )
    }

    @Test func sharesTheLastLineWhenItLeavesRoom() {
        let fit = TrailingAccessoryFit.fit(layout([180, 90]), accessory: CGSize(width: 40, height: 14), spacing: 6, maxWidth: 200, scale: 2)
        #expect(fit == TrailingAccessoryFit(placement: .inline, size: CGSize(width: 180, height: 48)))
    }

    @Test func aShortSingleLineWidensToHoldTheAccessory() {
        let fit = TrailingAccessoryFit.fit(layout([50]), accessory: CGSize(width: 30, height: 14), spacing: 6, maxWidth: 200, scale: 2)
        #expect(fit == TrailingAccessoryFit(placement: .inline, size: CGSize(width: 86, height: 24)))
    }

    @Test func exactlyFillingTheLimitStillFits() {
        let fit = TrailingAccessoryFit.fit(layout([154]), accessory: CGSize(width: 40, height: 14), spacing: 6, maxWidth: 200, scale: 2)
        #expect(fit.placement == .inline)
        #expect(fit.size.width == 200)
    }

    @Test func aFullLastLinePutsTheAccessoryBelow() {
        let fit = TrailingAccessoryFit.fit(layout([180, 170]), accessory: CGSize(width: 40, height: 14), spacing: 6, maxWidth: 200, scale: 2)
        #expect(fit == TrailingAccessoryFit(placement: .below, size: CGSize(width: 180, height: 62)))
    }

    @Test func aWideAccessoryBelowWidensTheBox() {
        let fit = TrailingAccessoryFit.fit(layout([30]), accessory: CGSize(width: 190, height: 14), spacing: 6, maxWidth: 200, scale: 2)
        #expect(fit == TrailingAccessoryFit(placement: .below, size: CGSize(width: 190, height: 38)))
    }

    @Test func aTallAccessoryNeverPushesTheTextDown() {
        let fit = TrailingAccessoryFit.fit(layout([50]), accessory: CGSize(width: 30, height: 30), spacing: 6, maxWidth: 200, scale: 2)
        #expect(fit == TrailingAccessoryFit(placement: .inline, size: CGSize(width: 86, height: 30)))
    }

    @Test func onlyLeftAlignedTextSharesItsLastLine() {
        for alignment in [TextLayout.Alignment.center, .right] {
            let fit = TrailingAccessoryFit.fit(layout([50], alignment: alignment), accessory: CGSize(width: 30, height: 14), spacing: 6, maxWidth: 200, scale: 2)
            #expect(fit == TrailingAccessoryFit(placement: .below, size: CGSize(width: 50, height: 38)))
        }
    }

    @Test func withoutTextTheBoxIsTheAccessory() {
        let fit = TrailingAccessoryFit.fit(layout([]), accessory: CGSize(width: 30.2, height: 14.1), spacing: 6, maxWidth: 200, scale: 2)
        #expect(fit == TrailingAccessoryFit(placement: .inline, size: CGSize(width: 30.5, height: 14.5)))
    }

    @Test func noLimitAlwaysFitsInline() {
        let fit = TrailingAccessoryFit.fit(layout([500], maxWidth: nil), accessory: CGSize(width: 40, height: 14), spacing: 6, maxWidth: nil, scale: 3)
        #expect(fit == TrailingAccessoryFit(placement: .inline, size: CGSize(width: 546, height: 24)))
    }

    @Test func sizesRoundUpToThePixelGrid() {
        let fit = TrailingAccessoryFit.fit(layout([50.1]), accessory: CGSize(width: 30, height: 14), spacing: 6, maxWidth: 200, scale: 2)
        #expect(fit.size.width == 86.5)
    }

    @Test func lastLineMaxXFollowsAlignment() {
        #expect(layout([180, 90]).lastLineMaxX(inWidth: 200) == 90)
        #expect(layout([90], alignment: .right).lastLineMaxX(inWidth: 200) == 200)
        #expect(layout([90], alignment: .center).lastLineMaxX(inWidth: 200) == 145)
        #expect(layout([]).lastLineMaxX(inWidth: 200) == 0)
    }
}

/// A bubble: padding 10, at most 200 wide, the text with the time as its
/// trailing accessory, and the time pinned to the bottom-right corner.
/// The approximate measurer gives 20-point text 10-point characters and
/// 24-point lines, and 10-point text 5-point characters and 12-point lines.
@Suite struct TrailingAccessoryLayoutTests {
    private struct Bubble {
        let root: UltraNode
        let bubble: UltraNode
        let message: UltraTextNode
        let time: UltraTextNode
    }

    private func makeBubble(_ string: String, time timeString: String = "12:41") -> Bubble {
        let time = text(timeString, fontSize: 10) {
            $0.position = .absolute
            $0.right = 10
            $0.bottom = 10
        }
        let message = text(string)
        message.trailingAccessory = time
        message.trailingAccessorySpacing = 5
        let bubble = box({ $0.padding = 10; $0.maxWidth = 200; $0.alignSelf = .flexStart }, children: [message, time])
        return Bubble(root: box(children: [bubble]), bubble: bubble, message: message, time: time)
    }

    private func frames(_ harness: Harness, _ bubble: Bubble) -> (bubble: CGRect, message: CGRect, time: CGRect, fit: TrailingAccessoryFit?) {
        harness.read {
            (bubble.bubble.shadow.frame, bubble.message.shadow.frame, bubble.time.shadow.frame, bubble.message.currentAccessoryFit)
        }
    }

    @Test func timeSitsOnTheLastLineWhenItFits() throws {
        let bubble = makeBubble("Hi")
        let harness = Harness(root: bubble.root)
        harness.pass()
        let result = frames(harness, bubble)
        // "Hi" is 20 wide; the time "12:41" is 25 x 12.
        #expect(result.fit?.placement == .inline)
        #expect(result.message == CGRect(x: 10, y: 10, width: 50, height: 24))
        #expect(result.bubble == CGRect(x: 0, y: 0, width: 70, height: 44))
        #expect(result.time == CGRect(x: 35, y: 22, width: 25, height: 12))
    }

    @Test func timeWrapsBelowAFullLastLineAndTheBubbleGrows() throws {
        // 18 characters fill the 180-point line.
        let bubble = makeBubble(String(repeating: "m", count: 18))
        let harness = Harness(root: bubble.root)
        harness.pass()
        let result = frames(harness, bubble)
        #expect(result.fit?.placement == .below)
        #expect(result.message == CGRect(x: 10, y: 10, width: 180, height: 36))
        #expect(result.bubble == CGRect(x: 0, y: 0, width: 200, height: 56))
        #expect(result.time == CGRect(x: 165, y: 34, width: 25, height: 12))
    }

    @Test func appendingSlidesTheTimeRightThenDropsIt() throws {
        let bubble = makeBubble("Hi")
        let harness = Harness(root: bubble.root)
        var times: [CGRect] = []
        for string in ["Hi", "Hi there", "Hi there friend", "Hi there friend :)"] {
            bubble.message.text = string
            harness.pass()
            times.append(frames(harness, bubble).time)
        }
        #expect(times.map(\.minX) == [35, 95, 165, 165])
        #expect(times.map(\.minY) == [22, 22, 22, 34])
    }

    @Test func aLongerAccessoryRemeasuresTheText() throws {
        let bubble = makeBubble(String(repeating: "m", count: 14))
        let harness = Harness(root: bubble.root)
        harness.pass()
        #expect(frames(harness, bubble).fit?.placement == .inline)
        // 140 + 5 + 25 fits in 180; 140 + 5 + 40 doesn't.
        bubble.time.text = "12:41 vv"
        harness.pass()
        let result = frames(harness, bubble)
        #expect(result.fit?.placement == .below)
        #expect(result.time.size == CGSize(width: 40, height: 12))
        #expect(result.bubble.height == 56)
    }

    @Test func measuringOffscreenAgreesWithTheHost() async throws {
        let bubble = makeBubble("Hello there, a message that wraps onto a second line")
        let size = await NodeMeasurement.measure(bubble.root, width: 300, environment: RenderEnvironment(scale: 2), measurer: ApproximateTextMeasurer())
        let harness = Harness(root: bubble.root, width: 300, height: size.height)
        harness.pass()
        #expect(frames(harness, bubble).bubble.maxY == size.height)
    }
}

@Suite struct TextTransitionPlanTests {
    private let far = TextTransitionPlan.outset

    /// Lines of `strings`, 24 high and 10 per character, left-aligned.
    private func lines(_ strings: [String], fingerprinted string: String? = nil) -> TextTransitionLines {
        var start = 0
        var boxes: [TextLineBox] = []
        let joined = string ?? strings.joined()
        let units = Array(joined.utf16)
        let attributed = AttributedText(string: joined, runs: [.init(range: 0..<units.count, style: TextContent.defaultStyle)], paragraph: .init(), linkCount: 0)
        for (index, line) in strings.enumerated() {
            let count = line.utf16.count
            let trimmed = line.hasSuffix(" ") ? count - 1 : count
            let range = start..<(start + count)
            boxes.append(TextLineBox(
                rect: CGRect(x: 4, y: 2 + CGFloat(index) * 24, width: CGFloat(trimmed) * 10, height: 24),
                range: range,
                fingerprint: TextTransitionLines.fingerprint(of: range, units: units, text: attributed, truncated: false)
            ))
            start += count
        }
        return TextTransitionLines(string: joined, lines: boxes, isLeftAligned: true)
    }

    @Test func unchangedTextIsStable() {
        let old = lines(["Hello ", "world"])
        let plan = TextTransitionPlan.plan(from: old, to: old)
        #expect(plan.isIdentity)
        #expect(plan.stable == [CGRect(x: -far, y: -far, width: 2 * far, height: 2 * far)])
    }

    @Test func appendingOnTheLastLineRevealsOnlyTheNewGlyphs() {
        let plan = TextTransitionPlan.plan(from: lines(["Hello"]), to: lines(["Hello world"]))
        #expect(plan.stable == [CGRect(x: -far, y: -far, width: far + 54, height: 2 * far)])
        #expect(plan.reveals == [.init(rect: CGRect(x: 54, y: -far, width: far - 54, height: 2 * far), fromOpacity: 0)])
        #expect(plan.fadeOut.isEmpty)
    }

    @Test func appendingOntoANewLineKeepsTheOldLinesStable() {
        let plan = TextTransitionPlan.plan(from: lines(["One two ", "three"]), to: lines(["One two ", "three four ", "five"]))
        // Line 0 is unchanged, line 1 grew: its old 50 points stay, the rest
        // and line 2 fade in.
        #expect(plan.stable == [
            CGRect(x: -far, y: -far, width: 2 * far, height: far + 26),
            CGRect(x: -far, y: 26, width: far + 54, height: 24),
        ])
        #expect(plan.reveals.map(\.rect) == [
            CGRect(x: 54, y: 26, width: far - 54, height: 24),
            CGRect(x: -far, y: 50, width: 2 * far, height: far - 50),
        ])
        #expect(plan.fadeOut.isEmpty)
    }

    @Test func rewrappingKeepsTheCommonPrefixAndCrossfadesTheRest() {
        let plan = TextTransitionPlan.plan(from: lines(["aaa bbb ccc"]), to: lines(["aaa bbb ", "ccc ddd"]))
        #expect(plan.stable == [CGRect(x: -far, y: -far, width: far + 74, height: far + 26)])
        #expect(plan.reveals.map(\.rect) == [CGRect(x: -far, y: 26, width: 2 * far, height: far - 26)])
        #expect(plan.fadeOut == [CGRect(x: 74, y: -far, width: far - 74, height: 2 * far)])
    }

    @Test func anEditInsideALineCrossfadesFromThatLineOn() {
        let plan = TextTransitionPlan.plan(from: lines(["aaa ", "bbb ", "ccc"]), to: lines(["aaa ", "bxb ", "ccc"]))
        #expect(plan.stable == [CGRect(x: -far, y: -far, width: 2 * far, height: far + 26)])
        #expect(plan.reveals.map(\.rect) == [CGRect(x: -far, y: 26, width: 2 * far, height: far - 26)])
        #expect(plan.fadeOut == [CGRect(x: -far, y: 26, width: 2 * far, height: far - 26)])
    }

    @Test func centeredTextCrossfadesAChangedLineWhole() {
        var old = lines(["Hello"])
        var new = lines(["Hello world"])
        old.isLeftAligned = false
        new.isLeftAligned = false
        let plan = TextTransitionPlan.plan(from: old, to: new)
        #expect(plan.stable.isEmpty)
        #expect(plan.reveals.map(\.rect) == [CGRect(x: -far, y: -far, width: 2 * far, height: 2 * far)])
        #expect(plan.fadeOut == [CGRect(x: -far, y: -far, width: 2 * far, height: 2 * far)])
    }

    @Test func regionsStillFadingInContinueFromWhereTheyAre() {
        let flight = TextTransitionPlan.Reveal(rect: CGRect(x: 54, y: -far, width: far - 54, height: 2 * far), fromOpacity: 0.4)
        let plan = TextTransitionPlan.plan(from: lines(["Hello world"]), to: lines(["Hello world again"]), inFlight: [flight])
        // "world" (54..<114) was at 0.4: it keeps fading in, not jumping to
        // opaque; "again" fades in from 0.
        #expect(plan.reveals.contains(.init(rect: CGRect(x: 114, y: -far, width: far - 114, height: 2 * far), fromOpacity: 0)))
        #expect(plan.reveals.contains(.init(rect: CGRect(x: 54, y: -far, width: 60, height: 2 * far), fromOpacity: 0.4)))
        #expect(plan.stable == [CGRect(x: -far, y: -far, width: far + 54, height: 2 * far)])
    }

    @Test func fingerprintsSeeStyleChanges() {
        let units = Array("Hello".utf16)
        let plain = AttributedText(string: "Hello", runs: [.init(range: 0..<5, style: TextContent.defaultStyle)], paragraph: .init(), linkCount: 0)
        var boldStyle = TextContent.defaultStyle
        boldStyle.fontWeight = .bold
        let bold = AttributedText(string: "Hello", runs: [.init(range: 0..<2, style: boldStyle), .init(range: 2..<5, style: TextContent.defaultStyle)], paragraph: .init(), linkCount: 0)
        #expect(TextTransitionLines.fingerprint(of: 0..<5, units: units, text: plain, truncated: false)
            != TextTransitionLines.fingerprint(of: 0..<5, units: units, text: bold, truncated: false))
        #expect(TextTransitionLines.fingerprint(of: 0..<5, units: units, text: plain, truncated: false)
            != TextTransitionLines.fingerprint(of: 0..<5, units: units, text: plain, truncated: true))
    }
}

@Suite struct LayoutTransitionPlanTests {
    private func node(_ key: String?, _ parent: Int?, _ frame: CGRect, contents: UInt64? = nil) -> TransitionNode {
        TransitionNode(key: key, parent: parent, frame: frame, contents: contents)
    }

    @Test func rootsMatchWithoutKeysAndKeysMatchAcrossTrees() {
        let old = TransitionTree(nodes: [node(nil, nil, .zero), node("a", 0, .zero), node(nil, 0, .zero), node("b", 0, .zero)])
        let new = TransitionTree(nodes: [node(nil, nil, .zero), node("b", 0, .zero), node("a", 0, .zero), node("c", 0, .zero)])
        #expect(LayoutTransitionPlan.match(old, new) == [0: 0, 1: 3, 2: 1])
    }

    /// A bubble that grows, with its time at the bottom-right corner: the
    /// time moves within the bubble, both on the same curve.
    @Test func childrenMoveInTheirParentsCoordinates() {
        let old = TransitionTree(nodes: [
            node(nil, nil, CGRect(x: 0, y: 0, width: 390, height: 60)),
            node("bubble", 0, CGRect(x: 10, y: 4, width: 100, height: 40)),
            node("time", 1, CGRect(x: 60, y: 20, width: 30, height: 12)),
        ])
        let new = TransitionTree(nodes: [
            node(nil, nil, CGRect(x: 0, y: 0, width: 390, height: 80)),
            node("bubble", 0, CGRect(x: 10, y: 4, width: 150, height: 60)),
            node("time", 1, CGRect(x: 110, y: 40, width: 30, height: 12)),
        ])
        let plan = LayoutTransitionPlan.plan(from: old, to: new)
        #expect(plan.moves.map(\.from) == [old.nodes[0].frame, old.nodes[1].frame, old.nodes[2].frame])
        #expect(plan.moves.map(\.to) == [new.nodes[0].frame, new.nodes[1].frame, new.nodes[2].frame])
        #expect(plan.entrances.isEmpty && plan.exits.isEmpty && plan.contents.isEmpty)
    }

    /// Interpolating parent and child on one progress keeps the child's
    /// distance from the parent's bottom-right corner constant when it is
    /// constant at both ends.
    @Test func insetsFromTheParentCornerStayConstantAtEveryProgress() {
        let plan = LayoutTransitionPlan.plan(
            from: TransitionTree(nodes: [node(nil, nil, .zero), node("bubble", 0, CGRect(x: 10, y: 4, width: 100, height: 40)), node("time", 1, CGRect(x: 60, y: 20, width: 30, height: 12))]),
            to: TransitionTree(nodes: [node(nil, nil, .zero), node("bubble", 0, CGRect(x: 10, y: 4, width: 150, height: 60)), node("time", 1, CGRect(x: 110, y: 40, width: 30, height: 12))])
        )
        func lerp(_ a: CGRect, _ b: CGRect, _ p: CGFloat) -> CGRect {
            CGRect(x: a.minX + (b.minX - a.minX) * p, y: a.minY + (b.minY - a.minY) * p, width: a.width + (b.width - a.width) * p, height: a.height + (b.height - a.height) * p)
        }
        for p in stride(from: CGFloat(-0.2), through: 1.2, by: 0.1) {
            let bubble = lerp(plan.moves[1].from, plan.moves[1].to, p)
            let time = lerp(plan.moves[2].from, plan.moves[2].to, p)
            #expect(abs(bubble.width - time.maxX - 10) < 1e-9)
            #expect(abs(bubble.height - time.maxY - 8) < 1e-9)
        }
    }

    @Test func aReparentedNodeStartsWhereItWasOnScreen() {
        let old = TransitionTree(nodes: [
            node(nil, nil, .zero),
            node("left", 0, CGRect(x: 0, y: 0, width: 100, height: 100)),
            node("dot", 1, CGRect(x: 10, y: 10, width: 5, height: 5)),
            node("right", 0, CGRect(x: 200, y: 50, width: 100, height: 100)),
        ])
        let new = TransitionTree(nodes: [
            node(nil, nil, .zero),
            node("left", 0, CGRect(x: 0, y: 0, width: 100, height: 100)),
            node("right", 0, CGRect(x: 220, y: 50, width: 100, height: 100)),
            node("dot", 2, CGRect(x: 30, y: 30, width: 5, height: 5)),
        ])
        let plan = LayoutTransitionPlan.plan(from: old, to: new)
        let dot = plan.moves.first { $0.node == 3 }
        // On screen at (10, 10); its new parent starts at (200, 50).
        #expect(dot?.from == CGRect(x: -190, y: -40, width: 5, height: 5))
        #expect(dot?.to == CGRect(x: 30, y: 30, width: 5, height: 5))
    }

    @Test func unmatchedKeyedNodesEnterAndLeave() {
        let old = TransitionTree(nodes: [
            node(nil, nil, .zero),
            node("bubble", 0, CGRect(x: 10, y: 10, width: 100, height: 40)),
            node("status", 1, CGRect(x: 80, y: 20, width: 10, height: 10)),
            node("check", 2, CGRect(x: 1, y: 1, width: 4, height: 4)),
            node(nil, 1, CGRect(x: 0, y: 0, width: 4, height: 4)),
        ])
        let new = TransitionTree(nodes: [
            node(nil, nil, .zero),
            node("bubble", 0, CGRect(x: 20, y: 10, width: 100, height: 40)),
            node("edited", 1, CGRect(x: 5, y: 5, width: 20, height: 10)),
        ])
        let plan = LayoutTransitionPlan.plan(from: old, to: new)
        #expect(plan.entrances == [2])
        // The status leaves inside the bubble's view, where it was in the
        // bubble; its keyed child goes with it, and the unkeyed node is
        // nobody's to animate.
        #expect(plan.exits == [.init(node: 2, container: 1, frame: CGRect(x: 80, y: 20, width: 10, height: 10), opacity: 1)])
    }

    @Test func changedBitmapsCrossfadeAndChangedTextPlansItsLines() {
        let oldText = TextTransitionLines(string: "Hi", lines: [TextLineBox(rect: CGRect(x: 0, y: 0, width: 20, height: 24), range: 0..<2, fingerprint: 1)], isLeftAligned: true)
        let newText = TextTransitionLines(string: "Hi you", lines: [TextLineBox(rect: CGRect(x: 0, y: 0, width: 60, height: 24), range: 0..<6, fingerprint: 2)], isLeftAligned: true)
        let old = TransitionTree(nodes: [
            node(nil, nil, .zero),
            node("background", 0, .zero, contents: 1),
            TransitionNode(key: "text", parent: 0, frame: .zero, contents: 2, text: oldText),
            node("same", 0, .zero, contents: 3),
        ])
        let new = TransitionTree(nodes: [
            node(nil, nil, .zero),
            node("background", 0, .zero, contents: 4),
            TransitionNode(key: "text", parent: 0, frame: .zero, contents: 5, text: newText),
            node("same", 0, .zero, contents: 3),
        ])
        let plan = LayoutTransitionPlan.plan(from: old, to: new)
        #expect(plan.contents.count == 2)
        #expect(plan.contents.first == .crossfade(old: 1, new: 1))
        guard case .text(2, 2, let text)? = plan.contents.last else {
            Issue.record("expected a text plan, got \(plan.contents)")
            return
        }
        #expect(text.fadeOut.isEmpty)
        #expect(text.reveals.count == 1)
    }

    /// A new row grows out of frames given in host coordinates, like the
    /// composer's field.
    @Test func framesInHostCoordinatesMoveIntoTheirParents() {
        let from = TransitionTree(nodes: [
            node("bubble", nil, CGRect(x: 12, y: 300, width: 280, height: 44)),
            node("text", nil, CGRect(x: 21, y: 308, width: 260, height: 22)),
        ], root: nil)
        let new = TransitionTree(nodes: [
            node(nil, nil, CGRect(x: 0, y: 0, width: 390, height: 50)),
            node("bubble", 0, CGRect(x: 250, y: 4, width: 130, height: 40)),
            node("text", 1, CGRect(x: 12, y: 8, width: 80, height: 22)),
            node("time", 1, CGRect(x: 90, y: 24, width: 30, height: 12)),
        ])
        let plan = LayoutTransitionPlan.plan(from: from, to: new)
        #expect(plan.moves.map(\.node) == [1, 2])
        #expect(plan.moves[0].from == CGRect(x: 12, y: 300, width: 280, height: 44))
        #expect(plan.moves[1].from == CGRect(x: 9, y: 8, width: 260, height: 22))
        #expect(plan.entrances == [3])
    }
}

@Suite struct TransitionValueTests {
    @Test func keyPathsMoveAlongOneAxisOrNone() {
        #expect(TransitionAxis(keyPath: "position.x") == .horizontal)
        #expect(TransitionAxis(keyPath: "bounds.size.width") == .horizontal)
        #expect(TransitionAxis(keyPath: "position.y") == .vertical)
        #expect(TransitionAxis(keyPath: "bounds.size.height") == .vertical)
        for keyPath in ["opacity", "cornerRadius", "backgroundColor", "transform", "bounds"] {
            #expect(TransitionAxis(keyPath: keyPath) == nil)
        }
    }

    @Test func aShiftedAnimationKeepsItsMotionAndEndsAtTheNewTarget() {
        // A height running 100 -> 160 whose destination becomes 200 at once.
        let start = TransitionShift.start(from: 100, to: 160, target: 200)
        #expect(start == 140)
        // At every progress the shifted value is the old one plus 40.
        for progress in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let old = 100 + (160 - 100) * progress, shifted = start + (200 - start) * progress
            #expect(shifted - old == 40)
        }
        #expect(TransitionShift.start(from: 80, to: 20, target: 20) == 80)
    }

    @Test func appearanceKeepsItsAnchorFixed() {
        let appearance = NodeAppearance(key: "bubble", scale: 0.8, anchor: CGPoint(x: 0, y: 1))
        let translation = appearance.translation(for: CGSize(width: 100, height: 50))
        #expect(abs(translation.x + 10) < 1e-9 && abs(translation.y - 5) < 1e-9)
        // The anchor (0, 50), relative to the center (-50, 25), maps to itself.
        let mapped = CGPoint(x: -50 * 0.8 + translation.x, y: 25 * 0.8 + translation.y)
        #expect(abs(mapped.x + 50) < 1e-9 && abs(mapped.y - 25) < 1e-9)
    }

    @Test func drawnBoxesStretchBetweenTheirCorners() {
        var style = Style()
        style.backgroundColor = .blue
        style.borderTopLeftRadius = 18
        style.borderTopRightRadius = 18
        style.borderBottomLeftRadius = 6
        style.borderBottomRightRadius = 18
        let box = BoxStyle(style: style, borderWidths: .zero, size: CGSize(width: 100, height: 36), isDark: false, isRightToLeft: false)
        let placement = ContentsPlacement.stretching(box, size: CGSize(width: 100, height: 36), scale: 2)
        #expect(placement == .stretch(Insets(top: 17.75, left: 18, bottom: 17.75, right: 18)))
    }

    @Test func textBitmapsSitAtTheTopAndBoxesStretch() throws {
        let label = text("Hi")
        let card = box {
            $0.width = 100
            $0.height = 40
            $0.backgroundColor = .white
            $0.borderTopLeftRadius = 4
            $0.borderTopRightRadius = 8
        }
        let centered = UltraTextNode("Hi", textStyle: TextStyle(fontSize: 20, textAlign: .center))
        centered.style.width = 100
        label.transitionKey = "label"
        let harness = Harness(root: box({ $0.alignItems = .flexStart }, children: [label, card, centered]))
        let commit = try #require(harness.pass())
        #expect(commit.entry(for: label)?.contents?.contents?.placement == .top(.left))
        #expect(commit.entry(for: centered)?.contents?.contents?.placement == .top(.center))
        #expect(commit.entry(for: card)?.contents?.contents?.placement == .stretch(Insets(all: 8)))
        #expect(commit.entry(for: label)?.props?.transitionKey == "label")
        let lines = try #require(commit.entry(for: label)?.props?.text?.lines)
        #expect(lines.string == "Hi")
        #expect(lines.isLeftAligned)
        #expect(lines.lines.map(\.rect) == [CGRect(x: 0, y: 0, width: 20, height: 24)])
    }
}
