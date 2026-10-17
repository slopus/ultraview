import Foundation
import Testing
@testable import UltraCore
import UltraLayout

@Suite struct TextFlatteningTests {
    private func flatten(_ spans: [TextSpan], style: TextStyle = TextStyle(), fontScale: CGFloat = 1, isDark: Bool = false, configure: (inout TextContent) -> Void = { _ in }) -> AttributedText {
        var content = TextContent()
        content.spans = spans
        content.style = style
        configure(&content)
        return content.attributedText(fontScale: fontScale, isDark: isDark)
    }

    @Test func nestedSpansInheritAndOverride() {
        let text = flatten([
            TextSpan("Hello ", children: [
                TextSpan("bold ", style: TextStyle(fontWeight: .bold), children: [
                    TextSpan("blue", style: TextStyle(color: .blue, fontStyle: .italic)),
                ]),
            ]),
            TextSpan("!"),
        ], style: TextStyle(color: .red, fontSize: 16))

        #expect(text.string == "Hello bold blue!")
        #expect(text.runs.map(\.range) == [0..<6, 6..<11, 11..<15, 15..<16])
        let styles = text.runs.map(\.style)
        #expect(styles.map(\.fontSize) == [16, 16, 16, 16])
        #expect(styles.map(\.fontWeight) == [.regular, .bold, .bold, .regular])
        #expect(styles.map(\.isItalic) == [false, false, true, false])
        #expect(styles.map(\.color) == [Color.red.light, Color.red.light, Color.blue.light, Color.red.light])
    }

    @Test func defaultsApplyWhereNothingIsSet() {
        let style = flatten([TextSpan("x")]).runs[0].style
        #expect(style == TextContent.defaultStyle)
        #expect(style.fontSize == 14)
        #expect(style.color == Color.black.light)
    }

    @Test func everyAttributeResolves() {
        let style = flatten([TextSpan("x", style: TextStyle(
            fontFamily: "Menlo",
            letterSpacing: 1.5,
            textDecorationLine: .underlineLineThrough,
            textDecorationColor: .green,
            textDecorationStyle: .dashed,
            backgroundColor: .yellow
        ))]).runs[0].style

        #expect(style.fontFamily == "Menlo")
        #expect(style.letterSpacing == 1.5)
        #expect(style.decorationLine == .underlineLineThrough)
        #expect(style.decorationColor == Color.green.light)
        #expect(style.decorationStyle == .dashed)
        #expect(style.backgroundColor == Color.yellow.light)
    }

    @Test func adjacentRunsWithTheSameStyleMerge() {
        let text = flatten([TextSpan("a"), TextSpan("b"), TextSpan("c", style: TextStyle(fontSize: 30))])
        #expect(text.runs.map(\.range) == [0..<2, 2..<3])
    }

    @Test func transformsApplyPerSpanAndRangesFollowTheResult() {
        let text = flatten([
            TextSpan("straße ", style: TextStyle(fontSize: 10, textTransform: .uppercase)),
            TextSpan("MIXED case", style: TextStyle(fontSize: 11, textTransform: .lowercase)),
            TextSpan(" hello world", style: TextStyle(fontSize: 12, textTransform: .capitalize)),
        ])
        #expect(text.string == "STRASSE mixed case Hello World")
        #expect(text.runs.map(\.range) == [0..<8, 8..<18, 18..<30])
    }

    @Test func pressableSpansGetIndicesAndPassThemToChildren() {
        let text = flatten([
            TextSpan("a"),
            TextSpan("link", onPress: {}, children: [TextSpan(" inner", style: TextStyle(fontWeight: .bold))]),
            TextSpan("b"),
            TextSpan("second", onLongPress: {}),
        ])
        #expect(text.linkCount == 2)
        #expect(text.runs.map(\.link) == [nil, 0, 0, nil, 1])

        var content = TextContent()
        content.spans = [TextSpan("x", onPress: {}), TextSpan("y", children: [TextSpan("z", onPress: {})])]
        #expect(content.links.map(\.text) == ["x", "z"])
    }

    @Test func fontScalingFollowsTheSystemWithinLimits() {
        let spans = [TextSpan("x", style: TextStyle(fontSize: 10, lineHeight: 20))]
        let scaled = flatten(spans, fontScale: 2)
        #expect(scaled.runs[0].style.fontSize == 20)
        #expect(scaled.paragraph.lineHeight == 40)

        let capped = flatten(spans, fontScale: 2) { $0.maxFontSizeMultiplier = 1.5 }
        #expect(capped.runs[0].style.fontSize == 15)

        let uncapped = flatten(spans, fontScale: 2) { $0.maxFontSizeMultiplier = 0 }
        #expect(uncapped.runs[0].style.fontSize == 20)

        let fixed = flatten(spans, fontScale: 2) { $0.allowFontScaling = false }
        #expect(fixed.runs[0].style.fontSize == 10)
    }

