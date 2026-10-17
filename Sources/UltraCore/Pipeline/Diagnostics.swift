import Foundation
import Synchronization

/// Counts the pipeline's heavy work by thread, for tests and the demo's
/// overlay. Layout passes, text measurement and drawing all belong off the
/// main thread; debug builds also assert it.
public final class Diagnostics: Sendable {
    public static let shared = Diagnostics()

    private let passes = Atomic<Int>(0)
    private let passesOnMain = Atomic<Int>(0)
    private let measurements = Atomic<Int>(0)
    private let measurementsOnMain = Atomic<Int>(0)
    private let draws = Atomic<Int>(0)
    private let drawsOnMain = Atomic<Int>(0)

    public struct Counts: Sendable, Equatable {
        /// Layout passes (each runs Yoga over one tree).
        public var passes = 0
        public var passesOnMain = 0
        /// Text layouts computed (measuring and line breaking).
        public var measurements = 0
        public var measurementsOnMain = 0
        /// Bitmaps drawn.
        public var draws = 0
        public var drawsOnMain = 0

        public var mainThreadWork: Int {
            passesOnMain + measurementsOnMain + drawsOnMain
        }

        public static func - (lhs: Counts, rhs: Counts) -> Counts {
            Counts(
                passes: lhs.passes - rhs.passes,
                passesOnMain: lhs.passesOnMain - rhs.passesOnMain,
                measurements: lhs.measurements - rhs.measurements,
                measurementsOnMain: lhs.measurementsOnMain - rhs.measurementsOnMain,
                draws: lhs.draws - rhs.draws,
                drawsOnMain: lhs.drawsOnMain - rhs.drawsOnMain
            )
        }
    }

    public var counts: Counts {
        Counts(
            passes: passes.load(ordering: .relaxed),
            passesOnMain: passesOnMain.load(ordering: .relaxed),
            measurements: measurements.load(ordering: .relaxed),
            measurementsOnMain: measurementsOnMain.load(ordering: .relaxed),
            draws: draws.load(ordering: .relaxed),
            drawsOnMain: drawsOnMain.load(ordering: .relaxed)
        )
    }

    func recordPass() {
        record(passes, passesOnMain, "layout pass")
    }

    func recordMeasurement() {
        record(measurements, measurementsOnMain, "text measurement")
    }

    func recordDraw() {
        record(draws, drawsOnMain, "drawing")
    }

    private func record(_ total: borrowing Atomic<Int>, _ onMain: borrowing Atomic<Int>, _ what: StaticString) {
        total.add(1, ordering: .relaxed)
        if Thread.isMainThread {
            onMain.add(1, ordering: .relaxed)
            assertionFailure("\(what) on the main thread")
        }
    }
}
