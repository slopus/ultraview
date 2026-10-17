/// How one changing height contributes to a row's position around the anchor.
struct SizePositionGeometry: Sendable {
    var anchor: Int
    var anchorsTop: Bool
    var pinsAnchorBottom: Bool
    var visibleHeight: Double

    func coefficient(source: Int, row: Int, from: Double, to: Double, ownPlacement: Double) -> Double {
        var common = anchorsTop ? 0 : (source < anchor ? -1.0 : 0)
        if pinsAnchorBottom, source == anchor {
            let half = visibleHeight / 2
            if abs(to - from) > 1e-6 {
                common = ((max(0, to - half) - to) - (max(0, from - half) - from)) / (to - from)
            } else { common = to > half ? 0 : -1 }
        }
        return common + (source < row ? 1 : 0) + (source == row ? ownPlacement : 0)
    }
}