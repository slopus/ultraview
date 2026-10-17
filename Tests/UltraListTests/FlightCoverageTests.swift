import Testing
@testable import UltraList

@Suite struct FlightCoverageTests {
    @Test func intervalIncludesAnInteriorBounceAndInterpolatedEnds() {
        let trajectory = ScrollTrajectory(samples: [
            .init(time: 0, offset: 0, velocity: 0),
            .init(time: 0.1, offset: 100, velocity: 0),
            .init(time: 0.2, offset: 20, velocity: 0),
            .init(time: 0.4, offset: 60, velocity: 0),
        ])
        #expect(trajectory.extent(from: 0.05, through: 0.3) == 20...100)
        let flight = ScrollFlight(trajectory: trajectory, beginTime: 5, coordinateShift: 1_000)
        #expect(flight.coveredOffsets(at: 5.1, horizon: 0.2) == 1_020...1_100)
        #expect(flight.coveredOffsets(at: 6, horizon: 0.3) == 1_060...1_060)
    }
    @Test(arguments: [-1.0, 1.0]) func directionalBandCoversTheWholeInterval(direction: Double) {
        let offset = 1_000.0, end = offset + direction * 500
        var window = ListWindow(rows: (10..<16).map { .init(index: $0, y: Double($0) * 100, height: 100) })
        window.rebalance(count: 100, offsetInFrameSpace: offset, viewportHeight: 400, margin: 100,
            coveredOffsets: min(offset, end)...max(offset, end), maximumAdditionalRows: 64,
            measure: { _ in (100, 0, 0) })
        #expect(window.minY <= min(offset, end) - 100)
        #expect(window.maxY >= max(offset, end) + 500)
        #expect(zip(window.rows, window.rows.dropFirst()).allSatisfy { $0.index + 1 == $1.index && $0.bandBottom == $1.bandTop })
    }
    @Test func budgetBoundsWorkEvenForZeroHeightRowsAndStopsAtMissingMeasurements() {
        var window = ListWindow(rows: [.init(index: 100, y: 1_000, height: 100)])
        var calls = 0
        window.rebalance(count: 10_000, offsetInFrameSpace: 1_000, viewportHeight: 400,
            coveredOffsets: 1_000...9_000, maximumAdditionalRows: 8) { _ in calls += 1; return (0, 0, 0) }
        #expect(calls == 8 && window.rows.count == 9)
        var missing = ListWindow(rows: [.init(index: 0, y: 0, height: 100)])
        missing.rebalance(count: 100, offsetInFrameSpace: 0, viewportHeight: 400,
            coveredOffsets: 0...1_000, maximumAdditionalRows: 64) { index in index < 3 ? (100, 0, 0) : nil }
        #expect(missing.range == 0..<3)
    }
}