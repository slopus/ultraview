import Foundation
import UltraLayout

/// One node of a tree as it is shown, for planning a layout transition.
public struct TransitionNode: Sendable, Equatable {
    /// The node's `transitionKey`. Only keyed nodes (and the root) are
    /// matched between trees and animated.
    public var key: String?
    /// Index of the parent in the same tree; `nil` for the root, or for a
    /// node given in host coordinates.
    public var parent: Int?
    /// Relative to the parent's bounds.
    public var frame: CGRect
    public var opacity: CGFloat
    /// What the node's bitmap shows: equal values show the same pixels.
    /// `nil` without a bitmap.
    public var contents: UInt64?
    /// Set when the bitmap shows only text: the lines it shows.
    public var text: TextTransitionLines?

    public init(key: String?, parent: Int?, frame: CGRect, opacity: CGFloat = 1, contents: UInt64? = nil, text: TextTransitionLines? = nil) {
        self.key = key
        self.parent = parent
        self.frame = frame
        self.opacity = opacity
        self.contents = contents
        self.text = text
    }
}

/// A tree as shown: nodes in pre-order (parents before children).
public struct TransitionTree: Sendable, Equatable {
    public var nodes: [TransitionNode]
    /// The root's index. A tree without one (like the frames a new row
    /// grows out of) has every node in host coordinates.
    public var root: Int?

    public init(nodes: [TransitionNode], root: Int? = 0) {
        self.nodes = nodes
        self.root = root.flatMap { nodes.indices.contains($0) ? $0 : nil }
    }

    /// Frames in host coordinates.
    public var absoluteFrames: [CGRect] {
        var frames: [CGRect] = []
        frames.reserveCapacity(nodes.count)
        for node in nodes {
            if let parent = node.parent, parent < frames.count {
                frames.append(node.frame.offsetBy(dx: frames[parent].minX, dy: frames[parent].minY))
            } else {
                frames.append(node.frame)
            }
        }
        return frames
    }
}

/// How a hosted tree goes from an old layout to a new one, all on one
/// timing: matched nodes move and resize, keyed nodes that appear fade in,
/// keyed nodes that disappear fade out where they were, and bitmaps that
/// changed crossfade (or, for text, reveal what was added).
///
/// Nodes match by `transitionKey`; the two roots always match. A matched
/// node's start frame is converted into its new parent's coordinates as of
/// the start, so a node that changes parent, or whose parent doesn't
/// animate, still travels in a straight line on screen: when parent and
/// child interpolate on the same curve, the child's on-screen frame is the
/// same interpolation of its old and new on-screen frames.
public struct LayoutTransitionPlan: Sendable, Equatable {
    public struct Move: Sendable, Equatable {
        /// Index in the new tree.
        public var node: Int
        /// In the new parent's coordinates at the start.
        public var from: CGRect
        /// The new frame, relative to the new parent.
        public var to: CGRect
        public var fromOpacity: CGFloat
        public var toOpacity: CGFloat
    }

    public struct Exit: Sendable, Equatable {
        /// Index in the old tree.
        public var node: Int
        /// Index in the new tree of the node whose view holds the fading
        /// view: the new partner of its nearest matched ancestor.
        public var container: Int
        /// In the container's coordinates; held there while it fades.
        public var frame: CGRect
        public var opacity: CGFloat
    }

    public enum Content: Sendable, Equatable {
        /// The old bitmap fades out above the new one.
        case crossfade(old: Int, new: Int)
        case text(old: Int, new: Int, TextTransitionPlan)
    }

    public var moves: [Move]
    /// New keyed nodes without a match, fading in from transparent.
    public var entrances: [Int]
    public var exits: [Exit]
    public var contents: [Content]

    public init(moves: [Move] = [], entrances: [Int] = [], exits: [Exit] = [], contents: [Content] = []) {
        self.moves = moves
        self.entrances = entrances
        self.exits = exits
        self.contents = contents
    }

    /// Partners: new index to old index.
    public static func match(_ old: TransitionTree, _ new: TransitionTree) -> [Int: Int] {
        var byKey: [String: Int] = [:]
        for (index, node) in old.nodes.enumerated() {
            if let key = node.key, byKey[key] == nil { byKey[key] = index }
        }
        var partners: [Int: Int] = [:]
        var taken = Set<Int>()
        if let newRoot = new.root, let oldRoot = old.root {
            partners[newRoot] = oldRoot
            taken.insert(oldRoot)
        }
        for (index, node) in new.nodes.enumerated() where partners[index] == nil {
            guard let key = node.key, let partner = byKey[key], !taken.contains(partner) else { continue }
            partners[index] = partner
            taken.insert(partner)
        }
        return partners
    }

