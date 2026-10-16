import Foundation
import Testing
import UltraLayout

private func box(width: CGFloat, height: CGFloat) -> LayoutNode {
    var style = LayoutStyle()
    style.width = .points(width)
    style.height = .points(height)
    return LayoutNode(style: style)
}

private func row(_ configure: (inout LayoutStyle) -> Void = { _ in }, children: [LayoutNode]) -> LayoutNode {
    var style = LayoutStyle()
    style.flexDirection = .row
    configure(&style)
    return LayoutNode(style: style, children: children)
}

@Suite struct LayoutNodeTests {
    @Test func rowWithPaddingAndGap() {
        let root = row({
            $0.padding = LayoutInsets(all: 10)
            $0.gap = 5
            $0.alignItems = .flexStart
        }, children: [box(width: 40, height: 20), box(width: 60, height: 30), box(width: 20, height: 10)])

        root.calculateLayout(width: 300, height: 100)

        #expect(root.frame == CGRect(x: 0, y: 0, width: 300, height: 100))
        #expect(root.children.map(\.frame) == [
            CGRect(x: 10, y: 10, width: 40, height: 20),
            CGRect(x: 55, y: 10, width: 60, height: 30),
            CGRect(x: 120, y: 10, width: 20, height: 10),
        ])
    }

    @Test func flexGrowSharesFreeSpace() {
        var fixed = LayoutStyle()
        fixed.width = .points(100)
        var grow1 = LayoutStyle()
        grow1.flexGrow = 1
        var grow3 = LayoutStyle()
        grow3.flexGrow = 3
        let root = row(children: [LayoutNode(style: fixed), LayoutNode(style: grow1), LayoutNode(style: grow3)])

        root.calculateLayout(width: 500, height: 50)

        #expect(root.children.map(\.frame) == [
            CGRect(x: 0, y: 0, width: 100, height: 50),
            CGRect(x: 100, y: 0, width: 100, height: 50),
            CGRect(x: 200, y: 0, width: 300, height: 50),
        ])
    }

    @Test func columnIsTheDefaultAndStretchesWidth() {
        var child = LayoutStyle()
        child.height = .points(30)
        var margin = LayoutStyle()
        margin.height = .percent(50)
        margin.margin = LayoutInsets(top: 4, left: 8, bottom: 0, right: 12)
        let root = LayoutNode(children: [LayoutNode(style: child), LayoutNode(style: margin)])

        root.calculateLayout(width: 200, height: 100)

        #expect(root.children.map(\.frame) == [
            CGRect(x: 0, y: 0, width: 200, height: 30),
            CGRect(x: 8, y: 34, width: 180, height: 50),
        ])
    }

    @Test func unboundedAxisWrapsContent() {
        let root = row(children: [box(width: 40, height: 20), box(width: 60, height: 30)])

        root.calculateLayout()

        #expect(root.frame == CGRect(x: 0, y: 0, width: 100, height: 30))
    }

    @Test func styleChangesAfterLayoutAreRecomputed() {
        let child = box(width: 40, height: 20)
        let root = row(children: [child])
        root.calculateLayout(width: 100, height: 100)
        #expect(child.frame.origin == .zero)

        root.style.justifyContent = .flexEnd
        root.calculateLayout(width: 100, height: 100)

        #expect(child.frame.origin == CGPoint(x: 60, y: 0))
    }

    @Test func rightToLeftMirrorsRows() {
        let root = row({ $0.alignItems = .flexStart }, children: [box(width: 40, height: 20), box(width: 60, height: 20)])

        root.calculateLayout(width: 200, height: 20, direction: .rightToLeft)

        #expect(root.children.map(\.frame.minX) == [160, 100])
    }

    @Test func resultSnapshotsTheTree() {
        let root = row({ $0.alignItems = .flexStart }, children: [box(width: 40, height: 20), row(children: [box(width: 10, height: 10)])])

        root.calculateLayout(width: 100, height: 50)

        #expect(root.result == LayoutResult(
            frame: CGRect(x: 0, y: 0, width: 100, height: 50),
            children: [
                LayoutResult(frame: CGRect(x: 0, y: 0, width: 40, height: 20)),
                LayoutResult(
                    frame: CGRect(x: 40, y: 0, width: 10, height: 10),
                    children: [LayoutResult(frame: CGRect(x: 0, y: 0, width: 10, height: 10))]
                ),
            ]
        ))
    }
}

