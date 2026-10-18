/// The change in displacement between two surviving rows, using bounded
/// intervals in the old and new order. Shared, unchanged bands cancel.
struct ContinuationField {
    struct Band: Sendable, Equatable {
        var height: Double
        var top: Double = 0
        var bottom: Double = 0
        var extent: Double { top + height + bottom }
    }

    static func delta(old: [String], new: [String], oldReference: Int, oldRow: Int,
                      newReference: Int, newRow: Int, limit: Int = 64,
                      oldBand: (String) -> Band?, newBand: (String) -> Band?,
                      referencePlacement: Double = 0, rowPlacement: Double = 0) -> Double? {
        guard abs(oldRow - oldReference) <= limit, abs(newRow - newReference) <= limit,
              old.indices.contains(oldReference), old.indices.contains(oldRow),
              new.indices.contains(newReference), new.indices.contains(newRow) else { return nil }
        var coefficients: [String: (old: Double, new: Double)] = [:]
        for index in min(oldReference, oldRow)..<max(oldReference, oldRow) {
            coefficients[old[index], default: (0, 0)].old += oldRow >= oldReference ? 1 : -1
        }
        for index in min(newReference, newRow)..<max(newReference, newRow) {
            coefficients[new[index], default: (0, 0)].new += newRow >= newReference ? 1 : -1
        }
        var result = 0.0
        for (identity, coefficient) in coefficients {
            let before = oldBand(identity), after = newBand(identity)
            if coefficient.old == coefficient.new, before == nil, after == nil { continue }
            guard coefficient.old == 0 || before != nil, coefficient.new == 0 || after != nil else { return nil }
            result += coefficient.old * (before?.extent ?? 0) - coefficient.new * (after?.extent ?? 0)
        }
        // Prefixes above locate band tops. Rows start after their top reserve.
        for (beforeID, afterID, coefficient, placement) in [
            (old[oldRow], new[newRow], 1.0, rowPlacement),
            (old[oldReference], new[newReference], -1.0, referencePlacement)
        ] {
            let before = oldBand(beforeID), after = newBand(afterID)
            if before == nil, after == nil { continue }
            guard let before, let after else { return nil }
            result += coefficient * (before.top - after.top + placement * (before.height - after.height))
        }
        return result
    }
}