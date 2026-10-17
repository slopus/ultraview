import Foundation
import Testing
@testable import UltraList

@Suite struct AxisLockTests {
    @Test func staysUndecidedInsideTheSlopAndPicksTheDominantAxis() {
        #expect(AxisLock.decide(dx: 6, dy: 8) == nil)
        #expect(AxisLock.decide(dx: 0, dy: 10) == nil)
        #expect(AxisLock.decide(dx: 0, dy: 10.001) == .vertical)
        #expect(AxisLock.decide(dx: 9, dy: -5) == .horizontal)
        #expect(AxisLock.decide(dx: -11, dy: 2) == .horizontal)
        #expect(AxisLock.decide(dx: 3, dy: -11) == .vertical)
        // A tie belongs to the list's own vertical axis.
        #expect(AxisLock.decide(dx: 8, dy: 8) == .vertical)
        #expect(AxisLock.decide(dx: -8, dy: 8) == .vertical)
    }
    @Test func decidesOncePerGesture() {
        var lock = AxisLock()
        #expect(lock.update(dx: 4, dy: 1) == nil)
        #expect(lock.update(dx: 12, dy: 3) == .horizontal)
        // A later vertical run doesn't change the decision.
        #expect(lock.update(dx: 12, dy: 300) == .horizontal)
        #expect(lock.axis == .horizontal)
        var forced = AxisLock()
        #expect(forced.force(dx: 1, dy: 2) == .vertical)
        #expect(forced.update(dx: 50, dy: 0) == .vertical)
    }
    @Test func diagonalDragsSplitAtFortyFiveDegrees() {
        for degrees in stride(from: 0.0, through: 360.0, by: 5) {
            let angle = degrees * .pi / 180, dx = 20 * cos(angle), dy = 20 * sin(angle)
            let expected: GestureAxis = abs(dx) > abs(dy) ? .horizontal : .vertical
            #expect(AxisLock.decide(dx: dx, dy: dy) == expected, "\(degrees)°")
        }
    }
}

@Suite struct SwipeRevealLayoutTests {
    let threeButtons = SwipeRevealLayout(widths: [76, 76, 60], rowWidth: 390, allowsFullSwipe: true)

