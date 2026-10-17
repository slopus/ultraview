/// Keeps one preparation in progress and the newest successor. A faster,
/// already-ready successor can overtake both without allowing stale applies.
struct PreparationQueue<Value, Key: Hashable> {
    struct Entry {
        var generation: UInt64
        var value: Value
        var waiting: Set<Key>
    }

    private(set) var inFlight: Entry?
    private(set) var latest: Entry?
    private var generation: UInt64 = 0
    var entries: [Entry] { [inFlight, latest].compactMap { $0 } }
    var isEmpty: Bool { inFlight == nil }

    @discardableResult
    mutating func submit(_ value: Value, waiting: Set<Key>, merge: (Value, Value) -> Value) -> UInt64 {
        generation &+= 1
        var entry = Entry(generation: generation, value: value, waiting: waiting)
        if let latest { entry.value = merge(latest.value, entry.value) }
        if inFlight == nil { inFlight = entry }
        else { latest = entry }
        return entry.generation
    }

    mutating func replaceWaiting(generation: UInt64, with keys: Set<Key>) {
        if inFlight?.generation == generation { inFlight?.waiting = keys }
        if latest?.generation == generation { latest?.waiting = keys }
    }

    mutating func complete(_ key: Key) {
        inFlight?.waiting.remove(key)
        latest?.waiting.remove(key)
    }

    mutating func takeReady(merge: (Value, Value) -> Value) -> Entry? {
        if var ready = latest, ready.waiting.isEmpty {
            if let inFlight { ready.value = merge(inFlight.value, ready.value) }
            inFlight = nil; latest = nil
            return ready
        }
        guard let ready = inFlight, ready.waiting.isEmpty else { return nil }
        inFlight = latest; latest = nil
        return ready
    }

    mutating func updateNewest(_ update: (inout Value) -> Void) {
        if latest != nil { update(&latest!.value) }
        else if inFlight != nil { update(&inFlight!.value) }
    }

    mutating func removeAll() { inFlight = nil; latest = nil }
}

extension PreparationQueue.Entry: Sendable where Value: Sendable, Key: Sendable {}
extension PreparationQueue: Sendable where Value: Sendable, Key: Sendable {}