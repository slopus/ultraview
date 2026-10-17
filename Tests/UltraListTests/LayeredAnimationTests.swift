import Testing
@testable import UltraList

@Suite struct LayeredAnimationTests {
    private let a = AnimationOwner.row("a"), b = AnimationOwner.row("b"), c = AnimationOwner.row("c")
    private let linear = ListTransition(duration: 1, curve: .linear)
    private func require(_ value: AnimationTrack?) throws -> AnimationTrack { try #require(value) }

    @Test func followersKeepAHeightClockThroughALaterMove() throws {
        var model = ListAnimationModel()
        let height = try require(model.replace(a, .height, from: 100, to: 150, at: 0, transition: linear))
        model.setPositionLayer(b, source: .height("a"), track: height.residual(multipliedBy: 1))
        model.replace(a, .positionY, from: 40, to: 0, at: 0.5, transition: linear)
        model.replace(b, .positionY, from: 40, to: 0, at: 0.5, transition: linear)
        #expect(model.tracks[.init(a, .height)] == height)
        for step in 0...24 {
            let time = Double(step) / 16
            let upper = -40 + model.value(a, .positionY, at: time)
            let lower = 110 + model.value(b, .positionY, at: time)
            #expect(lower - upper == model.value(a, .height, at: time))
        }
    }

    @Test func twoSizeCurvesAndAMoveKeepBothSeams() throws {
        var model = ListAnimationModel()
        let first = try require(model.replace(a, .height, from: 100, to: 150, at: 0, transition: linear))
        let second = try require(model.replace(b, .height, from: 100, to: 125, at: 0.25, transition: .easeInOut(0.75)))
        model.setPositionLayer(b, source: .height("a"), track: first.residual(multipliedBy: 1))
        model.setPositionLayer(c, source: .height("a"), track: first.residual(multipliedBy: 1))
        model.setPositionLayer(c, source: .height("b"), track: second.residual(multipliedBy: 1))
        for owner in [a, b, c] { model.replace(owner, .positionY, from: 40, to: 0, at: 0.5, transition: linear) }
        for step in 0...24 {
            let time = Double(step) / 16
            let firstTop = -40 + model.value(a, .positionY, at: time)
            let secondTop = 110 + model.value(b, .positionY, at: time)
            let thirdTop = 235 + model.value(c, .positionY, at: time)
            #expect(abs(secondTop - firstTop - model.value(a, .height, at: time)) < 1e-9)
            #expect(abs(thirdTop - secondTop - model.value(b, .height, at: time)) < 1e-9)
        }
    }

    @Test func aMoveRetargetDoesNotFoldTheFollowerIntoIt() throws {
        var model = ListAnimationModel()
        let height = try require(model.replace(a, .height, from: 100, to: 150, at: 0, transition: linear))
        model.setPositionLayer(b, source: .height("a"), track: height.residual(multipliedBy: 1))
        model.replace(b, .positionY, from: 40, to: 0, at: 0, transition: linear)
        let before = model.value(b, .positionY, at: 0.5)
        let move = try require(model.transition(b, .positionY, old: 0, new: 40, at: 0.5, transition: linear))
        #expect(move.from == -20)
        #expect(40 + model.value(b, .positionY, at: 0.5) == before)
    }

    @Test func unchangedFollowersKeepTheirGenerationAndRejectOldCompletion() throws {
        var model = ListAnimationModel()
        let height = try require(model.replace(a, .height, from: 100, to: 150, at: 0, transition: linear))
        let initial = model.setPositionLayer(b, source: .height("a"), track: height.residual(multipliedBy: 1))
        #expect(model.setPositionLayer(b, source: .height("a"), track: height.residual(multipliedBy: 1)) == initial)
        let replacement = try require(model.transition(a, .height, old: 150, new: 175, at: 0.5, transition: linear))
        let next = model.setPositionLayer(b, source: .height("a"), track: replacement.residual(multipliedBy: 1))
        let completed = model.finish(.init(b, source: .height("a")), generation: initial.generation)
        #expect(!completed)
        #expect(model.tracks[.init(b, source: .height("a"))] == next)
    }

    @Test func removingOneSourceKeepsTheOtherSourceAndOwnMove() throws {
        var model = ListAnimationModel()
        let first = try require(model.replace(a, .height, from: 100, to: 150, at: 0, transition: linear))
        let second = try require(model.replace(b, .height, from: 100, to: 125, at: 0.25, transition: linear))
        model.setPositionLayer(c, source: .height("a"), track: first.residual(multipliedBy: 1))
        let kept = model.setPositionLayer(c, source: .height("b"), track: second.residual(multipliedBy: 1))
        let move = model.replace(c, .positionY, from: 40, to: 0, at: 0.5, transition: linear)
        #expect(model.removePositionLayers(c, except: [.height("b")]) == [.init(c, source: .height("a"))])
        #expect(model.tracks[.init(c, source: .height("b"))] == kept)
        #expect(model.tracks[.init(c, .positionY)] == move)
    }
}