import Foundation

public struct AttachmentMap: Sendable, Equatable {
    public var low: Double
    public var high: Double
    public var height: Double
    public var edge: BoundaryEdge
    public var floating: Bool
    public var screenAnchor: Double
    public var contentBase: Double
    public var partners: [AttachmentMap] = []
    public var gap: Double = 0
    public init(low: Double, high: Double, height: Double, edge: BoundaryEdge, floating: Bool, screenAnchor: Double, contentBase: Double) {
        self.low = low; self.high = high; self.height = height; self.edge = edge
        self.floating = floating; self.screenAnchor = screenAnchor; self.contentBase = contentBase
    }
    public var breakpoints: [Double] { [low + contentBase - screenAnchor, high + contentBase - screenAnchor].sorted() }
    public func ownPosition(offset: Double) -> Double {
        guard floating else { return edge == .top ? low : high }
        let anchor = screenAnchor + offset - contentBase
        return edge == .top ? min(max(anchor, low), high) : max(min(anchor, high), low)
    }
    public func position(offset: Double) -> Double {
        var result = ownPosition(offset: offset)
        for _ in 0...partners.count {
            var next = result
            for partner in partners {
                let y = partner.ownPosition(offset: offset)
                if y < next + height && y + partner.height > next { next = min(next, y - gap) }
            }
            next = max(low, next)
            if next == result { break }; result = next
        }
        return result
    }
    public func stickDistance(offset: Double) -> Double {
        let raw = edge == .top ? position(offset: offset) - low : high - position(offset: offset)
        let naturalOverlap = partners.contains { abs($0.high + $0.height - high - height) < 1e-6 }
        return raw - (naturalOverlap ? gap : 0)
    }
    public func flightValues(_ flight: ScrollFlight) -> [Double] {
        let settled = position(offset: flight.settledOffset)
        return flight.trajectory.samples.map { position(offset: $0.offset + flight.coordinateShift) - settled }
    }
}

public struct AttachmentRun: Sendable, Equatable {
    public var key: String
    public var serial: UInt64
    public var members: Range<Int>
    public var identities: [String]
    public var edge: BoundaryEdge
    public var startsRun: Bool
    public var endsRun: Bool
}

public enum AttachmentRuns {
    /// Matching witnesses preserve one prior serial on a split or merge.
    public static func resolve(identities: [String], loaded: Range<Int>, keys: (Int) -> [String], edge: (String, Int) -> BoundaryEdge, combines: (String, Int, Int) -> Bool, prior: [AttachmentRun], nextSerial: inout UInt64) -> [AttachmentRun] {
        var pending: [AttachmentRun] = []
        func continues(_ key: String, _ index: Int) -> Bool {
            index > 0 && index < identities.count && keys(index - 1).contains(key) && keys(index).contains(key) && combines(key, index - 1, index)
        }
        for index in loaded {
            for key in keys(index).sorted() {
                if index > loaded.lowerBound && continues(key, index) { continue }
                var end = index + 1
                while end < loaded.upperBound && continues(key, end) { end += 1 }
                pending.append(.init(key: key, serial: 0, members: index..<end, identities: Array(identities[index..<end]), edge: edge(key, index), startsRun: !continues(key, index), endsRun: !continues(key, end)))
            }
        }
        for index in pending.indices {
            let run = pending[index]
            let candidates = prior.compactMap { previous -> (UInt64, Int)? in
                guard previous.key == run.key else { return nil }
                let ordered = previous.edge == .top ? previous.identities : previous.identities.reversed().map { $0 }
                guard let witness = ordered.first(where: { identities.contains($0) }),
                      let newIndex = identities.firstIndex(of: witness), run.members.contains(newIndex) else { return nil }
                return (previous.serial, newIndex)
            }
            if let chosen = candidates.min(by: { run.edge == .top ? $0.1 < $1.1 : $0.1 > $1.1 }) { pending[index].serial = chosen.0 }
            else { nextSerial += 1; pending[index].serial = nextSerial }
        }
        return pending
    }
}