/// What the main thread has yet to apply, and the order to apply it in.
///
/// Creating views is the main thread's most expensive work, and a commit can
/// mount hundreds of them (a scroll node entering a window, a jump far down
/// a feed). So a turn applies, together:
/// - every unmount and every update,
/// - the mounts of nodes on screen, which must appear in the same frame as
///   the rest of what's on screen;
///
/// and then the mounts of nodes off screen one at a time, parents before
/// children, while the turn's budget lasts. Whatever is left waits for the
/// next turn. A newer commit merges into what's left, so a view that went
/// out of range before it was created is never created.
///
/// Platform-free: the caller does the view work. Main thread only.
struct CommitQueue {
    private var remainder: Commit?

    /// Whether some work is waiting for a turn.
    var hasWork: Bool { remainder != nil }

    /// Adds a newer commit to the work.
    mutating func add(_ commit: Commit) {
        if var remainder {
            remainder.merge(commit)
            self.remainder = remainder
        } else {
            remainder = commit
        }
    }

    /// The work for one turn.
    struct Turn {
        /// Applied in full, in one transaction: unmounts, updates and the
        /// mounts of nodes on screen. Same order rules as a whole commit.
        var now: [CommitEntry] = []
        /// Mounts of nodes off screen, parents before children. Apply a
        /// prefix and hand the rest back with `putBack`.
        var later: [CommitEntry] = []
        let generation: UInt64
        let request: UInt64
    }

    /// Takes all the work; give back what a turn didn't get to.
    mutating func takeTurn() -> Turn? {
        guard let commit = remainder else { return nil }
        remainder = nil
        let entries = commit.orderedEntries
        var isNow = entries.map { $0.kind != .mount || $0.isVisible }
        // A node on screen needs its ancestors' views in the same turn.
        var mountPositions: [ObjectIdentifier: Int] = [:]
        for (position, entry) in entries.enumerated() where entry.kind == .mount {
            mountPositions[ObjectIdentifier(entry.node)] = position
        }
        for (position, entry) in entries.enumerated() where entry.kind == .mount && isNow[position] {
            var parent = entry.parent
            while let node = parent, let parentPosition = mountPositions[ObjectIdentifier(node)], !isNow[parentPosition] {
                isNow[parentPosition] = true
                parent = entries[parentPosition].parent
            }
        }

        var turn = Turn(generation: commit.generation, request: commit.request)
        var later: [(position: Int, entry: CommitEntry)] = []
        for (position, entry) in entries.enumerated() {
            if isNow[position] {
                turn.now.append(entry)
            } else {
                later.append((position, entry))
            }
        }
        // Stable, so siblings keep the order the pass recorded them in.
        turn.later = later
            .sorted { ($0.entry.depth, $0.position) < ($1.entry.depth, $1.position) }
            .map(\.entry)
        return turn
    }

    /// Returns mounts a turn didn't apply, in order. Call it before adding
    /// newer commits.
    mutating func putBack<Entries: Collection<CommitEntry>>(_ entries: Entries, of turn: Turn) {
        guard !entries.isEmpty else { return }
        precondition(remainder == nil, "put back before adding newer commits")
        var commit = Commit(generation: turn.generation, request: turn.request)
        for entry in entries {
            commit.record(entry)
        }
        remainder = commit
    }
}
