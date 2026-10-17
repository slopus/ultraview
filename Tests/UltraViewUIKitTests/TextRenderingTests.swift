#if canImport(UIKit)
import Testing
import UIKit
@testable import UltraCore
import UltraView

@MainActor
@Suite struct TextMeasurementTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var text: String
        var fontSize: CGFloat
        var weight: FontWeight = .regular
        var width: CGFloat
        var lines = 0
        var testDescription: String { "\(text.prefix(16)) @\(fontSize) w\(width) n\(lines)" }
    }

    nonisolated static let cases: [Case] = [
        Case(text: "Hello", fontSize: 17, width: 300),
        Case(text: "Hello, world", fontSize: 12, weight: .bold, width: 300),
        Case(text: "The quick brown fox jumps over the lazy dog", fontSize: 17, width: 200),
        Case(text: "The quick brown fox jumps over the lazy dog", fontSize: 15, weight: .semibold, width: 120),
        Case(text: String(repeating: "Wrapping text measured off the main thread. ", count: 6), fontSize: 14, width: 280),
        Case(text: String(repeating: "Wrapping text measured off the main thread. ", count: 6), fontSize: 14, width: 280, lines: 2),
        Case(text: "Large title", fontSize: 34, weight: .bold, width: 390),
        Case(text: "Ünïcödé — émoji 👋🏽 and CJK 漢字かな", fontSize: 16, width: 180),
        Case(text: "Line one\nLine two\nLine three", fontSize: 17, width: 300),
    ]

    @Test(arguments: cases)
    func measuresWithinAPointOfALabel(_ test: Case) async throws {
        let node = UltraTextNode(
            test.text,
            textStyle: TextStyle(fontSize: test.fontSize, fontWeight: test.weight),
            numberOfLines: test.lines
        )
        let root = UltraNode(style: styled { $0.alignItems = .flexStart }, children: [node])
        let hosted = Hosted(root, size: CGSize(width: test.width, height: 2000))
        await hosted.settle()

        let label = UILabel()
        label.text = test.text
        label.font = .systemFont(ofSize: test.fontSize, weight: test.weight.uiFontWeight)
        label.numberOfLines = test.lines
        let expected = label.sizeThatFits(CGSize(width: test.width, height: .greatestFiniteMagnitude))
        let measured = try #require(node.view?.bounds.size)

        #expect(abs(measured.width - min(expected.width, test.width)) <= 1, "width \(measured.width) vs label \(expected.width)")
        #expect(abs(measured.height - expected.height) <= 1, "height \(measured.height) vs label \(expected.height)")
    }
}

