import Foundation
import Testing
import UltraLayout

/// Percentage padding, margins and insets resolve against the parent's
/// size. Laying a tree out again after the parent resized must give what a
/// fresh layout at the new size gives, also for a child whose own size is
/// fixed and so could reuse its earlier layout.
@Suite struct PercentEdgeTests {
    private func tree(_ edges: (inout LayoutStyle) -> Void) -> (root: LayoutNode, inner: LayoutNode) {
        var innerStyle = LayoutStyle()
        innerStyle.height = .points(10)
        let inner = LayoutNode(style: innerStyle)
        var fixed = LayoutStyle()
        fixed.width = .points(100)
        fixed.height = .points(50)
        edges(&fixed)
        let child = LayoutNode(style: fixed, children: [inner])
        var rootStyle = LayoutStyle()
        rootStyle.alignItems = .flexStart
        return (LayoutNode(style: rootStyle, children: [child]), inner)
    }

    @Test func paddingFollowsTheParentsWidth() {
        let (root, inner) = tree { $0.paddingLeft = .percent(10) }
        root.calculateLayout(width: 300, height: 400)
        #expect(inner.frame == CGRect(x: 30, y: 0, width: 70, height: 10))

        root.calculateLayout(width: 200, height: 400)
        let (fresh, freshInner) = tree { $0.paddingLeft = .percent(10) }
        fresh.calculateLayout(width: 200, height: 400)
        #expect(freshInner.frame == CGRect(x: 20, y: 0, width: 80, height: 10))
        #expect(inner.frame == freshInner.frame)
        #expect(root.children[0].resolvedPadding.left == 20)
    }

    @Test func marginsAndInsetsFollowTheParentsSize() {
        let (root, _) = tree {
            $0.marginLeft = .percent(10)
            $0.top = .percent(10)
        }
        root.calculateLayout(width: 300, height: 400)
        #expect(root.children[0].frame == CGRect(x: 30, y: 40, width: 100, height: 50))

        root.calculateLayout(width: 200, height: 200)
        #expect(root.children[0].frame == CGRect(x: 20, y: 20, width: 100, height: 50))
    }

    @Test func aChildMovedToAnotherParentResolvesAgainstIt() {
        let (root, inner) = tree { $0.paddingLeft = .percent(10) }
        root.calculateLayout(width: 300, height: 400)
        let child = root.children[0]

        var otherStyle = LayoutStyle()
        otherStyle.width = .points(500)
        otherStyle.alignItems = .flexStart
        let other = LayoutNode(style: otherStyle)
        root.removeChild(child)
        other.addChild(child)
        root.addChild(other)
        root.calculateLayout(width: 300, height: 400)
        #expect(inner.frame.minX == 50)
    }
}
