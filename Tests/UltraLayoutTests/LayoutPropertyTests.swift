import Foundation
import Testing
import UltraLayout

private func node(_ configure: (inout LayoutStyle) -> Void = { _ in }, children: [LayoutNode] = []) -> LayoutNode {
    var style = LayoutStyle()
    configure(&style)
    return LayoutNode(style: style, children: children)
}

private func box(_ width: CGFloat, _ height: CGFloat, _ configure: (inout LayoutStyle) -> Void = { _ in }) -> LayoutNode {
    node({
        $0.width = .points(width)
        $0.height = .points(height)
        configure(&$0)
    })
}

/// Every style property reaches Yoga and has its effect on frames.
@Suite struct LayoutPropertyTests {
    @Test(arguments: [
        (LayoutStyle.Wrap.noWrap, [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 0), CGPoint(x: 80, y: 0)]),
        (.wrap, [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 0), CGPoint(x: 0, y: 10)]),
        (.wrapReverse, [CGPoint(x: 0, y: 10), CGPoint(x: 40, y: 10), CGPoint(x: 0, y: 0)]),
    ])
    func flexWrap(_ wrap: LayoutStyle.Wrap, origins: [CGPoint]) {
        let root = node({
            $0.flexDirection = .row
            $0.flexWrap = wrap
            $0.alignItems = .flexStart
            $0.alignContent = .flexStart
        }, children: [box(40, 10), box(40, 10), box(40, 10)])

        root.calculateLayout(width: 100, height: nil)

        #expect(root.children.map(\.frame.origin) == origins)
    }

    @Test(arguments: [
        (LayoutStyle.Align.flexStart, [0, 10] as [CGFloat]),
        (.center, [40, 50]),
        (.flexEnd, [80, 90]),
        (.spaceBetween, [0, 90]),
        (.spaceAround, [20, 70]),
        (.spaceEvenly, [80 / 3, 160 / 3 + 10]),
        (.stretch, [0, 50]),
    ])
    func alignContent(_ align: LayoutStyle.Align, ys: [CGFloat]) {
        let root = node({
            $0.flexDirection = .row
            $0.flexWrap = .wrap
            $0.alignContent = align
            $0.alignItems = .flexStart
        }, children: [box(60, 10), box(60, 10)])

        root.calculateLayout(width: 100, height: 100)

        for (actual, expected) in zip(root.children.map(\.frame.minY), ys) {
            #expect(abs(actual - expected) <= 1, "\(align): \(actual) vs \(expected)")
        }
    }

    @Test func alignContentDefaultsToFlexStart() {
        #expect(LayoutStyle().alignContent == .flexStart)
        #expect(LayoutStyle().flexDirection == .column)
        #expect(LayoutStyle().flexShrink == nil)
    }

    @Test func absolutePositionUsesInsets() {
        let child = box(20, 10) {
            $0.position = .absolute
            $0.right = 5
            $0.bottom = 0
        }
        let root = node({ $0.padding = 10 }, children: [box(50, 50), child])

        root.calculateLayout(width: 100, height: 100)

        #expect(child.frame == CGRect(x: 75, y: 90, width: 20, height: 10))
        #expect(root.children[0].frame.origin == CGPoint(x: 10, y: 10))
    }

    @Test func absolutePercentInsetsAndSize() {
        let child = node {
            $0.position = .absolute
            $0.left = .percent(10)
            $0.top = .percent(20)
            $0.width = .percent(50)
            $0.height = .percent(25)
        }
        let root = node(children: [child])

        root.calculateLayout(width: 200, height: 100)

        #expect(child.frame == CGRect(x: 20, y: 20, width: 100, height: 25))
    }

    @Test func relativeInsetsShiftWithoutAffectingSiblings() {
        let shifted = box(10, 10) {
            $0.top = 5
            $0.left = 7
        }
        let root = node(children: [shifted, box(10, 10)])

        root.calculateLayout(width: 100, height: 100)

        #expect(shifted.frame.origin == CGPoint(x: 7, y: 5))
        #expect(root.children[1].frame.origin == CGPoint(x: 0, y: 10))
    }

    @Test func displayNoneTakesNoSpace() {
        let hidden = box(50, 50) { $0.display = .none }
        let root = node({ $0.alignItems = .flexStart }, children: [hidden, box(10, 10)])

        root.calculateLayout(width: 100, height: 100)

        #expect(hidden.frame.size == .zero)
        #expect(root.children[1].frame.origin == .zero)
    }

    @Test func aspectRatio() {
        let child = node {
            $0.width = 80
            $0.aspectRatio = 2
        }
        let root = node({ $0.alignItems = .flexStart }, children: [child])

        root.calculateLayout(width: 100, height: 100)

        #expect(child.frame.size == CGSize(width: 80, height: 40))
    }

    @Test func minAndMaxSizes() {
        let tooSmall = box(10, 10) {
            $0.minWidth = 30
            $0.minHeight = .percent(50)
        }
        let tooBig = box(500, 500) {
            $0.maxWidth = 60
            $0.maxHeight = 20
        }
        let root = node({ $0.alignItems = .flexStart }, children: [tooSmall, tooBig])

        root.calculateLayout(width: 100, height: 100)

        #expect(tooSmall.frame.size == CGSize(width: 30, height: 50))
        #expect(tooBig.frame.size == CGSize(width: 60, height: 20))
    }

    @Test func flexBasisAndFlexShorthand() {
        let based = node {
            $0.flexBasis = 30
            $0.flexGrow = 1
        }
        let flexible = node { $0.flex = 1 }
        let root = node({ $0.flexDirection = .row }, children: [based, flexible])

        root.calculateLayout(width: 130, height: 10)

        #expect(based.frame.width == 80)
        #expect(flexible.frame.width == 50)
    }

    @Test func percentFlexBasis() {
        let child = node { $0.flexBasis = .percent(25) }
        let root = node({ $0.flexDirection = .row }, children: [child])

        root.calculateLayout(width: 200, height: 10)

        #expect(child.frame.width == 50)
    }

    @Test func autoMarginsCenter() {
        let child = box(20, 20) { $0.margin = .auto }
        let root = node(children: [child])

        root.calculateLayout(width: 100, height: 100)

        #expect(child.frame.origin == CGPoint(x: 40, y: 40))
    }

    @Test func edgePrecedence() {
        let child = box(10, 10) {
            $0.margin = 1
            $0.marginHorizontal = 3
            $0.marginLeft = 7
        }
        let root = node({ $0.alignItems = .flexStart }, children: [child])

        root.calculateLayout(width: 100, height: 100)

        #expect(child.frame.origin == CGPoint(x: 7, y: 1))
    }

    @Test func startAndEndFollowDirection() {
        let child = box(10, 10) { $0.marginStart = 5 }
        let root = node({ $0.alignItems = .flexStart }, children: [child])

        root.calculateLayout(width: 100, height: 100, direction: .leftToRight)
        #expect(child.frame.minX == 5)

        root.calculateLayout(width: 100, height: 100, direction: .rightToLeft)
        #expect(child.frame.minX == 85)
    }

    @Test func paddingPercentAndVertical() {
        let child = node { $0.height = 10 }
        let root = node({
            $0.paddingVertical = 6
            $0.paddingHorizontal = .percent(10)
        }, children: [child])

        root.calculateLayout(width: 200, height: 100)

        #expect(child.frame == CGRect(x: 20, y: 6, width: 160, height: 10))
        #expect(root.resolvedPadding == Insets(top: 6, left: 20, bottom: 6, right: 20))
    }

    @Test func borderWidthsTakeSpace() {
        let child = node { $0.height = 10 }
        let root = node({
            $0.borderWidth = 2
            $0.borderLeftWidth = 5
            $0.borderStartWidth = 4
        }, children: [child])

        root.calculateLayout(width: 100, height: 100)

        #expect(child.frame == CGRect(x: 4, y: 2, width: 94, height: 10))
        #expect(root.resolvedBorder == Insets(top: 2, left: 4, bottom: 2, right: 2))
    }

    @Test func rowAndColumnGaps() {
        let root = node({
            $0.flexDirection = .row
            $0.flexWrap = .wrap
            $0.gap = 1
            $0.columnGap = 10
            $0.rowGap = 5
            $0.alignItems = .flexStart
        }, children: [box(40, 10), box(40, 10), box(40, 10)])

        root.calculateLayout(width: 100, height: nil)

        #expect(root.children.map(\.frame.origin) == [
            CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0), CGPoint(x: 0, y: 15),
        ])
    }

    @Test func overflowScrollMeasuresChildrenWithoutLimit() {
        let content = node(children: [box(50, 300)])
        let scroller = node({ $0.overflow = .scroll }, children: [content])

        scroller.calculateLayout(width: 100, height: 200)

        #expect(content.frame.size == CGSize(width: 100, height: 300))
        #expect(scroller.frame.size == CGSize(width: 100, height: 200))
    }

    @Test func overflowHiddenKeepsSize() {
        let content = node(children: [box(50, 300)])
        let clipper = node({ $0.overflow = .hidden }, children: [content])

        clipper.calculateLayout(width: 100, height: 200)

        #expect(content.frame.height == 300)
        #expect(clipper.frame.height == 200)
    }

    @Test func boxSizing() {
        let borderBox = box(50, 50) { $0.padding = 10 }
        let contentBox = box(50, 50) {
            $0.padding = 10
            $0.boxSizing = .contentBox
        }
        let root = node({ $0.alignItems = .flexStart }, children: [borderBox, contentBox])

        root.calculateLayout(width: 200, height: 200)

        #expect(borderBox.frame.size == CGSize(width: 50, height: 50))
        #expect(contentBox.frame.size == CGSize(width: 70, height: 70))
    }

    @Test func staticPositionIgnoresInsets() {
        let child = box(10, 10) {
            $0.position = .static
            $0.left = 30
        }
        let root = node({ $0.alignItems = .flexStart }, children: [child])

        root.calculateLayout(width: 100, height: 100)

        #expect(child.frame.minX == 0)
    }

    @Test func clearingAValueRestoresTheDefault() {
        let child = box(10, 10)
        let root = node({ $0.alignItems = .flexStart }, children: [child])
        child.style.marginLeft = 20
        root.calculateLayout(width: 100, height: 100)
        #expect(child.frame.minX == 20)

        child.style.marginLeft = nil
        root.calculateLayout(width: 100, height: 100)
        #expect(child.frame.minX == 0)
    }
}

