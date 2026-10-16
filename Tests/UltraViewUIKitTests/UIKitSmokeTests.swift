#if canImport(UIKit)
import Testing
import UIKit
import UltraView

@MainActor
@Suite struct UIKitSmokeTests {
    @Test func appliesALayoutComputedOffTheMainThread() async {
        let result = await Task.detached {
            var bar = LayoutStyle()
            bar.height = .points(44)
            var content = LayoutStyle()
            content.flexGrow = 1
            content.flexDirection = .row
            content.gap = 8
            var tile = LayoutStyle()
            tile.flexGrow = 1
            let tree = Node(children: [
                Node(style: bar),
                Node(style: content, children: [Node(style: tile), Node(style: tile)]),
            ])
            return tree.layout(width: 208, height: 300)
        }.value

        let root = UIView()
        let bar = UIView()
        let content = UIView()
        let left = UIView()
        let right = UIView()
        root.addSubview(bar)
        root.addSubview(content)
        content.addSubview(left)
        content.addSubview(right)

        result.apply(to: root)

        #expect(root.frame == CGRect(x: 0, y: 0, width: 208, height: 300))
        #expect(bar.frame == CGRect(x: 0, y: 0, width: 208, height: 44))
        #expect(content.frame == CGRect(x: 0, y: 44, width: 208, height: 256))
        #expect(left.frame == CGRect(x: 0, y: 0, width: 100, height: 256))
        #expect(right.frame == CGRect(x: 108, y: 0, width: 100, height: 256))
    }

    @Test func listViewTakesGeometry() {
        let list = ListView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        list.setGeometry(ListGeometry(itemExtents: [10, 20]))
        #expect(list.geometry.contentExtent == 30)
    }
}
#endif
