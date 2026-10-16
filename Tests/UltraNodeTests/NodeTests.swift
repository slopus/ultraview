import Foundation
import Testing
import UltraLayout
import UltraNode

@Suite struct NodeTests {
    @Test func layoutReturnsFramesOfTheTree() {
        var header = LayoutStyle()
        header.height = .points(44)
        var body = LayoutStyle()
        body.flexGrow = 1
        var root = LayoutStyle()
        root.padding = LayoutInsets(top: 20, left: 0, bottom: 0, right: 0)
        let tree = Node(style: root, children: [Node(style: header), Node(style: body)])

        let result = tree.layout(width: 320, height: 480)

        #expect(tree.layoutPassCount == 1)

        #expect(result.frame == CGRect(x: 0, y: 0, width: 320, height: 480))
        #expect(result.children.map(\.frame) == [
            CGRect(x: 0, y: 20, width: 320, height: 44),
            CGRect(x: 0, y: 64, width: 320, height: 416),
        ])
    }

    @Test func layoutRunsOffTheMainThread() async {
        let result = await Task.detached {
            var child = LayoutStyle()
            child.width = .percent(50)
            child.height = .points(10)
            return Node(children: [Node(style: child)]).layout(width: 200, height: nil)
        }.value

        #expect(result.children.first?.frame == CGRect(x: 0, y: 0, width: 100, height: 10))
        #expect(result.frame.height == 10)
    }
}