/// Each enum case reaches Yoga as the value it names (see Yoga.swift).
@Suite struct LayoutStyleMappingTests {
    @Test(arguments: [
        (LayoutStyle.FlexDirection.column, [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 20)]),
        (.columnReverse, [CGPoint(x: 0, y: 80), CGPoint(x: 0, y: 60)]),
        (.row, [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)]),
        (.rowReverse, [CGPoint(x: 90, y: 0), CGPoint(x: 80, y: 0)]),
    ])
    func flexDirection(_ direction: LayoutStyle.FlexDirection, origins: [CGPoint]) {
        let root = row({
            $0.flexDirection = direction
            $0.alignItems = .flexStart
        }, children: [box(width: 10, height: 20), box(width: 10, height: 20)])

        root.calculateLayout(width: 100, height: 100)

        #expect(root.children.map(\.frame.origin) == origins)
    }

    @Test(arguments: [
        (LayoutStyle.Justify.flexStart, [0, 10] as [CGFloat]),
        (.center, [40, 50]),
        (.flexEnd, [80, 90]),
        (.spaceBetween, [0, 90]),
        (.spaceAround, [20, 70]),
        (.spaceEvenly, [80 / 3, 160 / 3 + 10]),
    ])
    func justify(_ justify: LayoutStyle.Justify, xs: [CGFloat]) {
        let root = row({ $0.justifyContent = justify }, children: [box(width: 10, height: 10), box(width: 10, height: 10)])

        root.calculateLayout(width: 100, height: 10)

        for (actual, expected) in zip(root.children.map(\.frame.minX), xs) {
            #expect(abs(actual - expected) <= 1, "\(justify): \(actual) vs \(expected)")
        }
    }

    @Test(arguments: [
        (LayoutStyle.Align.flexStart, CGRect(x: 0, y: 0, width: 10, height: 10)),
        (.center, CGRect(x: 0, y: 45, width: 10, height: 10)),
        (.flexEnd, CGRect(x: 0, y: 90, width: 10, height: 10)),
        (.stretch, CGRect(x: 0, y: 0, width: 10, height: 100)),
        (.baseline, CGRect(x: 0, y: 0, width: 10, height: 10)),
    ])
    func alignItems(_ align: LayoutStyle.Align, frame: CGRect) {
        var child = LayoutStyle()
        child.width = .points(10)
        child.height = align == .stretch ? .auto : .points(10)
        let root = row({ $0.alignItems = align }, children: [LayoutNode(style: child)])

        root.calculateLayout(width: 100, height: 100)

        #expect(root.children[0].frame == frame)
    }

    @Test func alignSelfOverridesAlignItems() {
        var child = LayoutStyle()
        child.width = .points(10)
        child.height = .points(10)
        child.alignSelf = .flexEnd
        let root = row({ $0.alignItems = .flexStart }, children: [LayoutNode(style: child)])

        root.calculateLayout(width: 100, height: 100)

        #expect(root.children[0].frame.origin == CGPoint(x: 0, y: 90))
    }

    @Test func styleDirectionOverridesInherited() {
        let root = row({
            $0.direction = .rightToLeft
            $0.alignItems = .flexStart
        }, children: [box(width: 10, height: 10)])

        root.calculateLayout(width: 100, height: 10, direction: .leftToRight)

        #expect(root.children[0].frame.minX == 90)
    }

    @Test func flexShrink() {
        var shrinking = LayoutStyle()
        shrinking.width = .points(80)
        shrinking.flexShrink = 1
        var rigid = LayoutStyle()
        rigid.width = .points(80)
        let root = row(children: [LayoutNode(style: shrinking), LayoutNode(style: rigid)])

        root.calculateLayout(width: 100, height: 10)

        #expect(root.children.map(\.frame.width) == [20, 80])
    }
}
