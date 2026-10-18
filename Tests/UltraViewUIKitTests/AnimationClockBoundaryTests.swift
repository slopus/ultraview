#if canImport(UIKit)
import UIKit
import QuartzCore
import Testing
@testable import UltraList

@MainActor
@Suite(.serialized) struct AnimationClockBoundaryTests {
    @Test(arguments: [AnimationOwner.row("row"), .viewport])
    func replacingAnAnimationRejectsThePreviousGenerationsOrigin(owner: AnimationOwner) async throws {
        let window = makeWindow(), host = UIView(frame: .init(x: 0, y: 0, width: 100, height: 400))
        window.addSubview(host); window.isHidden = false
        defer { window.isHidden = true }
        let controller = AnimationController()
        controller.referenceLayer = host.layer
        controller.bind(owner, layer: host.layer)
        let property: AnimatedProperty = owner == .viewport ? .viewportOffset : .positionY
        let key = ListAnimationModel.Key(owner, property)
        controller.replace(owner, property, from: 100, to: 0, at: controller.now,
                           transition: .init(duration: 1, curve: .linear))
        let previous = try #require(controller.model.tracks[key])
        try await flush()
        #expect(controller.clockOrigin(key, generation: previous.generation) != nil)
        controller.replace(owner, property, from: 150, to: 0, at: controller.now,
                           transition: .init(duration: 1, curve: .linear))
        let replacement = try #require(controller.model.tracks[key])
        try await flush()
        #expect(replacement.generation != previous.generation)
        #expect(controller.clockOrigin(key, generation: replacement.generation) != nil)
        #expect(controller.clockOrigin(key, generation: previous.generation) == nil,
                "a stale continuation witness adopted the replacement's native origin")
        #expect(controller.clockOrigin(key, generation: previous.generation, fallback: previous.startTime) == previous.startTime)
    }

    @Test func aCarryWithoutOwnMovementStillJoinsItsSlotFromThePresentedPosition() async throws {
        let window = makeWindow(), host = UIView(frame: .init(x: 0, y: 0, width: 100, height: 500))
        window.addSubview(host); window.isHidden = false
        defer { window.isHidden = true }
        host.layer.speed = 0; host.layer.timeOffset = 100
        let row = CALayer()
        row.anchorPoint = .zero; row.position = .init(x: 0, y: 400)
        row.bounds = .init(x: 0, y: 0, width: 100, height: 100)
        host.layer.addSublayer(row)
        let controller = AnimationController(), owner = AnimationOwner.row("carry")
        controller.referenceLayer = host.layer; controller.bind(owner, layer: row)
        let clock = AnimationTrack(generation: 1, from: -100, to: 0, startTime: 100,
                                   transition: .init(duration: 1, curve: .linear))
        controller.setPositionLayers(owner, [.init(source: .height("source"), track: clock, origin: 100)])
        #expect(controller.model.tracks[.init(owner, .positionY)] == nil)
        controller.joinPosition(owner, shown: 350, target: 400, at: 100)
        try await flush()
        for (phase, expected) in [(0.0, 350.0), (0.5, 375.0), (1.0, 400.0)] {
            host.layer.timeOffset = 100 + phase
            try await flush()
            let shown = try #require(row.presentation())
            #expect(abs(shown.position.y - expected) <= 0.5,
                    "a carry with only follower clocks jumped when it joined its slot")
        }
    }

    private func flush() async throws {
        CATransaction.flush(); try await Task.sleep(for: .milliseconds(35))
    }
}
#endif