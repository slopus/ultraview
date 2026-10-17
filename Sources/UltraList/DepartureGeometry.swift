import Foundation

public enum BoundaryEdge: Sendable { case top, bottom }

/// Departures retain spatial witnesses even after their last view has faded.
public struct DepartureLedger: Sendable {
    public enum Witness: Sendable, Equatable {
        case unresolved
        case row(String, BoundaryEdge)
        case block(UInt64, BoundaryEdge)
    }
    public struct Block: Sendable {
        public var id: UInt64
        public var root: Double
        public var localTop: Double
        public var localBottom: Double
        public var edge: BoundaryEdge = .top
        public var witness: Witness = .unresolved
        public var viewportAnchored = false
        public var boundaryOpen = true
        public var members: Int
        public init(id: UInt64, root: Double, localTop: Double, localBottom: Double, members: Int) {
            self.id = id; self.root = root; self.localTop = localTop; self.localBottom = localBottom; self.members = members
        }
    }
    public private(set) var blocks: [UInt64: Block] = [:]
    public init() {}
    public mutating func insert(_ block: Block) { precondition(blocks[block.id] == nil); blocks[block.id] = block }
    @discardableResult
    public mutating func link(_ id: UInt64, to witness: Witness, edge: BoundaryEdge) -> Bool {
        guard var block = blocks[id] else { return false }
        if block.viewportAnchored, witness != .unresolved { return false }
        if case .block(let target, _) = witness {
            guard blocks[target] != nil, target != id else { return false }
            var seen: Set<UInt64> = [id], cursor = target
            while true {
                guard seen.insert(cursor).inserted else { return false }
                guard case .block(let next, _) = blocks[cursor]?.witness else { break }; cursor = next
            }
        }
        block.witness = witness; block.edge = edge; blocks[id] = block; return true
    }
    public func targets(rows: [String: ClosedRange<Double>]) -> [UInt64: Double] {
        var resolved: [UInt64: Double] = [:], visiting = Set<UInt64>()
        func solve(_ id: UInt64) -> Double {
            if let value = resolved[id] { return value }
            guard let block = blocks[id], visiting.insert(id).inserted else { return blocks[id]?.root ?? 0 }
            var boundary: Double?
            switch block.witness {
            case .unresolved: break
            case .row(let identity, let edge): boundary = rows[identity].map { edge == .top ? $0.lowerBound : $0.upperBound }
            case .block(let target, let edge):
                if let carrier = blocks[target] { boundary = solve(target) + (edge == .top ? carrier.localTop : carrier.localBottom) }
            }
            let value = boundary.map { $0 - (block.edge == .top ? block.localTop : block.localBottom) } ?? block.root
            visiting.remove(id); resolved[id] = value; return value
        }
        for id in blocks.keys.sorted() { _ = solve(id) }
        return resolved
    }
    public mutating func setRoot(_ id: UInt64, _ root: Double) { blocks[id]?.root = root }
    public mutating func seal(_ id: UInt64) { blocks[id]?.boundaryOpen = false }
    public mutating func promoteToViewport(_ id: UInt64, offset: Double) {
        guard var block = blocks[id] else { return }
        block.root -= offset; block.viewportAnchored = true; block.witness = .unresolved; blocks[id] = block
    }
    public mutating func shift(by delta: Double) {
        for id in blocks.keys where blocks[id]?.viewportAnchored == false { blocks[id]?.root += delta }
    }
    public mutating func finishMember(_ id: UInt64) { blocks[id]?.members -= 1 }
    public mutating func addMember(_ id: UInt64, localTop: Double, localBottom: Double) {
        guard var block = blocks[id] else { return }
        block.members += 1; block.localTop = min(block.localTop, localTop); block.localBottom = max(block.localBottom, localBottom)
        blocks[id] = block
    }
    public mutating func collect() -> [UInt64] {
        var removed: [UInt64] = []
        while let id = blocks.keys.sorted().first(where: { id in
            blocks[id]!.members <= 0 && !blocks.values.contains { if case .block(let target, _) = $0.witness { return target == id }; return false }
        }) { blocks.removeValue(forKey: id); removed.append(id) }
        return removed
    }
}

public enum CrossingPlanner {
    public struct Sample: Sendable {
        public var oldIndex: Int
        public var newIndex: Int
        public var oldY: Double
        public var newY: Double
        public init(oldIndex: Int, newIndex: Int, oldY: Double, newY: Double) { self.oldIndex = oldIndex; self.newIndex = newIndex; self.oldY = oldY; self.newY = newY }
    }
    public struct Endpoint: Sendable {
        public var identity: String
        public var oldIndex: Int
        public var newIndex: Int
        public var y: Double
        public var height: Double
        public var outgoing: Bool
        public var moved: Bool
        public init(identity: String, oldIndex: Int, newIndex: Int, y: Double, height: Double, outgoing: Bool, moved: Bool = false) {
            self.identity = identity; self.oldIndex = oldIndex; self.newIndex = newIndex; self.y = y; self.height = height; self.outgoing = outgoing; self.moved = moved
        }
    }
    public static func infer(_ endpoints: [Endpoint], samples: [Sample], safeRange: ClosedRange<Double>, anchorY: Double?) -> [String: Double] {
        let sorted = endpoints.sorted { ($0.outgoing ? $0.oldIndex : $0.newIndex) < ($1.outgoing ? $1.oldIndex : $1.newIndex) }
        var result: [String: Double] = [:], cursor = 0
        func below(_ e: Endpoint) -> Bool { e.y + e.height / 2 >= (anchorY ?? (safeRange.lowerBound + safeRange.upperBound) / 2) }
        func shared(_ e: Endpoint) -> Sample? {
            guard !e.moved else { return nil }
            return samples.filter { $0.newIndex - $0.oldIndex == e.newIndex - e.oldIndex }.min {
                let a = abs((e.outgoing ? $0.oldIndex : $0.newIndex) - (e.outgoing ? e.oldIndex : e.newIndex))
                let b = abs((e.outgoing ? $1.oldIndex : $1.newIndex) - (e.outgoing ? e.oldIndex : e.newIndex))
                return a == b ? $0.oldIndex < $1.oldIndex : a < b
            }
        }
        while cursor < sorted.count {
            let first = sorted[cursor]
            if let sample = shared(first) {
                result[first.identity] = first.y + (sample.newY - sample.oldY) * (first.outgoing ? 1 : -1)
                cursor += 1; continue
            }
            if first.moved {
                result[first.identity] = below(first) ? safeRange.upperBound : safeRange.lowerBound - first.height
                cursor += 1; continue
            }
            var end = cursor + 1
            while end < sorted.count {
                let previous = sorted[end - 1], next = sorted[end]
                guard !next.moved, next.outgoing == first.outgoing, next.oldIndex == previous.oldIndex + 1,
                      next.newIndex == previous.newIndex + 1, below(next) == below(first), shared(next) == nil else { break }
                end += 1
            }
            let last = sorted[end - 1]
            let shift = below(first) ? safeRange.upperBound - first.y : safeRange.lowerBound - last.y - last.height
            for item in sorted[cursor..<end] { result[item.identity] = item.y + shift }
            cursor = end
        }
        return result
    }
}

public enum ViewportTravel {
    public static func forward(target: Int, witness: Int?, hint: Bool? = nil) -> Bool { witness.map { target >= $0 } ?? hint ?? true }
    public static func carouselCorrection(oldStrip: ClosedRange<Double>, newStrip: ClosedRange<Double>, forward: Bool) -> Double {
        forward ? newStrip.lowerBound - oldStrip.upperBound : newStrip.upperBound - oldStrip.lowerBound
    }
}