@MainActor
@Suite struct TruncationTests {
    /// Capital Ms ink the upper half of a line everywhere; an ellipsis only
    /// inks the bottom. A band with ink below and none above is an ellipsis.
    private func render(_ mode: EllipsizeMode) async throws -> (Pixels, Hosted) {
        let node = UltraTextNode(
            String(repeating: "M", count: 40),
            style: styled { $0.width = 200 },
            textStyle: TextStyle(fontSize: 20),
            numberOfLines: 1,
            ellipsizeMode: mode
        )
        let hosted = Hosted(UltraNode(style: styled { $0.alignItems = .flexStart }, children: [node]))
        await hosted.settle()
        return (try #require(Pixels(node)), hosted)
    }

    private func upperInk(_ pixels: Pixels, from x: CGFloat, width: CGFloat = 6) -> Int {
        pixels.ink(in: CGRect(x: x, y: 6, width: width, height: 6))
    }

    private func lowerInk(_ pixels: Pixels, from x: CGFloat, width: CGFloat = 6) -> Int {
        pixels.ink(in: CGRect(x: x, y: 14, width: width, height: 6))
    }

    /// The x of each ellipsis-like band in the line.
    private func ellipsisBands(_ pixels: Pixels, in range: ClosedRange<CGFloat>) -> [CGFloat] {
        stride(from: range.lowerBound, through: range.upperBound - 6, by: 1).filter { x in
            upperInk(pixels, from: x) == 0 && lowerInk(pixels, from: x) > 0
        }
    }

    @Test func tailEndsWithAnEllipsis() async throws {
        let (pixels, _) = try await render(.tail)
        let ink = try #require(pixels.inkedColumns)
        #expect(upperInk(pixels, from: ink.upperBound - 6) == 0)
        #expect(lowerInk(pixels, from: ink.upperBound - 6) > 0)
        #expect(upperInk(pixels, from: ink.lowerBound) > 0)
        #expect(ellipsisBands(pixels, in: ink.lowerBound...(ink.upperBound - 20)).isEmpty)
    }

    @Test func headStartsWithAnEllipsis() async throws {
        let (pixels, _) = try await render(.head)
        let ink = try #require(pixels.inkedColumns)
        #expect(upperInk(pixels, from: ink.lowerBound) == 0)
        #expect(lowerInk(pixels, from: ink.lowerBound) > 0)
        #expect(upperInk(pixels, from: ink.upperBound - 6) > 0)
        #expect(ellipsisBands(pixels, in: (ink.lowerBound + 20)...ink.upperBound).isEmpty)
    }

    @Test func middleHasAnEllipsisInTheMiddle() async throws {
        let (pixels, _) = try await render(.middle)
        let ink = try #require(pixels.inkedColumns)
        #expect(upperInk(pixels, from: ink.lowerBound) > 0)
        #expect(upperInk(pixels, from: ink.upperBound - 6) > 0)
        let middle = (ink.lowerBound + ink.upperBound) / 2
        #expect(!ellipsisBands(pixels, in: (middle - 30)...(middle + 30)).isEmpty)
    }

    @Test func clipCutsAtTheEdgeWithoutAnEllipsis() async throws {
        let (pixels, _) = try await render(.clip)
        let ink = try #require(pixels.inkedColumns)
        #expect(ink.upperBound >= 198)
        #expect(ellipsisBands(pixels, in: ink.lowerBound...ink.upperBound).isEmpty)
    }

    @Test func untruncatedTextHasNoEllipsis() async throws {
        let node = UltraTextNode("MMMM", textStyle: TextStyle(fontSize: 20), numberOfLines: 1)
        let hosted = Hosted(UltraNode(style: styled { $0.alignItems = .flexStart }, children: [node]))
        await hosted.settle()
        let pixels = try #require(Pixels(node))
        let ink = try #require(pixels.inkedColumns)
        #expect(ellipsisBands(pixels, in: ink).isEmpty)
    }

    @Test func numberOfLinesLimitsHeight() async throws {
        let text = String(repeating: "Several lines of text in a narrow box. ", count: 8)
        let full = UltraTextNode(text, textStyle: TextStyle(fontSize: 16))
        let limited = UltraTextNode(text, textStyle: TextStyle(fontSize: 16), numberOfLines: 2)
        let hosted = Hosted(UltraNode(style: styled { $0.alignItems = .flexStart }, children: [full, limited]), size: CGSize(width: 200, height: 2000))
        await hosted.settle()
        let line = UIFont.systemFont(ofSize: 16).lineHeight
        #expect(abs((limited.view?.bounds.height ?? 0) - 2 * line) <= 1)
        #expect((full.view?.bounds.height ?? 0) > 4 * line)
    }
}

@MainActor
@Suite struct SpanAttributeTests {
    @Test func nestedSpansKeepTheirColors() async throws {
        let node = UltraTextNode(spans: [
            TextSpan("██████", style: TextStyle(color: .red)),
            TextSpan("██████", style: TextStyle(color: .blue)),
        ], textStyle: TextStyle(fontSize: 20, fontFamily: "Menlo"))
        let hosted = Hosted(UltraNode(style: styled { $0.alignItems = .flexStart }, children: [node]))
        await hosted.settle()
        let pixels = try #require(Pixels(node))
        let size = node.view!.bounds.size
        let left = try #require(pixels.averageInkColor(in: CGRect(x: 0, y: 0, width: size.width * 0.4, height: size.height)))
        let right = try #require(pixels.averageInkColor(in: CGRect(x: size.width * 0.6, y: 0, width: size.width * 0.4, height: size.height)))
        #expect(left.r > 0.8 && left.b < 0.4)
        #expect(right.b > 0.8 && right.r < 0.3)
    }

