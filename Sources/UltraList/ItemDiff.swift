/// Stable identities are matched in linear time. Moves are the complement of a longest increasing subsequence.
public struct ItemDiff: Sendable, Equatable {
    public struct Move: Sendable, Equatable {
        public var old: Int
        public var new: Int
    }
    public var survivors: [Int: Int]
    public var inserts: [Int]
    public var deletes: [Int]
    public var moves: [Move]
    public func survivingIndex(for old: Int) -> Int? { survivors[old] ?? moves.first(where: { $0.old == old })?.new }
    public init<ID: Hashable & Sendable>(old: [ID], new: [ID]) {
        precondition(Set(old).count == old.count && Set(new).count == new.count, "row identities must be unique")
        let lookup = Dictionary(uniqueKeysWithValues: new.enumerated().map { ($0.element, $0.offset) })
        let pairs = old.enumerated().compactMap { index, id in lookup[id].map { (old: index, new: $0) } }
        var tails: [Int] = [], predecessors = Array(repeating: -1, count: pairs.count)
        for index in pairs.indices {
            var low = 0, high = tails.count
            while low < high {
                let mid = (low + high) / 2
                if pairs[tails[mid]].new < pairs[index].new { low = mid + 1 } else { high = mid }
            }
            if low > 0 { predecessors[index] = tails[low - 1] }
            if low == tails.count { tails.append(index) } else { tails[low] = index }
        }
        var kept = Set<Int>(), cursor = tails.last ?? -1
        while cursor >= 0 { kept.insert(cursor); cursor = predecessors[cursor] }
        survivors = [:]; moves = []
        for index in pairs.indices {
            if kept.contains(index) { survivors[pairs[index].old] = pairs[index].new }
            else { moves.append(.init(old: pairs[index].old, new: pairs[index].new)) }
        }
        let oldLookup = Set(old)
        inserts = new.indices.filter { !oldLookup.contains(new[$0]) } + moves.map(\.new)
        deletes = old.indices.filter { lookup[old[$0]] == nil } + moves.map(\.old)
        inserts.sort(); deletes.sort(); moves.sort { $0.new < $1.new }
    }
}