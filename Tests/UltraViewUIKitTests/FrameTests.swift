#if canImport(UIKit)
import Testing
import UIKit
@testable import UltraCore
import UltraView

@MainActor
@Suite struct FrameTests {
    @Test func viewFramesMatchTheLayout() async throws {
        var bar = Style()
        bar.height = 44
        var content = Style()
        content.flexGrow = 1
        content.flexDirection = .row
        content.gap = 8
        var tile = Style()
        tile.flexGrow = 1
        let left = UltraNode(style: tile)
        let right = UltraNode(style: tile)
        let barNode = UltraNode(style: bar)
        let contentNode = UltraNode(style: content, children: [left, right])
        let root = UltraNode(children: [barNode, contentNode])

        let hosted = Hosted(root, size: CGSize(width: 208, height: 300))
        await hosted.settle()

        #expect(root.view?.frame == CGRect(x: 0, y: 0, width: 208, height: 300))
        #expect(barNode.view?.frame == CGRect(x: 0, y: 0, width: 208, height: 44))
        #expect(contentNode.view?.frame == CGRect(x: 0, y: 44, width: 208, height: 256))
        #expect(left.view?.frame == CGRect(x: 0, y: 0, width: 100, height: 256))
        #expect(right.view?.frame == CGRect(x: 108, y: 0, width: 100, height: 256))
        #expect(left.view?.superview === contentNode.view)
        #expect(root.view?.superview === hosted.host)
    }

    /// The same styles laid out directly with UltraLayout, at the screen's
    /// scale, give the frames the views end up with.
    @Test func everyFrameMatchesADirectLayout() async throws {
        let styles = sampleTree()
        let root = makeNodes(styles)
        let hosted = Hosted(root, size: CGSize(width: 375, height: 640))
        await hosted.settle()

        let direct = makeLayoutNodes(styles, config: .shared(pointScaleFactor: hosted.scale))
        direct.calculateLayout(width: 375, height: 640)
        compare(root, direct.result)
    }

    @Test func framesFollowStyleChangesFromAnotherThread() async throws {
        let child = UltraNode(style: styled { $0.height = 40 })
        let root = UltraNode(style: styled { $0.padding = 10 }, children: [child])
        let hosted = Hosted(root, size: CGSize(width: 200, height: 200))
        await hosted.settle()
        #expect(child.view?.frame == CGRect(x: 10, y: 10, width: 180, height: 40))

        await Task.detached {
            child.updateStyle {
                $0.height = 70
                $0.marginLeft = 20
            }
        }.value
        await hosted.settle()
        #expect(child.view?.frame == CGRect(x: 30, y: 10, width: 160, height: 70))
    }

    @Test func boxPropertiesReachTheLayer() async throws {
        let node = UltraNode(style: styled {
            $0.width = 80
            $0.height = 60
            $0.backgroundColor = .red
            $0.borderRadius = 12
            $0.borderWidth = 2
            $0.borderColor = .blue
            $0.opacity = 0.5
            $0.transform = [.scale(2)]
        })
        let hosted = Hosted(UltraNode(children: [node]))
        await hosted.settle()
        let layer = try #require(node.view?.layer)
        #expect(layer.cornerRadius == 12)
        #expect(layer.borderWidth == 2)
        #expect(layer.backgroundColor != nil)
        #expect(node.view?.alpha == 0.5)
        #expect(layer.transform.m11 == 2)
        #expect(layer.bounds.size == CGSize(width: 80, height: 60))
        _ = hosted
    }

    @Test func childrenFollowInsertsAndRemovals() async throws {
        let a = UltraNode(style: styled { $0.height = 10 })
        let b = UltraNode(style: styled { $0.height = 20 })
        let c = UltraNode(style: styled { $0.height = 30 })
        let root = UltraNode(children: [a, b])
        let hosted = Hosted(root)
        await hosted.settle()
        root.insertChild(c, at: 0)
        root.removeChild(a)
        await hosted.settle()
        #expect(a.view == nil)
        #expect(root.view?.subviews == [c.view, b.view].compactMap { $0 })
        #expect(c.view?.frame.minY == 0)
        #expect(b.view?.frame.minY == 30)
    }

