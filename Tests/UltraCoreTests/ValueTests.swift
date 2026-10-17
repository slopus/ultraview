import Dispatch
import Foundation
import Testing
@testable import UltraCore
import UltraLayout

@Suite struct PressRecognizerTests {
    @Test func tapPressesInOutAndPresses() {
        var press = PressRecognizer(handlesLongPress: false)
        #expect(press.touchBegan() == [.pressIn])
        #expect(press.touchEnded(inside: true) == [.pressOut, .press])
        #expect(press.phase == .idle)
    }

    @Test func leavingAndComingBack() {
        var press = PressRecognizer(handlesLongPress: false)
        _ = press.touchBegan()
        #expect(press.touchMoved(inside: true) == [])
        #expect(press.touchMoved(inside: false) == [.pressOut])
        #expect(press.touchMoved(inside: false) == [])
        #expect(press.touchMoved(inside: true) == [.pressIn])
        #expect(press.touchEnded(inside: true) == [.pressOut, .press])
    }

    @Test func releasingOutsideDoesNotPress() {
        var press = PressRecognizer(handlesLongPress: false)
        _ = press.touchBegan()
        _ = press.touchMoved(inside: false)
        #expect(press.touchEnded(inside: false) == [])
    }

    @Test func longPressReplacesThePress() {
        var press = PressRecognizer(handlesLongPress: true)
        _ = press.touchBegan()
        #expect(press.longPressTimerFired() == [.longPress])
        #expect(press.longPressTimerFired() == [])
        #expect(press.touchEnded(inside: true) == [.pressOut])
    }

    @Test func withoutALongPressHandlerTheTimerDoesNothing() {
        var press = PressRecognizer(handlesLongPress: false)
        _ = press.touchBegan()
        #expect(press.longPressTimerFired() == [])
        #expect(press.touchEnded(inside: true) == [.pressOut, .press])
    }

    @Test func longPressNeedsTheTouchInside() {
        var press = PressRecognizer(handlesLongPress: true)
        _ = press.touchBegan()
        _ = press.touchMoved(inside: false)
        #expect(press.longPressTimerFired() == [])
    }

    @Test func cancelling() {
        var press = PressRecognizer(handlesLongPress: false)
        _ = press.touchBegan()
        #expect(press.touchCancelled() == [.pressOut])
        #expect(press.touchEnded(inside: true) == [])
    }
}

@Suite struct TransformTests {
    private func close(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9
    }

    @Test func theLastOperationActsFirst() {
        let transform = Transform3D([.translateX(10), .scale(2)])
        #expect(close(transform.apply(to: CGPoint(x: 1, y: 1)), CGPoint(x: 12, y: 2)))

        let reversed = Transform3D([.scale(2), .translateX(10)])
        #expect(close(reversed.apply(to: CGPoint(x: 1, y: 1)), CGPoint(x: 22, y: 2)))
    }

    @Test func rotationIsClockwiseOnScreen() {
        let transform = Transform3D([.rotate(degrees: 90)])
        #expect(close(transform.apply(to: CGPoint(x: 1, y: 0)), CGPoint(x: 0, y: 1)))
    }

    @Test func skewAndScaleAxes() {
        #expect(close(Transform3D([.skewX(.pi / 4)]).apply(to: CGPoint(x: 0, y: 1)), CGPoint(x: 1, y: 1)))
        #expect(close(Transform3D([.skewY(.pi / 4)]).apply(to: CGPoint(x: 1, y: 0)), CGPoint(x: 1, y: 1)))
        #expect(close(Transform3D([.scaleX(3), .scaleY(2)]).apply(to: CGPoint(x: 1, y: 1)), CGPoint(x: 3, y: 2)))
        #expect(close(Transform3D([.translate(x: 4, y: 5)]).apply(to: .zero), CGPoint(x: 4, y: 5)))
    }

    @Test func perspectiveSetsTheDepthTerm() {
        let transform = Transform3D([.perspective(500)])
        #expect(transform[2, 3] == -1.0 / 500)
        #expect(Transform3D([]).isIdentity)
        #expect(Transform3D([.matrix(transform)]) == transform)
    }

    @Test func threeDimensionalRotationsKeepTheAxis() {
        let x = Transform3D([.rotateX(.pi / 3)])
        #expect(x[0, 0] == 1)
        let y = Transform3D([.rotateY(.pi / 3)])
        #expect(y[1, 1] == 1)
    }
}

@Suite struct StyleTests {
    @Test func layoutPropertiesAreAvailableOnTheStyle() {
        var style = Style()
        style.flexDirection = .row
        style.paddingHorizontal = 12
        style.width = .percent(50)
        style.marginTop = .auto

        #expect(style.layout.flexDirection == .row)
        #expect(style.layout.paddings.horizontal == 12)
        #expect(style.layout.width == .percent(50))
        #expect(style.layout.margins.top == .auto)
    }

