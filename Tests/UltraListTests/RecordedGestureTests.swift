import Foundation
import Testing
@testable import UltraList

private final class FixtureBundle: NSObject {}

@Suite struct RecordedGestureTests {
    @Test(arguments: ["slow-drag", "medium-flick", "into-bottom", "overscroll"])
    func publicObservationsMatchBothReplayPaths(name: String) throws {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: FixtureBundle.self)
        #endif
        let url = try #require(bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        var recording = try JSONDecoder().decode(GestureRecording.self, from: Data(contentsOf: url))
        // The recorder establishes these public starting offsets before recording any callbacks.
        if recording.initialOffset == nil {
            switch name {
            case "into-bottom": recording.initialOffset = recording.edges.maximum! - 600
            case "overscroll": recording.initialOffset = recording.edges.maximum!
            default: recording.initialOffset = 0
            }
        }
        #expect(recording.frames.count > 20)
        #expect(recording.events.contains { $0.phase == .ended })
        if name == "into-bottom" {
            #expect(recording.initialOffset != nil)
            #expect(recording.frames.contains { $0.offset > recording.edges.maximum! })
            #expect(recording.frames.last?.offset == recording.edges.maximum)
        }
        let tolerance = name == "slow-drag" ? 1.0 : name == "overscroll" ? 4.0 : 3.0
        for events in [false, true] {
            let replay = recording.replay(events: events)
            let errors = zip(replay, recording.frames).enumerated().map { (index: $0.offset, delta: abs($0.element.0 - $0.element.1.offset)) }
            let worst = errors.max { $0.delta < $1.delta }!
            print("REPLAY \(name) events=\(events) maximum=\(worst.delta) frame=\(worst.index)")
            #expect(worst.delta <= tolerance)
        }
        var perturbed = recording
        perturbed.frames[recording.frames.count / 2].offset += 20
        #expect(perturbed.maximumDivergence(events: true) > 10)
    }
}