    @Test func theTallestLineHeightWins() {
        let text = flatten([TextSpan("a", style: TextStyle(lineHeight: 30)), TextSpan("b")], style: TextStyle(lineHeight: 20))
        #expect(text.paragraph.lineHeight == 30)
    }

    @Test func paragraphSettingsComeFromTheOuterStyle() {
        let text = flatten([TextSpan("x", style: TextStyle(textAlign: .right))], style: TextStyle(textAlign: .center)) {
            $0.numberOfLines = 2
            $0.ellipsizeMode = .middle
        }
        #expect(text.paragraph.alignment == .center)
        #expect(text.paragraph.numberOfLines == 2)
        #expect(text.paragraph.ellipsizeMode == .middle)
    }

    @Test func darkAppearanceResolvesTextColors() {
        let color = Color.dynamic(light: .black, dark: .white)
        #expect(flatten([TextSpan("x")], style: TextStyle(color: color), isDark: true).runs[0].style.color == Color.white.light)
    }

    @Test func runLookupByOffset() {
        let text = flatten([TextSpan("ab"), TextSpan("cd", style: TextStyle(fontSize: 30)), TextSpan("e", style: TextStyle(fontSize: 40))])
        #expect(text.run(at: 0)?.style.fontSize == 14)
        #expect(text.run(at: 3)?.style.fontSize == 30)
        #expect(text.run(at: 4)?.style.fontSize == 40)
        #expect(text.run(at: 5) == nil)
        #expect(text.run(at: -1) == nil)
    }
}

@Suite struct TextLayoutReuseTests {
    private let measurer = ApproximateTextMeasurer(characterWidth: 0.5)

    private func layout(_ string: String, maxWidth: CGFloat?, lines: Int = 0) -> TextLayout {
        var content = TextContent()
        content.spans = [TextSpan(string)]
        content.style = TextStyle(fontSize: 20)
        content.numberOfLines = lines
        return measurer.layout(content.attributedText(fontScale: 1, isDark: false), maxWidth: maxWidth, scale: 2)
    }

    @Test func aLayoutFitsAnyWidthBetweenItsTextAndItsLimit() {
        let wrapped = layout("aaaa bbbb cccc", maxWidth: 100)
        #expect(wrapped.size.width == 90)
        #expect(wrapped.lines.count == 2)
        #expect(wrapped.fits(width: 100))
        #expect(wrapped.fits(width: 90))
        #expect(!wrapped.fits(width: 80))
        #expect(!wrapped.fits(width: 120))
        #expect(!wrapped.fits(width: nil))

        let single = layout("short", maxWidth: 300)
        #expect(single.fits(width: 50))
        #expect(single.fits(width: nil))
        #expect(!single.fits(width: 40))
    }

    @Test func truncatedLayoutsOnlyFitTheirOwnWidth() {
        let cut = layout("aaaa bbbb cccc", maxWidth: 100, lines: 1)
        #expect(cut.isTruncated)
        #expect(cut.fits(width: 100))
        #expect(!cut.fits(width: 95))
    }

    @Test func alignmentPlacesLinesInTheFinalWidth() {
        var content = TextContent()
        content.spans = [TextSpan("ab")]
        content.style = TextStyle(fontSize: 20, textAlign: .center)
        let centered = measurer.layout(content.attributedText(fontScale: 1, isDark: false), maxWidth: 100, scale: 2)
        #expect(centered.originX(ofLine: 0, inWidth: 100) == 40)
        #expect(centered.originX(ofLine: 0, inWidth: 60) == 20)
    }

    @Test func linkRegionsFollowAlignment() {
        var content = TextContent()
        content.spans = [TextSpan("ab"), TextSpan("cd", onPress: {})]
        content.style = TextStyle(fontSize: 20, textAlign: .right)
        let layout = measurer.layout(content.attributedText(fontScale: 1, isDark: false), maxWidth: 100, scale: 2)
        #expect(layout.linkRegions(inWidth: 100) == [TextLinkRegion(index: 0, rects: [CGRect(x: 80, y: 0, width: 20, height: 24)])])
    }
}

@Suite struct TextNodeTests {
    @Test func textIsMeasuredOnceAndDrawnFromTheSameLayout() throws {
        let label = text("Hello world")
        let harness = Harness(root: box({ $0.alignItems = .flexStart }, children: [label]))

        let commit = try #require(harness.pass())

        #expect(commit.entry(for: label)?.frame == CGRect(x: 0, y: 0, width: 110, height: 24))
        #expect(harness.measurer.count == 1)
        let layoutID = harness.read { label.currentTextLayout?.id }
        let draws = harness.rasterizer.draws.withLock { $0 }
        #expect(draws.count == 1)
        #expect(draws.first?.layoutID == layoutID)
        #expect(draws.first?.size == CGSize(width: 110, height: 24))
        #expect(commit.entry(for: label)?.contents?.contents != nil)
        #expect(commit.entry(for: label)?.props?.accessibility.label == "Hello world")
    }