    @Test func subviewsFollowEveryReordering() async throws {
        let pool = (0..<12).map { index in UltraNode(style: styled { $0.height = .points(CGFloat(index + 1)) }) }
        let root = UltraNode(children: Array(pool.prefix(6)))
        let hosted = Hosted(root)
        await hosted.settle()
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<40 {
            let children = Array(pool.shuffled(using: &generator).prefix(Int.random(in: 0...pool.count, using: &generator)))
            let passes = hosted.host.renderer.passCount.load(ordering: .relaxed)
            let commits = hosted.host.statistics.current.commits
            root.setChildren(children)
            await hosted.settle()
            let state = "passes +\(hosted.host.renderer.passCount.load(ordering: .relaxed) - passes) commits +\(hosted.host.statistics.current.commits - commits)"
            #expect(root.view?.subviews == children.compactMap(\.view), "\(state)")
            #expect(children.allSatisfy { $0.view?.superview === root.view })
        }
    }

    // MARK: Helpers

    private final class StyleTree {
        let style: LayoutStyle
        let children: [StyleTree]
        init(_ style: LayoutStyle, _ children: [StyleTree] = []) {
            self.style = style
            self.children = children
        }
    }

    private func sampleTree() -> StyleTree {
        func style(_ body: (inout LayoutStyle) -> Void) -> LayoutStyle {
            var style = LayoutStyle()
            body(&style)
            return style
        }
        let chip = style {
            $0.width = 70
            $0.height = 28
            $0.margin = 3
        }
        return StyleTree(style { $0.padding = 12; $0.gap = 10 }, [
            StyleTree(style { $0.height = 44; $0.flexDirection = .row; $0.justifyContent = .spaceBetween; $0.alignItems = .center }, [
                StyleTree(style { $0.width = 30; $0.height = 30 }),
                StyleTree(style { $0.width = 120; $0.height = 20 }),
                StyleTree(style { $0.width = 30; $0.height = 30 }),
            ]),
            StyleTree(style { $0.flexDirection = .row; $0.flexWrap = .wrap; $0.alignContent = .spaceAround; $0.height = 130 },
                      (0..<9).map { _ in StyleTree(chip) }),
            StyleTree(style { $0.flexDirection = .row; $0.height = 80; $0.columnGap = 7 }, [
                StyleTree(style { $0.flex = 1 }),
                StyleTree(style { $0.flex = 2; $0.paddingHorizontal = 5 }, [
                    StyleTree(style { $0.position = .absolute; $0.top = 4; $0.right = 4; $0.width = 16; $0.height = 16 }),
                ]),
                StyleTree(style { $0.width = .percent(25); $0.aspectRatio = 1; $0.alignSelf = .flexStart; $0.maxHeight = 60 }),
            ]),
            StyleTree(style { $0.flexGrow = 1; $0.flexDirection = .rowReverse; $0.alignItems = .flexEnd }, [
                StyleTree(style { $0.width = 33.3; $0.height = 41.7; $0.marginRight = 5.5 }),
                StyleTree(style { $0.width = .percent(33); $0.height = .percent(50) }),
            ]),
        ])
    }

    private func makeNodes(_ tree: StyleTree) -> UltraNode {
        var style = Style()
        style.layout = tree.style
        return UltraNode(style: style, children: tree.children.map(makeNodes))
    }

    private func makeLayoutNodes(_ tree: StyleTree, config: LayoutConfig) -> LayoutNode {
        LayoutNode(style: tree.style, config: config, children: tree.children.map { makeLayoutNodes($0, config: config) })
    }

    private func compare(_ node: UltraNode, _ result: LayoutResult) {
        #expect(node.view?.frame == result.frame, "\(node)")
        #expect(node.children.count == result.children.count)
        for (child, childResult) in zip(node.children, result.children) {
            compare(child, childResult)
        }
    }
}
#endif
