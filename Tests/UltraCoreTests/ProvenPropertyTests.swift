import Foundation
import Testing
@testable import UltraCore
import UltraLayout

/// Properties the formal model in `Proofs/` assumes or proves, checked
/// against the pipeline. A known issue marks a case where the code doesn't
/// have the property yet.
@Suite struct ProvenPropertyTests {
    /// Commit soundness assumes layout is a pure function of the tree: a
    /// tree laid out again after a change must get the frames a fresh
    /// layout gives. Percentage padding resolves against the parent's width,
    /// but Yoga's cache for a fixed-size child ignores that width.
    @Test func percentagePaddingFollowsTheParentAfterAResize() throws {
        func padded(_ child: UltraNode) -> UltraNode {
            box({
                $0.width = 100
                $0.height = 50
                $0.paddingLeft = .percent(10)
            }, children: [child])
        }
        let inner = box { $0.height = 10 }
        let harness = Harness(root: box({ $0.alignItems = .flexStart }, children: [padded(inner)]), width: 300)
        harness.pass()
        harness.update { $0.width = 200 }
        harness.pass()

        let freshInner = box { $0.height = 10 }
        let fresh = Harness(root: box({ $0.alignItems = .flexStart }, children: [padded(freshInner)]), width: 200)
        fresh.pass()
        let expected = fresh.read { freshInner.shadow.frame }
        #expect(expected == CGRect(x: 20, y: 0, width: 80, height: 10))
        withKnownIssue("Yoga's layout cache keeps the padding resolved against the old width") {
            #expect(harness.read { inner.shadow.frame } == expected)
        }
    }

    /// Text inside percentage padding: its inset, link regions and bitmap
    /// must follow the padding even when the text node's frame stays put.
    @Test func percentagePaddingMovesTextInAFixedFrame() throws {
        func label() -> UltraTextNode {
            UltraTextNode(
                spans: [TextSpan("ab"), TextSpan("cd", onPress: {})],
                style: {
                    var style = Style()
                    style.width = 100
                    style.height = 50
                    style.paddingLeft = .percent(10)
                    return style
                }(),
                textStyle: TextStyle(fontSize: 20)
            )
        }
        let resized = label()
        let harness = Harness(root: box({ $0.alignItems = .flexStart }, children: [resized]), width: 300)
        harness.pass()
        harness.update { $0.width = 200 }
        harness.pass()

        let freshLabel = label()
        let fresh = Harness(root: box({ $0.alignItems = .flexStart }, children: [freshLabel]), width: 200)
        fresh.pass()
        let expected = fresh.read { freshLabel.shadow.sentProps?.text?.links }
        #expect(expected?.first?.rects.first?.minX == 40)
        withKnownIssue("the stale padding keeps the old inset; evaluate also skips a node whose frame is unchanged") {
            #expect(harness.read { resized.shadow.sentProps?.text?.links } == expected)
        }
    }

    /// Interface states are computed from each node's parent. A node moved
    /// while a pass runs can be synced under its new parent before its old
    /// parent is synced; the old parent's shadow still lists it, and an
    /// interface-state change there must not reach it.
    @Test func aMoveRacingAPassLeavesTheNodeWithItsNewParentsState() throws {
        let moved = box { $0.height = 10 }
        let rows = (0..<100).map { _ in box { $0.height = 50 } }
        rows[0].addChild(moved)
        let scroll = UltraScrollNode(style: { var style = Style(); style.height = 100; return style }(), children: rows)
        let newParent = box { $0.height = 20 }
        let harness = Harness(root: box(children: [scroll, newParent]))
        harness.pass()
        #expect(moved.interfaceState == .all)

        // The node moves. The pass that runs next syncs the new parent but
        // visited the old one before it was marked: simulate that by
        // withholding the old parent's mark until after the pass.
        newParent.addChild(moved)
        rows[0].needsSync.store(false, ordering: .sequentiallyConsistent)
        // In the same pass the old parent scrolls out of every range.
        scroll.reportContentOffset(CGPoint(x: 0, y: 2000))
        harness.pass()
        rows[0].setNeedsSync()
        harness.pass()

        #expect(newParent.interfaceState == .all)
        withKnownIssue("assignState follows the old parent's stale child list") {
            #expect(moved.interfaceState == newParent.interfaceState)
            #expect(harness.read { moved.shadow.isMounted })
        }
    }
}
