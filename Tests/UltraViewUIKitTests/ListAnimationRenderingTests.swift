#if canImport(UIKit)
import UIKit
import QuartzCore
import Testing
@testable import UltraList

@MainActor
@Suite(.serialized) struct ListAnimationRenderingTests {
    @Test func pausedLayerMatchesAnalyticCurvesIncludingScaledSprings() async throws {
        let window = makeWindow()
        window.frame = .init(x: 0, y: 0, width: 320, height: 400)
        let host = UIView(frame: window.bounds)
        window.addSubview(host); window.isHidden = false
        defer { window.isHidden = true }
        let transitions: [ListTransition] = [
            .init(duration: 0.3, curve: .linear), .easeInOut(0.4), .uiKitScroll(),
            .spring(0.4), .spring(0.5), .spring(0.3832).scaled(by: 3), .spring(0.7, damping: 22), .smoothDeceleration().scaled(by: 2),
            .keyboard(0.25), .keyboard(0.4),
        ]
        for transition in transitions {
            let layer = CALayer()
            layer.anchorPoint = .zero; layer.position = .zero
            layer.bounds = .init(x: 0, y: 0, width: 100, height: 200)
            layer.backgroundColor = UIColor.red.cgColor
            layer.speed = 0; layer.timeOffset = 1
            host.layer.addSublayer(layer)
            let track = AnimationTrack(generation: 1, from: 100, to: 200, startTime: 1, transition: transition)
            let animation = AnimationController.compile(.height, track: track)
            animation.beginTime = 1
            layer.add(animation, forKey: "height")
            for phase in [0.1, 0.3, 0.5, 0.8] {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                layer.timeOffset = 1 + phase * transition.duration
                CATransaction.commit(); CATransaction.flush()
                try await Task.sleep(for: .milliseconds(35))
                let presentation = try #require(layer.presentation())
                let expected = track.value(at: 1 + phase * transition.duration)
                #expect(abs(presentation.bounds.height - expected) < 0.2, "curve \(transition.curve), phase \(phase), got \(presentation.bounds.height), expected \(expected)")
            }
            layer.removeFromSuperlayer()
        }
    }
    @Test func equalEndpointCompletionAndRetargetRejectStaleGeneration() async {
        let layer = CALayer(), controller = AnimationController()
        controller.referenceLayer = layer; controller.bind(.row("a"), layer: layer)
        var oldCompletions = 0, nextCompletions = 0
        let time = controller.now
        controller.replace(.row("a"), .opacity, from: 0, to: 0, at: time, transition: .easeInOut(0.03)) { oldCompletions += 1 }
        controller.replace(.row("a"), .opacity, from: 0, to: 0, at: time, transition: .easeInOut(0.1)) { nextCompletions += 1 }
        try? await Task.sleep(for: .milliseconds(60))
        #expect(oldCompletions == 0 && nextCompletions == 0)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(oldCompletions == 0 && nextCompletions == 1)
        #expect(!controller.model.hasTracks(.row("a")))
    }
    @Test func viewportSamplesRenderOnTheirClockAndLeaveRowSizesBasic() async throws {
        let window = makeWindow(), host = UIView(frame: .init(x: 0, y: 0, width: 100, height: 200))
        window.addSubview(host); window.isHidden = false
        defer { window.isHidden = true }
        let curve = ViewportCurve(progress: [0, 0, 0.25, 0.75, 1, 1])
        let transition = ListTransition(duration: 0.5, curve: .linear, viewportCurve: curve).scaled(by: 2)
        var model = ListAnimationModel()
        let viewportTrack = model.replace(.viewport, .viewportOffset, from: 100, to: 0, at: 1, transition: transition)
        let rowTrack = model.replace(.row("a"), .height, from: 100, to: 200, at: 1, transition: transition)
        let track = try #require(viewportTrack), row = try #require(rowTrack)
        #expect(AnimationController.compile(.height, track: row) is CABasicAnimation)
        let animation = AnimationController.compile(.viewportOffset, track: track)
        #expect(animation is CAKeyframeAnimation)
        host.layer.speed = 0; host.layer.timeOffset = 1
        animation.beginTime = 1
        host.layer.add(animation, forKey: "viewport")
        for phase in [0.1, 0.3, 0.5, 0.7, 0.9] {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            host.layer.timeOffset = 1 + phase
            CATransaction.commit(); CATransaction.flush()
            try await Task.sleep(for: .milliseconds(35))
            let shown = try #require(host.layer.presentation())
            #expect(abs(shown.bounds.origin.y - track.value(at: 1 + phase)) < 0.2)
        }
    }
}
#endif