    /// Plans the transition. `inFlight` gives, per old text node, regions of
    /// its bitmap still fading in from an earlier transition.
    public static func plan(
        from old: TransitionTree,
        to new: TransitionTree,
        inFlight: [Int: [TextTransitionPlan.Reveal]] = [:]
    ) -> LayoutTransitionPlan {
        let partners = match(old, new)
        let oldFrames = old.absoluteFrames
        let newFrames = new.absoluteFrames
        // Where each new node is on screen when the transition starts.
        var startFrames: [CGRect] = []
        startFrames.reserveCapacity(new.nodes.count)
        var plan = LayoutTransitionPlan()
        for (index, node) in new.nodes.enumerated() {
            let parentStart = node.parent.flatMap { $0 < startFrames.count ? startFrames[$0] : nil } ?? .zero
            if let partner = partners[index] {
                let start = oldFrames[partner]
                startFrames.append(start)
                plan.moves.append(Move(
                    node: index,
                    from: start.offsetBy(dx: -parentStart.minX, dy: -parentStart.minY),
                    to: node.frame,
                    fromOpacity: old.nodes[partner].opacity,
                    toOpacity: node.opacity
                ))
                let oldNode = old.nodes[partner]
                if oldNode.contents != node.contents {
                    if let from = oldNode.text, let to = node.text {
                        let text = TextTransitionPlan.plan(from: from, to: to, inFlight: inFlight[partner] ?? [])
                        if !text.isIdentity || !(inFlight[partner] ?? []).isEmpty {
                            plan.contents.append(.text(old: partner, new: index, text))
                        }
                    } else if oldNode.contents != nil {
                        plan.contents.append(.crossfade(old: partner, new: index))
                    }
                }
            } else {
                startFrames.append(newFrames[index])
                if node.key != nil, index != new.root {
                    plan.entrances.append(index)
                }
            }
        }

        // Keyed old nodes without a partner fade out, unless an ancestor
        // already carries them out.
        let matchedOld = Dictionary(uniqueKeysWithValues: partners.map { ($0.value, $0.key) })
        var leaving = Set<Int>()
        for (index, node) in old.nodes.enumerated() where matchedOld[index] == nil && node.key != nil && index != old.root {
            var ancestor = node.parent
            var carried = false
            var container: Int?
            while let current = ancestor {
                if leaving.contains(current) { carried = true; break }
                if let partner = matchedOld[current] { container = partner; break }
                ancestor = old.nodes[current].parent
            }
            leaving.insert(index)
            guard !carried else { continue }
            let holder = container ?? new.root ?? 0
            guard holder < startFrames.count else { continue }
            let origin = startFrames[holder].origin
            plan.exits.append(Exit(
                node: index,
                container: holder,
                frame: oldFrames[index].offsetBy(dx: -origin.x, dy: -origin.y),
                opacity: node.opacity
            ))
        }
        return plan
    }
}

/// How a node enters when its tree first appears: from a smaller scale
/// around one corner, and from transparent.
public struct NodeAppearance: Sendable, Equatable {
    /// The node's `transitionKey`.
    public var key: String
    /// The scale it starts at; 1 doesn't scale.
    public var scale: CGFloat
    /// The fixed point of the scaling, in unit coordinates of the node
    /// (0, 0 is the top-left corner).
    public var anchor: CGPoint
    public var fades: Bool

    public init(key: String, scale: CGFloat = 0.9, anchor: CGPoint = CGPoint(x: 0, y: 1), fades: Bool = true) {
        self.key = key
        self.scale = scale
        self.anchor = anchor
        self.fades = fades
    }

    /// The translation that, combined with scaling by `scale` about the
    /// center of a box of `size`, keeps `anchor` fixed.
    public func translation(for size: CGSize) -> CGPoint {
        let dx = (anchor.x - 0.5) * size.width
        let dy = (anchor.y - 0.5) * size.height
        return CGPoint(x: dx * (1 - scale), y: dy * (1 - scale))
    }
}

/// The direction a layout animation moves or sizes a node in. A row whose
/// width and height animate on different timings moves each axis of its
/// content on that axis's timing, so content insets hold on both.
public enum TransitionAxis: Sendable, Equatable {
    case horizontal, vertical

    /// The axis `keyPath` animates; `nil` for one that isn't a position or
    /// size along one axis (opacity, color, corner radius, transform).
    public init?(keyPath: String) {
        switch keyPath {
        case "position.x", "bounds.size.width", "bounds.origin.x": self = .horizontal
        case "position.y", "bounds.size.height", "bounds.origin.y": self = .vertical
        default: return nil
        }
    }
}

/// A running animation whose destination moves at once: it keeps its timing
/// and its remaining motion, now ending at the new destination. Every value
/// it shows from then on is shifted by how far the destination moved, as a
/// list moves a row's running track when its size changes immediately.
public enum TransitionShift {
    /// The start that, on the same timing, ends at `target` instead of `to`.
    public static func start(from: Double, to: Double, target: Double) -> Double {
        from + (target - to)
    }
}
