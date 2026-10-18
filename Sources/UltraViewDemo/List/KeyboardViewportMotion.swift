import UltraView

/// Keyboard heights are signed overlaps with the chat view. The keyboard
/// can start below that view while the composer remains at its resting edge.
struct KeyboardViewportMotion: Sendable {
    var beginHeight: Double
    var endHeight: Double
    var restingHeight: Double

    func height(at physicalProgress: Double) -> Double {
        max(restingHeight, beginHeight + (endHeight - beginHeight) * physicalProgress)
    }

    func viewportCurve(physicalProgress: [Double]) -> ViewportCurve? {
        let begin = height(at: 0), end = height(at: 1), distance = end - begin
        guard abs(distance) > 0.5, physicalProgress.count >= 2,
              physicalProgress.first == 0, physicalProgress.last == 1 else { return nil }
        let progress = physicalProgress.map { (height(at: $0) - begin) / distance }
        return ViewportCurve(progress: progress)
    }
}