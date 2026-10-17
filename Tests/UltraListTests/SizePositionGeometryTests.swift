import Testing
@testable import UltraList

@Suite struct SizePositionGeometryTests {
    @Test func topAnchoringFollowsOnlyPrecedingHeights() {
        let geometry = SizePositionGeometry(anchor: 0, anchorsTop: true, pinsAnchorBottom: false, visibleHeight: 600)
        #expect(geometry.coefficient(source: 1, row: 0, from: 100, to: 200, ownPlacement: 0) == 0)
        #expect(geometry.coefficient(source: 1, row: 1, from: 100, to: 200, ownPlacement: 0) == 0)
        #expect(geometry.coefficient(source: 1, row: 1, from: 100, to: 200, ownPlacement: 1) == 1)
        #expect(geometry.coefficient(source: 1, row: 2, from: 100, to: 200, ownPlacement: 0) == 1)
    }

    @Test func growthBeforeAnAnchorMovesItsEarlierRows() {
        let geometry = SizePositionGeometry(anchor: 2, anchorsTop: false, pinsAnchorBottom: false, visibleHeight: 600)
        #expect(geometry.coefficient(source: 1, row: 0, from: 100, to: 200, ownPlacement: 0) == -1)
        #expect(geometry.coefficient(source: 1, row: 1, from: 100, to: 200, ownPlacement: 0) == -1)
        #expect(geometry.coefficient(source: 1, row: 1, from: 100, to: 200, ownPlacement: 1) == 0)
        #expect(geometry.coefficient(source: 1, row: 2, from: 100, to: 200, ownPlacement: 0) == 0)
        #expect(geometry.coefficient(source: 1, row: 3, from: 100, to: 200, ownPlacement: 0) == 0)
    }

    @Test(arguments: [(100.0, 200.0, -1.0), (400, 500, 0), (200, 400, -0.5), (400, 200, -0.5)])
    func pinnedHeightUsesTheBoundaryChange(from: Double, to: Double, expected: Double) {
        let geometry = SizePositionGeometry(anchor: 2, anchorsTop: false, pinsAnchorBottom: true, visibleHeight: 600)
        #expect(geometry.coefficient(source: 2, row: 2, from: from, to: to, ownPlacement: 0) == expected)
        #expect(geometry.coefficient(source: 2, row: 2, from: from, to: to, ownPlacement: 1) == expected + 1)
        #expect(geometry.coefficient(source: 2, row: 3, from: from, to: to, ownPlacement: 0) == expected + 1)
    }

    @Test(arguments: [false, true]) func everySizeContributionKeepsAdjacentRowsTouching(pinned: Bool) {
        let geometry = SizePositionGeometry(anchor: 2, anchorsTop: false, pinsAnchorBottom: pinned, visibleHeight: 600)
        for source in 0..<5 {
            for upper in 0..<4 {
                let first = geometry.coefficient(source: source, row: upper, from: 200, to: 400, ownPlacement: 0)
                let next = geometry.coefficient(source: source, row: upper + 1, from: 200, to: 400, ownPlacement: 0)
                #expect(next - first == (source == upper ? 1 : 0))
            }
        }
    }
}