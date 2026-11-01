#if canImport(UIKit)
import Testing
import UIKit
@testable import UltraList

@MainActor
@Suite(.serialized) struct ScrollInputTests {
    @Test func scrollTypesMatchTheSystemAndMoveWithTheInputSurface() {
        let engine = PhysicsEngine(mode: .keyframe)
        defer { engine.teardown() }
        let types = engine.pan.allowedScrollTypesMask.union(engine.wheel.allowedScrollTypesMask)
        #expect(types == UIScrollView().panGestureRecognizer.allowedScrollTypesMask)
        #expect(engine.wheel.allowedTouchTypes.isEmpty)
        let surface = UIView()
        engine.attachInput(to: surface)
        #expect(engine.pan.view === surface)
        #expect(engine.wheel.view === surface)
    }

    @Test(arguments: [ScrollEngineMode.keyframe, .stepped])
    func wheelDistanceIsClampedAndNeverLaunchesMomentum(mode: ScrollEngineMode) {
        let engine = PhysicsEngine(mode: mode)
        defer { engine.teardown() }
        engine.setEdges(.init(minimum: -20, maximum: 1000))
        engine.setOffset(200)
        let wheel = WheelSample()
        wheel.sampleState = .began; wheel.distance = -40
        engine.wheeled(wheel)
        #expect(engine.offset == 240)
        wheel.sampleState = .changed; wheel.distance = -120
        engine.wheeled(wheel)
        #expect(engine.offset == 320)
        wheel.distance = -2000
        engine.wheeled(wheel)
        #expect(engine.offset == 1000)
        wheel.distance = 1000
        engine.wheeled(wheel)
        #expect(engine.offset == -20)
        wheel.sampleState = .ended
        engine.wheeled(wheel)
        #expect(!engine.decelerating)
        #expect(engine.activeFlight == nil)
        #expect(engine.host.layer.animationKeys()?.isEmpty ?? true)
    }

    @Test func wheelCatchesAFlightWithoutLeavingItsAnimationRunning() {
        let engine = PhysicsEngine(mode: .keyframe)
        defer { engine.teardown() }
        engine.setOffset(200)
        engine.beginMomentum(velocity: 3000)
        #expect(engine.activeFlight != nil)
        let wheel = WheelSample()
        wheel.sampleState = .began; wheel.distance = -40
        engine.wheeled(wheel)
        #expect(engine.offset >= 240)
        #expect(engine.activeFlight == nil)
        #expect(!engine.decelerating)
        #expect(engine.host.layer.animationKeys()?.isEmpty ?? true)
    }

    @Test(arguments: [UIEvent.EventType.hover, .transform, .presses])
    func unrelatedInputDoesNotCatchAFlight(type: UIEvent.EventType) {
        let engine = PhysicsEngine(mode: .keyframe)
        defer { engine.teardown() }
        engine.beginMomentum(velocity: 3000)
        let flight = engine.activeFlight
        let event = OtherInput(type: type)
        #expect(engine.gestureRecognizer(engine.pan, shouldReceive: event))
        #expect(engine.activeFlight == flight)
        #expect(engine.decelerating)
    }

    @Test func resizingAScrollHostKeepsItsFlight() throws {
        let scroll = UltraScrollView()
        defer { scroll.engine.teardown() }
        scroll.frame = .init(x: 0, y: 0, width: 1024, height: 1366)
        scroll.contentHeight = 100_000
        scroll.layoutIfNeeded()
        scroll.layer.speed = 0; scroll.layer.timeOffset = 100
        scroll.setScrollOffset(2000)
        scroll.beginMomentum(velocity: 3000)
        let flight = try #require(scroll.engine.activeFlight)
        for size in [CGSize(width: 1366, height: 1024), .init(width: 744, height: 1133),
                     .init(width: 1133, height: 744), .init(width: 600, height: 700)] {
            scroll.frame.size = size
            scroll.setNeedsLayout(); scroll.layoutIfNeeded()
            #expect(scroll.engine.activeFlight == flight)
            #expect(scroll.contentView.layer.animationKeys()?.isEmpty == false)
        }
        #expect(flight.offset(at: flight.beginTime + 0.5) > 2500)
    }
}

@MainActor
private final class WheelSample: UIPanGestureRecognizer {
    var sampleState = UIGestureRecognizer.State.possible
    var distance = 0.0
    override var state: UIGestureRecognizer.State {
        get { sampleState }
        set { sampleState = newValue }
    }
    override func translation(in view: UIView?) -> CGPoint { .init(x: 0, y: distance) }
    override func velocity(in view: UIView?) -> CGPoint { .init(x: 0, y: -100_000) }
}

@MainActor
private final class OtherInput: UIEvent {
    let inputType: UIEvent.EventType
    init(type: UIEvent.EventType) { inputType = type; super.init() }
    override var type: UIEvent.EventType { inputType }
}
#endif