@Suite struct MeasureFunctionTests {
    @Test func leafIsSizedByItsMeasureFunction() {
        let leaf = LayoutNode()
        var calls: [(CGFloat, MeasureMode)] = []
        leaf.measureFunction = { width, widthMode, _, _ in
            calls.append((width, widthMode))
            return CGSize(width: min(width, 150), height: 30)
        }
        let root = node({ $0.alignItems = .flexStart }, children: [leaf])

        root.calculateLayout(width: 100, height: 200)

        #expect(leaf.frame.size == CGSize(width: 100, height: 30))
        #expect(calls.contains { $0.1 == .atMost && $0.0 == 100 })
    }

    @Test func stretchedLeafIsMeasuredExactly() {
        let leaf = LayoutNode()
        var modes: [MeasureMode] = []
        leaf.measureFunction = { width, mode, _, _ in
            modes.append(mode)
            return CGSize(width: 10, height: 20)
        }
        let root = node(children: [leaf])

        root.calculateLayout(width: 100, height: 200)

        #expect(leaf.frame.size == CGSize(width: 100, height: 20))
        #expect(modes.contains(.exactly))
    }

    @Test func markDirtyRemeasures() {
        let leaf = LayoutNode()
        var height: CGFloat = 10
        leaf.measureFunction = { _, _, _, _ in CGSize(width: 10, height: height) }
        let root = node({ $0.alignItems = .flexStart }, children: [leaf])
        root.calculateLayout(width: 100, height: nil)
        #expect(root.frame.height == 10)

        height = 40
        root.calculateLayout(width: 100, height: nil)
        #expect(root.frame.height == 10, "cached until marked dirty")

        leaf.markDirty()
        #expect(leaf.isDirty)
        root.calculateLayout(width: 100, height: nil)
        #expect(root.frame.height == 40)
    }

