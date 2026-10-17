import Dispatch
import Foundation
import Synchronization
import UltraLayout

/// The result of one pass: what the main thread must do to its views, for
/// exactly the nodes that changed. Immutable once built and safe to send.
///
/// The main thread applies a commit in this order: unmounts, then mounts
/// from the root down (creating views), then frames, properties, contents
/// and child order.
public struct Commit: Sendable {
    /// Increases with every pass of a tree.
    public private(set) var generation: UInt64
    /// The newest host request (size, window, appearance) this commit
    /// reflects.
    public private(set) var request: UInt64
    /// Entries in the order they were first recorded, with an index by node.
    private var storage: [CommitEntry] = []
    private var index: [ObjectIdentifier: Int] = [:]

    init(generation: UInt64, request: UInt64) {
        self.generation = generation
        self.request = request
    }

    public var isEmpty: Bool { storage.isEmpty }

    /// The number of nodes the commit touches.
    public var count: Int { storage.count }

    public var entries: [ObjectIdentifier: CommitEntry] {
        Dictionary(uniqueKeysWithValues: storage.map { (ObjectIdentifier($0.node), $0) })
    }

    public func entry(for node: UltraNode) -> CommitEntry? {
        index[ObjectIdentifier(node)].map { storage[$0] }
    }

    /// Entries in the order they were first recorded.
    public var orderedEntries: [CommitEntry] {
        storage
    }

    /// Records `entry`, folding it into an existing entry for the same node.
    mutating func record(_ entry: CommitEntry) {
        let key = ObjectIdentifier(entry.node)
        if let position = index[key] {
            storage[position].merge(entry)
        } else {
            index[key] = storage.count
            storage.append(entry)
        }
    }

    /// Changes the entry for `node`, creating an update entry if needed.
    mutating func update(_ node: UltraNode, _ body: (inout CommitEntry) -> Void) {
        let key = ObjectIdentifier(node)
        if let position = index[key] {
            body(&storage[position])
        } else {
            var entry = CommitEntry(kind: .update, node: node)
            body(&entry)
            index[key] = storage.count
            storage.append(entry)
        }
    }

    /// Changes every entry in place.
    mutating func updateAll(_ body: (inout CommitEntry) -> Void) {
        for position in storage.indices {
            body(&storage[position])
        }
    }

    /// Folds a newer commit into this one. Where both touch a node, the newer
    /// values win and the older ones are dropped, so the main thread applies
    /// each node's newest state once.
    mutating func merge(_ newer: Commit) {
        precondition(newer.generation > generation, "commits must be merged in generation order")
        generation = newer.generation
        request = max(request, newer.request)
        for entry in newer.storage {
            record(entry)
        }
    }
}

public struct CommitEntry: Sendable {
    public enum Kind: Sendable, Equatable {
        /// Create the node's view and set everything on it.
        case mount
        /// Change some properties of an existing view.
        case update
        /// Remove the node's view and its subtree's views.
        case unmount
    }

    public internal(set) var kind: Kind
    public let node: UltraNode
    /// For mounts: the parent node, `nil` for the root.
    public internal(set) var parent: UltraNode?
    /// For mounts: distance from the root, so parents are created first.
    public internal(set) var depth = 0
    /// Relative to the parent's view.
    public internal(set) var frame: CGRect?
    public internal(set) var props: ViewProps?
    public internal(set) var contents: ContentsChange?
    /// The node's mounted children in order, when that list changed.
    public internal(set) var children: [UltraNode]?
    /// Whether the node was on screen as of the pass. The main thread
    /// applies everything for nodes on screen at once, and may spread the
    /// creation of other views over several frames.
    public internal(set) var isVisible = false

    init(kind: Kind, node: UltraNode) {
        self.kind = kind
        self.node = node
    }

    mutating func merge(_ newer: CommitEntry) {
        switch newer.kind {
        case .mount, .unmount:
            self = newer
        case .update:
            if kind == .unmount {
                kind = .update
            }
            frame = newer.frame ?? frame
            props = newer.props ?? props
            contents = newer.contents ?? contents
            children = newer.children ?? children
            isVisible = newer.isVisible
        }
    }
}

public enum ContentsChange: Sendable {
    case set(Contents)
    case clear

    public var contents: Contents? {
        if case .set(let contents) = self { contents } else { nil }
    }
}

/// Hands commits from the layout queue to the main thread. Holds at most one
/// commit: a newer one posted before the main thread took the last is merged
/// into it, so outdated values are dropped instead of applied.
///
/// The main thread never waits on it: it takes what's there when it's told
/// something was posted.
public final class CommitMailbox: Sendable {
    private let pending = Mutex<Commit?>(nil)
    private let posted = DispatchSemaphore(value: 0)

    public init() {}

    /// Returns `true` when the mailbox was empty, so the caller should
    /// schedule the main thread to take it.
    @discardableResult
    public func post(_ commit: Commit) -> Bool {
        let wasEmpty = pending.withLock { pending -> Bool in
            if var current = pending {
                current.merge(commit)
                pending = current
                return false
            }
            pending = commit
            return true
        }
        if wasEmpty {
            posted.signal()
        }
        return wasEmpty
    }

    public func take() -> Commit? {
        pending.withLock { pending in
            defer { pending = nil }
            return pending
        }
    }

    /// Takes the pending commit only if it reflects `request` or newer.
    public func take(servingRequest request: UInt64) -> Commit? {
        pending.withLock { pending in
            guard let commit = pending, commit.request >= request else { return nil }
            pending = nil
            return commit
        }
    }

    /// Waits until something is posted or `deadline` passes. For consumers
    /// on background threads, such as tests; never call it on the main
    /// thread.
    public func waitForPost(until deadline: DispatchTime) -> Bool {
        posted.wait(timeout: deadline) == .success
    }
}
