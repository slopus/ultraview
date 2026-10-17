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
}
#endif