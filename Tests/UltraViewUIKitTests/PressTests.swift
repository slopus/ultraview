#if canImport(UIKit)
import Testing
import UIKit
@testable import UltraCore
import UltraView

@MainActor
@Suite struct PressTests {
    private func makeButton(_ log: EventLog) -> UltraNode {
        let button = UltraNode(style: styled {
            $0.width = 100
            $0.height = 44
            $0.backgroundColor = .blue
        })
        button.onPress = log.handler("press")
        button.onPressIn = log.handler("in")
        button.onPressOut = log.handler("out")
        return button
    }

    @Test func tapCallsInOutAndPress() async throws {
        let log = EventLog()
        let button = makeButton(log)
        let hosted = Hosted(UltraNode(children: [button]))
        await hosted.settle()
        let view = try #require(button.view as? NodeView)
        #expect(view.beginPress(at: CGPoint(x: 50, y: 22)))
        view.endPress(inside: true)
        #expect(log.events == ["in", "out", "press"])
    }

    @Test func draggingOffCancelsThePress() async throws {
        let log = EventLog()
        let button = makeButton(log)
        let hosted = Hosted(UltraNode(children: [button]))
        await hosted.settle()
        let view = try #require(button.view as? NodeView)
        _ = view.beginPress(at: CGPoint(x: 50, y: 22))
        view.movePress(inside: false)
        view.endPress(inside: false)
        #expect(log.events == ["in", "out"])
    }

    @Test func longPressReplacesPress() async throws {
        let log = EventLog()
        let button = makeButton(log)
        button.onLongPress = log.handler("long")
        let hosted = Hosted(UltraNode(children: [button]))
        await hosted.settle()
        let view = try #require(button.view as? NodeView)
        _ = view.beginPress(at: CGPoint(x: 50, y: 22))
        view.longPressTimerFired()
        view.endPress(inside: true)
        #expect(log.events == ["in", "long", "out"])
    }

    @Test func pressedOpacityShowsWhilePressed() async throws {
        let log = EventLog()
        let button = makeButton(log)
        button.pressedOpacity = 0.4
        let hosted = Hosted(UltraNode(children: [button]))
        await hosted.settle()
        let view = try #require(button.view as? NodeView)
        _ = view.beginPress(at: CGPoint(x: 50, y: 22))
        #expect(abs(view.alpha - 0.4) < 0.001)
        view.endPress(inside: true)
        #expect(view.alpha == 1)
    }

    @Test func hitTestingHonorsPointerEventsAndHitSlop() async throws {
        let log = EventLog()
        let button = makeButton(log)
        button.updateStyle { $0.hitSlop = Insets(all: 10) }
        let passive = UltraNode(style: styled {
            $0.width = 100
            $0.height = 44
            $0.pointerEvents = .none
        })
        let root = UltraNode(style: styled { $0.padding = 20; $0.gap = 30 }, children: [button, passive])
        let hosted = Hosted(root)
        await hosted.settle()
        // Inside the button, and 8 points outside it (within the slop).
        #expect(hosted.host.hitTest(CGPoint(x: 70, y: 42), with: nil) === button.view)
        #expect(hosted.host.hitTest(CGPoint(x: 70, y: 20 + 44 + 8), with: nil) === button.view)
        // The passive node never receives touches.
        #expect(hosted.host.hitTest(CGPoint(x: 70, y: 20 + 44 + 30 + 22), with: nil) !== passive.view)
    }

    @Test func pressableSpansHaveTheirOwnHandlers() async throws {
        let log = EventLog()
        let text = UltraTextNode(spans: [
            TextSpan("Read the "),
            TextSpan("terms", style: TextStyle(color: .blue), onPress: log.handler("terms")),
            TextSpan(" and the "),
            TextSpan("policy", style: TextStyle(color: .blue), onPress: log.handler("policy"), onLongPress: log.handler("policy long")),
        ], textStyle: TextStyle(fontSize: 17))
        text.onPress = log.handler("text")
        let hosted = Hosted(UltraNode(style: styled { $0.alignItems = .flexStart }, children: [text]))
        await hosted.settle()
        let view = try #require(text.view as? NodeView)
        let links = try #require(view.props?.text?.links)
        #expect(links.map(\.index) == [0, 1])

        let terms = links[0].rects[0]
        #expect(view.beginPress(at: CGPoint(x: terms.midX, y: terms.midY)))
        // The pressed span is highlighted.
        #expect(view.layer.sublayers?.contains { $0 is CAShapeLayer } == true)
        view.endPress(inside: true)
        #expect(view.layer.sublayers?.contains { $0 is CAShapeLayer } != true)

        let policy = links[1].rects[0]
        _ = view.beginPress(at: CGPoint(x: policy.midX, y: policy.midY))
        view.longPressTimerFired()
        view.endPress(inside: true)

        // Outside the links, the node's own handler.
        _ = view.beginPress(at: CGPoint(x: 2, y: terms.midY))
        view.endPress(inside: true)
        #expect(log.events == ["terms", "policy long", "text"])
    }

    @Test func suppressHighlightingSkipsTheHighlight() async throws {
        let log = EventLog()
        let text = UltraTextNode(spans: [TextSpan("link", onPress: log.handler("link"))])
        text.suppressHighlighting = true
        let hosted = Hosted(UltraNode(style: styled { $0.alignItems = .flexStart }, children: [text]))
        await hosted.settle()
        let view = try #require(text.view as? NodeView)
        let rect = try #require(view.props?.text?.links.first?.rects.first)
        _ = view.beginPress(at: CGPoint(x: rect.midX, y: rect.midY))
        #expect(view.layer.sublayers?.contains { $0 is CAShapeLayer } != true)
        view.endPress(inside: true)
        #expect(log.events == ["link"])
    }
}
#endif