    @Test func defaultsMatchYoga() {
        let style = Style()
        #expect(style.flexDirection == .column)
        #expect(style.alignItems == .stretch)
        #expect(style.alignContent == .flexStart)
        #expect(style.flexShrink == nil)
        #expect(style.position == .relative)
        #expect(style.opacity == 1)
        #expect(style.pointerEvents == .auto)
    }

    @Test func boxChangesAreTold() {
        var style = Style()
        var other = style
        other.opacity = 0.5
        #expect(!style.boxDiffers(from: other))
        other.borderTopLeftRadius = 3
        #expect(style.boxDiffers(from: other))
        style.borderTopLeftRadius = 3
        style.borderBottomWidth = 1
        #expect(style.boxDiffers(from: other))
    }

    @Test func colorsFromHexAndDynamic() {
        let color = Color(hex: 0x3478F6)
        #expect(abs(color.light.red - 0x34 / 255.0) < 1e-9)
        #expect(abs(color.light.blue - 0xF6 / 255.0) < 1e-9)
        let dynamic = Color.dynamic(light: .white, dark: .black)
        #expect(dynamic.resolved(dark: false) == Color.white.light)
        #expect(dynamic.resolved(dark: true) == Color.black.light)
        #expect(Color.red.resolved(dark: true) == Color.red.light)
        #expect(dynamic.withAlpha(0.5).resolved(dark: true).alpha == 0.5)
    }
}

@Suite struct NodeTreeTests {
    @Test func childrenCanBeAddedInsertedAndRemoved() {
        let a = UltraNode(), b = UltraNode(), c = UltraNode()
        let parent = UltraNode(children: [a])
        parent.addChild(c)
        parent.insertChild(b, at: 1)
        #expect(same(parent.children, [a, b, c]))
        #expect(b.parent === parent)

        parent.removeChild(b)
        #expect(same(parent.children, [a, c]))
        #expect(b.parent == nil)

        c.removeFromParent()
        #expect(same(parent.children, [a]))
    }

    @Test func addingMovesFromTheOldParent() {
        let child = UltraNode()
        let first = UltraNode(children: [child])
        let second = UltraNode()
        second.addChild(child)
        #expect(first.children.isEmpty)
        #expect(child.parent === second)

        let third = UltraNode()
        third.setChildren([child])
        #expect(second.children.isEmpty)
        #expect(child.parent === third)
    }

    @Test func setChildrenReleasesTheOldOnes() {
        let a = UltraNode(), b = UltraNode()
        let parent = UltraNode(children: [a, b])
        parent.setChildren([b])
        #expect(a.parent == nil)
        #expect(b.parent === parent)
    }

    @Test func scrollNodesForwardChildrenToTheirContent() {
        let a = UltraNode(), b = UltraNode()
        let scroll = UltraScrollNode(children: [a])
        scroll.addChild(b)
        #expect(same(scroll.children, [a, b]))
        #expect(a.parent === scroll.contentNode)
        scroll.removeChild(a)
        #expect(same(scroll.children, [b]))
    }

    @Test func concurrentChangesKeepTheTreeConsistent() {
        let parents = (0..<4).map { _ in UltraNode() }
        let children = (0..<32).map { _ in UltraNode() }
        DispatchQueue.concurrentPerform(iterations: 8) { thread in
            for step in 0..<500 {
                let child = children[(thread * 7 + step) % children.count]
                parents[(thread + step) % parents.count].addChild(child)
                child.updateStyle { $0.opacity = CGFloat(step % 3) / 2 }
            }
        }
        var seen = Set<ObjectIdentifier>()
        for parent in parents {
            for child in parent.children {
                #expect(seen.insert(ObjectIdentifier(child)).inserted, "a child appears under one parent")
                #expect(child.parent === parent)
            }
        }
        #expect(seen.count == children.count)
    }

    @Test func textNodesTakeTheirTextApart() {
        let label = UltraTextNode(spans: [TextSpan("a", children: [TextSpan("b")]), TextSpan("c")])
        #expect(label.text == "abc")
        label.text = "x"
        #expect(label.spans.count == 1)
        label.numberOfLines = 2
        label.ellipsizeMode = .head
        label.maxFontSizeMultiplier = 2
        label.allowFontScaling = false
        #expect(label.numberOfLines == 2)
        #expect(label.ellipsizeMode == .head)
        #expect(label.maxFontSizeMultiplier == 2)
        #expect(!label.allowFontScaling)
    }
}