    @Test func childrenInheritAndOverride() async throws {
        // The inner span inherits red from its parent and adds a size.
        let node = UltraTextNode(spans: [
            TextSpan("██", style: TextStyle(color: .green), children: [
                TextSpan("██", style: TextStyle(color: .red, fontSize: 40), children: [
                    TextSpan("██", style: TextStyle(fontWeight: .bold)),
                ]),
            ]),
        ], textStyle: TextStyle(fontSize: 12, fontFamily: "Menlo"))
        let plain = UltraTextNode("██", textStyle: TextStyle(fontSize: 12, fontFamily: "Menlo"))
        let hosted = Hosted(UltraNode(style: styled { $0.alignItems = .flexStart }, children: [node, plain]))
        await hosted.settle()
        let size = node.view!.bounds.size
        #expect(size.height > 2.5 * plain.view!.bounds.height)

        let pixels = try #require(Pixels(node))
        let tail = try #require(pixels.averageInkColor(in: CGRect(x: size.width * 0.8, y: 0, width: size.width * 0.2, height: size.height)))
        #expect(tail.r > 0.8 && tail.g < 0.4)
        let head = try #require(pixels.averageInkColor(in: CGRect(x: 0, y: 0, width: 10, height: size.height)))
        #expect(head.g > 0.6 && head.r < 0.4)
    }

    @Test func spanBackgroundCoversOnlyItsCharacters() async throws {
        let node = UltraTextNode(spans: [
            TextSpan("....."),
            TextSpan(".....", style: TextStyle(backgroundColor: .yellow)),
        ], textStyle: TextStyle(fontSize: 20, fontFamily: "Menlo"))
        let hosted = Hosted(UltraNode(style: styled { $0.alignItems = .flexStart }, children: [node]))
        await hosted.settle()
        let pixels = try #require(Pixels(node))
        let size = node.view!.bounds.size
        // Above the dots, only the highlighted half has paint.
        #expect(pixels.ink(in: CGRect(x: 2, y: 4, width: size.width / 2 - 4, height: 6)) == 0)
        let highlight = try #require(pixels.averageInkColor(in: CGRect(x: size.width / 2 + 2, y: 4, width: size.width / 2 - 4, height: 6)))
        #expect(highlight.r > 0.9 && highlight.g > 0.7 && highlight.b < 0.3)
    }

    @Test func underlineDrawsALineUnderTheSpan() async throws {
        let node = UltraTextNode(spans: [
            TextSpan("xxxxx"),
            TextSpan("xxxxx", style: TextStyle(textDecorationLine: .underline)),
        ], textStyle: TextStyle(fontSize: 20, fontFamily: "Menlo"))
        let hosted = Hosted(UltraNode(style: styled { $0.alignItems = .flexStart }, children: [node]))
        await hosted.settle()
        let pixels = try #require(Pixels(node))
        let size = node.view!.bounds.size
        let baseline = try #require(node.currentTextLayout?.lines.first?.baseline)
        // An x has nothing below the baseline: only the underline does.
        let below = baseline + 1
        #expect(pixels.ink(in: CGRect(x: 0, y: below, width: size.width / 2 - 2, height: size.height - below)) == 0)
        #expect(pixels.ink(in: CGRect(x: size.width / 2 + 2, y: below, width: size.width / 2 - 4, height: size.height - below)) > 0)
    }

    @Test func paddingInsetsTheDrawnText() async throws {
        let node = UltraTextNode(
            "MMMM",
            style: styled { $0.padding = 12 },
            textStyle: TextStyle(fontSize: 20)
        )
        let hosted = Hosted(UltraNode(style: styled { $0.alignItems = .flexStart }, children: [node]))
        await hosted.settle()
        let pixels = try #require(Pixels(node))
        let size = try #require(node.view?.bounds.size)
        #expect(pixels.ink(in: CGRect(x: 0, y: 0, width: size.width, height: 11)) == 0)
        #expect(pixels.ink(in: CGRect(x: 0, y: 0, width: 11, height: size.height)) == 0)
        #expect(pixels.ink(in: CGRect(x: 12, y: 12, width: size.width - 24, height: size.height - 24)) > 0)
    }

    @Test func textTransformAndAccessibilityLabel() async throws {
        let node = UltraTextNode(spans: [
            TextSpan("make ", style: TextStyle(textTransform: .uppercase)),
            TextSpan("it so"),
        ])
        let hosted = Hosted(UltraNode(children: [node]))
        await hosted.settle()
        #expect(node.view?.accessibilityLabel == "MAKE it so")
        #expect(node.view?.accessibilityTraits.contains(.staticText) == true)
    }
}
#endif