    @Test func textWrapsToTheAvailableWidth() throws {
        let label = text("aaaa bbbb cccc")
        let harness = Harness(root: box(children: [label]), width: 100)

        let commit = try #require(harness.pass())

        #expect(commit.entry(for: label)?.frame == CGRect(x: 0, y: 0, width: 100, height: 48))
        #expect(harness.measurer.count == 1, "the stretched width is the measured width")
    }

    @Test func styleChangesDontRemeasureOrRedraw() throws {
        let label = text("Hello")
        let harness = Harness(root: box({ $0.alignItems = .flexStart }, children: [label]))
        harness.pass()

        label.updateStyle { $0.opacity = 0.5 }
        let commit = try #require(harness.pass())

        #expect(commit.entry(for: label)?.props?.opacity == 0.5)
        #expect(commit.entry(for: label)?.contents == nil)
        #expect(harness.measurer.count == 1)
        #expect(harness.rasterizer.count == 1)
    }

    @Test func textChangesRemeasureRelayoutAndRedraw() throws {
        let label = text("Hi")
        let after = box { $0.height = 10 }
        let harness = Harness(root: box({ $0.alignItems = .flexStart }, children: [label, after]))
        harness.pass()

        label.text = "Hello"
        let commit = try #require(harness.pass())

        #expect(commit.entry(for: label)?.frame == CGRect(x: 0, y: 0, width: 50, height: 24))
        #expect(commit.entry(for: label)?.contents?.contents != nil)
        #expect(harness.measurer.count == 2)
        #expect(harness.rasterizer.drawnTexts == ["Hi", "Hello"])
        #expect(commit.entry(for: after) == nil, "its frame didn't change")
    }

    @Test func aWidthChangeRelaysOutText() throws {
        let label = text("aaaa bbbb cccc")
        let harness = Harness(root: box(children: [label]), width: 200)
        harness.pass()
        #expect(harness.read { label.shadow.frame.height } == 24)

        harness.update { $0.width = 100 }
        let commit = try #require(harness.pass())

        #expect(commit.entry(for: label)?.frame?.height == 48)
        #expect(harness.measurer.count == 2)
        #expect(harness.rasterizer.count == 2)
    }

    @Test func numberOfLinesLimitsTheHeight() throws {
        let label = text("aaaa bbbb cccc dddd eeee")
        label.numberOfLines = 2
        let harness = Harness(root: box(children: [label]), width: 100)

        let commit = try #require(harness.pass())

        #expect(commit.entry(for: label)?.frame?.height == 48)
        #expect(harness.read { label.currentTextLayout?.isTruncated } == true)
    }

    @Test func fontScaleRemeasures() throws {
        let label = text("Hi")
        let harness = Harness(root: box({ $0.alignItems = .flexStart }, children: [label]))
        harness.pass()

        harness.update { $0.environment.fontScale = 1.5 }
        let commit = try #require(harness.pass())

        #expect(commit.entry(for: label)?.frame?.size == CGSize(width: 30, height: 36))
    }

    @Test func spansWithHandlersBecomeLinkRegions() throws {
        let label = UltraTextNode(spans: [TextSpan("ab"), TextSpan("cd", onPress: {})], textStyle: TextStyle(fontSize: 20))
        let harness = Harness(root: box({ $0.alignItems = .flexStart }, children: [label]))

        let commit = try #require(harness.pass())
        let textProps = try #require(commit.entry(for: label)?.props?.text)

        #expect(textProps.links == [TextLinkRegion(index: 0, rects: [CGRect(x: 20, y: 0, width: 20, height: 24)])])
        #expect(textProps.highlightsPress)
        #expect(label.link(at: 0, version: textProps.version)?.text == "cd")
        label.text = "changed"
        #expect(label.link(at: 0, version: textProps.version) == nil, "an old tap target is ignored")
    }

    @Test func emptyTextHasNoSizeAndNoBitmap() throws {
        let label = text("")
        let harness = Harness(root: box({ $0.alignItems = .flexStart }, children: [label]))

        let commit = try #require(harness.pass())

        #expect(commit.entry(for: label)?.frame?.size == .zero)
        #expect(harness.rasterizer.count == 0)
    }

    @Test func textHasPaddingAndBackgroundLikeAnyNode() throws {
        let label = text("Hi") {
            $0.padding = 5
            $0.backgroundColor = .yellow
        }
        let harness = Harness(root: box({ $0.alignItems = .flexStart }, children: [label]))

        let commit = try #require(harness.pass())

        #expect(commit.entry(for: label)?.frame?.size == CGSize(width: 30, height: 34))
        #expect(commit.entry(for: label)?.props?.backgroundColor == Color.yellow.light)
    }
}