    @Test func textNodesRoundUpToThePixelGrid() {
        let text = LayoutNode(config: LayoutConfig.shared(pointScaleFactor: 2))
        text.isText = true
        text.measureFunction = { _, _, _, _ in CGSize(width: 10.1, height: 10.1) }
        let root = LayoutNode(config: LayoutConfig.shared(pointScaleFactor: 2), children: [text])
        root.style.alignItems = .flexStart

        root.calculateLayout(width: 100, height: 100)

        #expect(text.frame.size == CGSize(width: 10.5, height: 10.5))
    }

    @Test func pointScaleRoundsFrames() {
        let config = LayoutConfig.shared(pointScaleFactor: 3)
        var style = LayoutStyle()
        style.width = .percent(33.3333)
        style.height = 10
        let child = LayoutNode(style: style, config: config)
        let root = LayoutNode(config: config, children: [child])
        root.style.alignItems = .flexStart

        root.calculateLayout(width: 100, height: 100)

        let width = child.frame.width * 3
        #expect(abs(width - width.rounded()) < 0.001)
        #expect(LayoutConfig.shared(pointScaleFactor: 3) === config)
    }

    @Test func hasNewLayoutMarksRecomputedNodes() {
        let a = box(10, 10)
        let b = box(10, 10)
        let root = node(children: [a, b])
        root.calculateLayout(width: 100, height: 100)
        #expect(root.hasNewLayout)
        root.hasNewLayout = false
        a.hasNewLayout = false
        b.hasNewLayout = false

        // The root is always flagged; untouched children aren't.
        root.calculateLayout(width: 100, height: 100)
        #expect(!a.hasNewLayout)
        #expect(!b.hasNewLayout)

        b.style.height = 20
        root.calculateLayout(width: 100, height: 100)
        #expect(root.hasNewLayout)
        #expect(b.hasNewLayout)
    }

    @Test func childrenCanBeInsertedRemovedAndMoved() {
        let a = box(10, 10)
        let b = box(10, 20)
        let root = node(children: [a])
        root.insertChild(b, at: 0)
        root.calculateLayout(width: 100, height: 100)
        #expect(a.frame.minY == 20)

        root.removeChild(b)
        #expect(b.parent == nil)
        let other = node(children: [b])
        root.calculateLayout(width: 100, height: 100)
        #expect(a.frame.minY == 0)
        #expect(b.parent === other)

        b.removeFromParent()
        root.addChild(b)
        root.calculateLayout(width: 100, height: 100)
        #expect(b.frame.minY == 10)
    }
}
