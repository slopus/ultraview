import Foundation
import Synchronization

/// A width and revision identify one measurement. Old completions cannot reopen a stale frontier.
public struct MeasurementKey: Sendable, Hashable {
    public var identity: String
    public var revision: UInt64
    public var width: Double
    public var environment: UInt64
    public init(identity: String, revision: UInt64 = 0, width: Double, environment: UInt64 = 0) {
        self.identity = identity; self.revision = revision; self.width = width; self.environment = environment
    }
}

public final class MeasurementCache: Sendable {
    private struct State {
        var heights: [MeasurementKey: Double] = [:]
        var pending: Set<MeasurementKey> = []
        var generation: UInt64 = 0
    }
    private let state = Mutex(State())
    public init() {}
    public func height(for key: MeasurementKey) -> Double? { state.withLock { $0.heights[key] } }
    /// Returns a generation ticket only to the first requester.
    public func request(_ key: MeasurementKey) -> UInt64? {
        state.withLock { state in
            guard state.heights[key] == nil, state.pending.insert(key).inserted else { return nil }
            return state.generation
        }
    }
    @discardableResult
    public func complete(_ key: MeasurementKey, height: Double, ticket: UInt64) -> Bool {
        guard height.isFinite && height >= 0 else { return false }
        return state.withLock { state in
            guard ticket == state.generation, state.pending.remove(key) != nil else { return false }
            state.heights[key] = height; return true
        }
    }
    public func invalidate() { state.withLock { $0.generation += 1; $0.heights.removeAll(); $0.pending.removeAll() } }
    public func retain(identities: Set<String>) {
        state.withLock { state in
            state.heights = state.heights.filter { identities.contains($0.key.identity) }
            state.pending = state.pending.filter { identities.contains($0.identity) }
        }
    }
    /// Nearby rows come first, followed by the predicted direction of travel.
    public static func priority(count: Int, anchor: Int, direction: Int, limit: Int) -> [Int] {
        guard count > 0, limit > 0 else { return [] }
        var result: [Int] = [], radius = 0
        let anchor = min(max(0, anchor), count - 1), sign = direction < 0 ? -1 : 1
        while result.count < min(count, limit) {
            for candidate in radius == 0 ? [anchor] : [anchor + radius * sign, anchor - radius * sign] {
                if candidate >= 0 && candidate < count { result.append(candidate) }
                if result.count == min(count, limit) { break }
            }
            radius += 1
        }
        return result
    }
}

/// Coalesces dirty work without consuming it before a pass has accepted it.
public struct PassScheduler: Sendable {
    public private(set) var dirty: Set<String> = []
    public private(set) var scheduled = false
    public private(set) var animated = false
    public init() {}
    public mutating func mark(_ identity: String, animated: Bool) -> Bool {
        dirty.insert(identity); self.animated = self.animated || animated
        if scheduled { return false }; scheduled = true; return true
    }
    public mutating func beginFlush() { scheduled = false }
    public mutating func consume() -> Set<String> {
        let consumed = dirty; dirty.removeAll(); animated = false; return consumed
    }
}