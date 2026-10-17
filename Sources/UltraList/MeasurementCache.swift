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
    public enum Completion: Sendable, Equatable { case stored, stale, invalid }
    private struct State {
        var heights: [MeasurementKey: Double] = [:]
        var pending: [MeasurementKey: UInt64] = [:]
        var nextTicket: UInt64 = 0
    }
    private let state = Mutex(State())
    public init() {}
    public func height(for key: MeasurementKey) -> Double? { state.withLock { $0.heights[key] } }
    /// Returns a generation ticket only to the first requester.
    public func request(_ key: MeasurementKey) -> UInt64? {
        state.withLock { state in
            guard state.heights[key] == nil, state.pending[key] == nil else { return nil }
            state.nextTicket &+= 1
            state.pending[key] = state.nextTicket
            return state.nextTicket
        }
    }
    @discardableResult
    public func complete(_ key: MeasurementKey, height: Double, ticket: UInt64) -> Bool {
        store(key, height: height, ticket: ticket) == .stored
    }
    @discardableResult
    public func store(_ key: MeasurementKey, height: Double, ticket: UInt64) -> Completion {
        return state.withLock { state in
            guard state.pending[key] == ticket else { return .stale }
            guard height.isFinite && height >= 0 else { return .invalid }
            state.pending.removeValue(forKey: key)
            state.heights[key] = height; return .stored
        }
    }
    public func invalidate() { state.withLock { $0.heights.removeAll(); $0.pending.removeAll() } }
    public func cancelRequest(_ key: MeasurementKey, ticket: UInt64) {
        state.withLock { state in if state.pending[key] == ticket { state.pending.removeValue(forKey: key) } }
    }
    public func forget(_ key: MeasurementKey) {
        state.withLock { $0.heights.removeValue(forKey: key); $0.pending.removeValue(forKey: key) }
    }
    public func retain(keys: Set<MeasurementKey>) {
        state.withLock { state in
            state.heights = state.heights.filter { keys.contains($0.key) }
            state.pending = state.pending.filter { keys.contains($0.key) }
        }
    }
    public func retain(identities: Set<String>) {
        state.withLock { state in
            state.heights = state.heights.filter { identities.contains($0.key.identity) }
            state.pending = state.pending.filter { identities.contains($0.key.identity) }
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