    @Test func openWidthAndFullSwipeThreshold() {
        #expect(threeButtons.openWidth == 212)
        // max(212 + 48, 390 × 0.55) = max(260, 214.5)
        #expect(threeButtons.fullSwipeThreshold == 260)
        let one = SwipeRevealLayout(widths: [76], rowWidth: 390, allowsFullSwipe: true)
        #expect(one.fullSwipeThreshold == 390 * 0.55)
        #expect(SwipeRevealLayout(widths: [76], rowWidth: 390, allowsFullSwipe: false).fullSwipeThreshold == nil)
        // Too many buttons for the row: no room for a full swipe.
        #expect(SwipeRevealLayout(widths: [200, 200], rowWidth: 390, allowsFullSwipe: true).fullSwipeThreshold == nil)
        #expect(SwipeRevealLayout(widths: [], rowWidth: 390, allowsFullSwipe: true).fullSwipeThreshold == nil)
    }
    @Test func tracksOneToOneUpToItsLimitThenRubberBands() {
        for value in stride(from: 0.0, through: 390, by: 13) {
            #expect(threeButtons.displayed(value) == value)
        }
        #expect(threeButtons.displayed(-30) == 0)
        let past = threeButtons.displayed(490)
        // 390 × (1 − 1 / (1 + 0.55 × 100 / 390))
        #expect(abs(past - (390 + 390 * (1 - 1 / (1 + 0.55 * 100 / 390)))) < 1e-12)
        #expect(past > 390 && past < 490)
        let noFull = SwipeRevealLayout(widths: [76, 76], rowWidth: 390, allowsFullSwipe: false)
        #expect(noFull.displayed(152) == 152)
        #expect(noFull.displayed(200) < 200 && noFull.displayed(200) > 152)
        for value in stride(from: 0.0, through: 900, by: 37) {
            #expect(abs(threeButtons.proposed(threeButtons.displayed(value)) - value) < 1e-6)
            #expect(abs(noFull.proposed(noFull.displayed(value)) - value) < 1e-6)
        }
        #expect(SwipeRevealLayout(widths: [], rowWidth: 390, allowsFullSwipe: true).displayed(50) == 0)
    }
    @Test func spansShareTheRevealInProportionAndStayOnTheEdge() {
        let spans = threeButtons.spans(reveal: 106, expanded: false)
        #expect(spans == [0...38, 38...76, 76...106])
        let open = threeButtons.spans(reveal: 212, expanded: false)
        #expect(open == [0...76, 76...152, 152...212])
        let expanded = threeButtons.spans(reveal: 300, expanded: true)
        #expect(expanded[0] == 0...300)
        #expect(expanded[1] == (300.0 * 76 / 212)...(300.0 * 152 / 212))
        for reveal in stride(from: 0.0, through: 420, by: 7) {
            let spans = threeButtons.spans(reveal: reveal, expanded: false)
            #expect(spans.first?.lowerBound == 0)
            #expect(abs((spans.last?.upperBound ?? -1) - reveal) < 1e-9)
            for (a, b) in zip(spans, spans.dropFirst()) { #expect(a.upperBound == b.lowerBound) }
        }
    }
    @Test func spansAreAffineInTheReveal() {
        // One spring on the reveal moves every button consistently only if each
        // edge is a fixed multiple of it.
        let a = threeButtons.spans(reveal: 50, expanded: false), b = threeButtons.spans(reveal: 150, expanded: false)
        let c = threeButtons.spans(reveal: 100, expanded: false)
        for i in 0..<3 {
            #expect(abs((a[i].lowerBound + b[i].lowerBound) / 2 - c[i].lowerBound) < 1e-12)
            #expect(abs((a[i].upperBound + b[i].upperBound) / 2 - c[i].upperBound) < 1e-12)
        }
    }
    @Test func targets() {
        #expect(threeButtons.target(.closed) == 0)
        #expect(threeButtons.target(.open) == 212)
        #expect(threeButtons.target(.fullSwipe) == 390)
        #expect(threeButtons.isExpanded(259.99) == false)
        #expect(threeButtons.isExpanded(260))
    }
}

@Suite struct SwipeReleaseTests {
    @Test func exactOutcomes() {
        #expect(SwipeRelease.decide(reveal: 0, velocity: 0, openWidth: 152, fullSwipeThreshold: 260) == .closed)
        #expect(SwipeRelease.decide(reveal: 75.9, velocity: 0, openWidth: 152, fullSwipeThreshold: 260) == .closed)
        #expect(SwipeRelease.decide(reveal: 76, velocity: 0, openWidth: 152, fullSwipeThreshold: 260) == .open)
        // A flick opens from a short reveal: 20 + 500 × 0.12 = 80.
        #expect(SwipeRelease.decide(reveal: 20, velocity: 500, openWidth: 152, fullSwipeThreshold: 260) == .open)
        // A flick back closes a long one: 140 − 600 × 0.12 = 68.
        #expect(SwipeRelease.decide(reveal: 140, velocity: -600, openWidth: 152, fullSwipeThreshold: 260) == .closed)
        #expect(SwipeRelease.decide(reveal: 260, velocity: -3000, openWidth: 152, fullSwipeThreshold: 260) == .fullSwipe)
        #expect(SwipeRelease.decide(reveal: 259, velocity: 3000, openWidth: 152, fullSwipeThreshold: 260) == .open)
        #expect(SwipeRelease.decide(reveal: 400, velocity: 0, openWidth: 152, fullSwipeThreshold: nil) == .open)
        #expect(SwipeRelease.decide(reveal: 400, velocity: 0, openWidth: 0, fullSwipeThreshold: nil) == .closed)
    }
    @Test func monotoneInDistanceAndVelocity() {
        let reveals = stride(from: 0.0, through: 420, by: 3).map { $0 }
        let velocities = stride(from: -4000.0, through: 4000, by: 125).map { $0 }
        for threshold in [nil, 390 * 0.55, 260.0] as [Double?] {
            for velocity in velocities {
                var previous = SwipeOutcome.closed
                for reveal in reveals {
                    let outcome = SwipeRelease.decide(reveal: reveal, velocity: velocity, openWidth: 152, fullSwipeThreshold: threshold)
                    #expect(outcome >= previous); previous = outcome
                }
            }
            for reveal in reveals {
                var previous = SwipeOutcome.closed
                for velocity in velocities {
                    let outcome = SwipeRelease.decide(reveal: reveal, velocity: velocity, openWidth: 152, fullSwipeThreshold: threshold)
                    #expect(outcome >= previous); previous = outcome
                }
            }
        }
    }
}

@Suite struct SwipeMotionTests {
    @Test func listSpringIsCriticallyDampedAndLimitsVelocityAgainstOvershoot() throws {
        let spring = try #require(SwipeMotion.spring(for: .spring(0.5)))
        #expect(spring.stiffness == 555.027 && spring.damping == 47.118 && spring.speed == 1 && spring.duration == 0.5)
        // Toward the target at 20,000 pt/s from 212 pt away: limited to 212 × 23.559.
        let closing = SwipeMotion(from: -212, to: 0, velocity: 20_000, transition: .spring(0.5))
        #expect(abs(closing.velocity - 212 * 23.559) < 1e-9)
        let gentle = SwipeMotion(from: -212, to: 0, velocity: 600, transition: .spring(0.5))
        #expect(gentle.velocity == 600)
        // Away from the target is never limited.
        let away = SwipeMotion(from: -212, to: 0, velocity: -2000, transition: .spring(0.5))
        #expect(away.velocity == -2000)
        for motion in [closing, gentle, away, SwipeMotion(from: 0, to: -212, velocity: -9000, transition: .spring(0.5))] {
            let sign = motion.to - motion.from > 0 ? 1.0 : -1.0
            var time = 0.0
            while time <= motion.duration {
                // Never past the target.
                #expect((motion.value(at: time) - motion.to) * sign <= 1e-9, "\(motion) at \(time)")
                time += 1.0 / 240
            }
            #expect(motion.value(at: motion.duration) == motion.to)
            #expect(motion.value(at: 0) == motion.from)
            // Core Animation ends the spring at its duration; the last step is sub-pixel.
            #expect(abs(motion.value(at: motion.duration - 1e-9) - motion.to) < 0.03)
        }
        #expect(abs(closing.normalizedVelocity - 23.559) < 1e-9)
    }
    @Test func nonSpringCurvesStartAtRestAndFollowTheirCurve() {
        let motion = SwipeMotion(from: 0, to: 100, velocity: 900, transition: .easeInOut(0.3))
        #expect(motion.velocity == 0 && motion.normalizedVelocity == 0)
        #expect(abs(motion.value(at: 0.15) - 50) < 1e-9)
        #expect(motion.value(at: 0.3) == 100)
        #expect(SwipeMotion(from: 5, to: 9, velocity: 1, transition: .immediate).value(at: 0.001) == 9)
    }
    @Test func scaledSpringKeepsItsShape() throws {
        let slow = SwipeMotion(from: 0, to: 100, velocity: 400, transition: .spring(0.5).scaled(by: 2))
        let normal = SwipeMotion(from: 0, to: 100, velocity: 800, transition: .spring(0.5))
        #expect(abs(slow.duration - 1) < 1e-12)
        for step in 0...20 {
            let t = Double(step) / 40
            #expect(abs(slow.value(at: 2 * t) - normal.value(at: t)) < 1e-9)
        }
        let damped = try #require(SwipeMotion.spring(for: .spring(0.6, damping: 22)))
        #expect(damped.stiffness == 180 && damped.damping == 22)
    }
}

@Suite struct SwipeRegistryTests {
    @Test func atMostOneRowIsRevealed() {
        var registry = SwipeRegistry<String>()
        #expect(registry.begin("a") == nil)
        #expect(registry.active == "a")
        #expect(registry.begin("a") == nil)
        #expect(registry.begin("b") == "a")
        #expect(registry.active == "b")
        registry.settle("a", outcome: .closed)
        #expect(registry.active == "b")
        registry.settle("b", outcome: .open)
        #expect(registry.active == "b")
        registry.settle("b", outcome: .closed)
        #expect(registry.active == nil)
        _ = registry.begin("c"); registry.remove("c")
        #expect(registry.active == nil)
    }
    @Test func randomSequencesNeverRevealTwoRows() {
        var generator = SystemRandomNumberGenerator()
        var registry = SwipeRegistry<Int>()
        var open: Set<Int> = []
        for _ in 0..<2000 {
            let row = Int.random(in: 0..<5, using: &generator)
            switch Int.random(in: 0..<3, using: &generator) {
            case 0:
                if let closing = registry.begin(row) { open.remove(closing) }
                open.insert(row)
            case 1:
                let outcome = [SwipeOutcome.closed, .open, .fullSwipe].randomElement(using: &generator)!
                registry.settle(row, outcome: outcome)
                if outcome == .closed, registry.active != row { open.remove(row) }
            default:
                registry.remove(row); open.remove(row)
            }
            #expect(open.count <= 1)
            #expect(registry.active.map { open.contains($0) } ?? open.isEmpty)
        }
    }
}

@Suite struct HorizontalListGeometryTests {
    @Test func transposedAndTurnedFrames() {
        // A card 150 long at offset 40 in a list 120 tall on a 390-wide screen.
        let ltr = HorizontalListGeometry.screenRect(x: 0, y: 40, width: 120, height: 150, length: 390, rightToLeft: false)
        #expect(ltr == (40, 0, 150, 120))
        let rtl = HorizontalListGeometry.screenRect(x: 0, y: 40, width: 120, height: 150, length: 390, rightToLeft: true)
        #expect(rtl == (200, 0, 150, 120))
        // Insets across the list move cards down the screen.
        let inset = HorizontalListGeometry.screenRect(x: 8, y: 0, width: 104, height: 100, length: 390, rightToLeft: false)
        #expect(inset == (0, 8, 100, 104))
    }
}
