import Testing
@testable import UltraList

struct ContinuationFieldTests {
    private let band = ContinuationField.Band(height: 100)

    @Test func disjointSegmentsWithEqualIndexChangesKeepTheirOwnBoundaries() {
        let old = ["a", "b", "c", "d", "e", "f", "g"]
        let new = ["a", "c", "d", "e", "f", "b", "g"]
        #expect(delta(old, new, "a", "c") == 100)
        #expect(delta(old, new, "f", "g") == -100)
        #expect(delta(old, new, "g", "f") == 100)
    }

    @Test func reservesAndTheRowsPlacementContributeToTheDifference() {
        let old = ["a", "b", "c"], new = ["a", "c"]
        let bands: [String: ContinuationField.Band] = [
            "a": .init(height: 100, top: 5, bottom: 7),
            "b": .init(height: 80, top: 11, bottom: 13),
            "c": .init(height: 100, top: 17, bottom: 19)
        ]
        #expect(ContinuationField.delta(old: old, new: new, oldReference: 0, oldRow: 2,
            newReference: 0, newRow: 1, oldBand: { bands[$0] }, newBand: { bands[$0] }) == 104)
        #expect(ContinuationField.delta(old: ["a", "c"], new: ["a", "c"], oldReference: 0, oldRow: 1,
            newReference: 0, newRow: 1,
            oldBand: { _ in .init(height: 100) }, newBand: { $0 == "a" ? .init(height: 240) : .init(height: 100) },
            referencePlacement: 0.5) == -70)
    }

    @Test func unknownUnchangedBandsCancelButUnknownMutationBoundariesDoNot() {
        #expect(delta(["a", "b", "c"], ["a", "b", "c"], "a", "c", known: []) == 0)
        #expect(delta(["a", "b", "c"], ["a", "c"], "a", "c", known: ["a", "c"]) == nil)
        let many = (0..<70).map(String.init)
        #expect(delta(many, many, "0", "69") == nil)
    }

    @Test func insertingAHeightHasTheOppositeDisplacementFromDeletingIt() {
        #expect(delta(["a", "c"], ["a", "b", "c"], "a", "c") == -100)
        #expect(delta(["a", "b", "c"], ["a", "c"], "a", "c") == 100)
    }

    private func delta(_ old: [String], _ new: [String], _ reference: String, _ row: String,
                       known: Set<String>? = nil) -> Double? {
        ContinuationField.delta(old: old, new: new,
            oldReference: old.firstIndex(of: reference)!, oldRow: old.firstIndex(of: row)!,
            newReference: new.firstIndex(of: reference)!, newRow: new.firstIndex(of: row)!,
            oldBand: { known?.contains($0) == false ? nil : band },
            newBand: { known?.contains($0) == false ? nil : band })
    }
}