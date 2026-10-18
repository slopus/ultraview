#if canImport(UIKit)
import QuartzCore
import UIKit
import UltraLayout

/// The timing every animation of one layout transition shares: a begin
/// time, a duration, a speed, and a curve or spring. Built from an
/// animation already running elsewhere (a list row's height), node
/// animations run exactly in step with it, frame by frame.
@MainActor
public struct NodeAnimationTiming {
    let template: CABasicAnimation
    /// The value progress at which animations join this timing, if they
    /// join one already running.
    private(set) var joinProgress: Double?

    /// The timing of `animation`, including its begin time once it has
    /// one. `nil` for animations that aren't basic or spring animations.
    public init?(matching animation: CAAnimation) {
        guard let basic = animation.copy() as? CABasicAnimation else { return nil }
        basic.delegate = nil
        template = basic
    }

    /// A curve over `duration` seconds, starting when the current
    /// transaction commits.
    public init(duration: CFTimeInterval, timingFunction: CAMediaTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)) {
        let basic = CABasicAnimation()
        basic.duration = duration
        basic.timingFunction = timingFunction
        template = basic
    }

    /// A spring settling within `duration` seconds.
    public init(springDuration duration: CFTimeInterval, mass: CGFloat = 1, stiffness: CGFloat, damping: CGFloat) {
        let spring = CASpringAnimation()
        spring.mass = mass
        spring.stiffness = stiffness
        spring.damping = damping
        spring.duration = duration
        template = spring
    }

    /// When the animations begin, in layer time; 0 until the transaction
    /// that adds them commits.
    public var beginTime: CFTimeInterval { template.beginTime }

    /// The same timing for animations joining it at value progress
    /// `progress` (the share of its way an animation on it has covered):
    /// each starts from where its layer shows it and arrives with the rest.
    public func joined(at progress: Double) -> NodeAnimationTiming {
        var joined = self
        joined.joinProgress = min(max(progress, 0), 0.999)
        return joined
    }

    /// Whether values on this timing stay between their two ends: a curve
    /// that doesn't overshoot, or a spring damped enough not to.
    public var staysWithinItsEnds: Bool {
        if let spring = template as? CASpringAnimation {
            // A damping ratio of 0.99 overshoots by less than 1e-9; springs
            // meant to be critical are often written a digit short of it.
            return spring.initialVelocity == 0 && spring.damping >= 0.99 * 2 * (spring.stiffness * spring.mass).squareRoot()
        }
        guard let function = template.timingFunction else { return true }
        for index in 1...2 {
            var point: [Float] = [0, 0]
            function.getControlPoint(at: index, values: &point)
            if point[1] < 0 || point[1] > 1 { return false }
        }
        return true
    }

    /// How long they run, in layer time.
    public var activeDuration: CFTimeInterval {
        template.duration / Double(max(template.speed, 1e-6))
    }

    /// Whether `animation` already runs on this timing: same begin, length,
    /// speed and curve or spring.
    func isTiming(of animation: CABasicAnimation) -> Bool {
        let template = self.template
        // Begin times converted between layers' clocks differ in rounding.
        guard abs(animation.beginTime - template.beginTime) < 1e-6, animation.duration == template.duration,
              animation.speed == template.speed, animation.timeOffset == template.timeOffset,
              (animation is CASpringAnimation) == (template is CASpringAnimation) else { return false }
        if let spring = animation as? CASpringAnimation, let model = template as? CASpringAnimation {
            return spring.mass == model.mass && spring.stiffness == model.stiffness
                && spring.damping == model.damping && spring.initialVelocity == model.initialVelocity
        }
        func points(_ function: CAMediaTimingFunction?) -> [Float] {
            guard let function else { return [] }
            var values: [Float] = []
            for index in 0..<4 {
                var point: [Float] = [0, 0]
                function.getControlPoint(at: index, values: &point)
                values += point
            }
            return values
        }
        return points(animation.timingFunction) == points(template.timingFunction)
    }

    func animation(_ keyPath: String, from: Any?, to: Any?) -> CABasicAnimation {
        let animation = template.copy() as! CABasicAnimation
        animation.keyPath = keyPath
        animation.fromValue = from
        animation.toValue = to
        if let joinProgress, let shown = (from as? NSNumber)?.doubleValue, let end = (to as? NSNumber)?.doubleValue {
            animation.fromValue = TransitionJoin.start(shown: shown, to: end, progress: joinProgress)
        }
        animation.isAdditive = false
        animation.delegate = nil
        animation.fillMode = .both
        animation.isRemovedOnCompletion = true
        return animation
    }
}

/// A hosted tree as it looked at one moment: what a later layout
/// transition animates from. Taking one reads each view's presentation, so
/// a transition that interrupts another starts where things are on screen.
@MainActor
public struct NodeTransitionSnapshot {
    struct Visual {
        var contents: Any?
        var contentsScale: CGFloat = 1
        var contentsGravity: CALayerContentsGravity = .resize
        var contentsCenter = CGRect(x: 0, y: 0, width: 1, height: 1)
        var backgroundColor: CGColor?
        var cornerRadius: CGFloat = 0
        var transform = CATransform3DIdentity
        /// Text regions still fading in, in the view's coordinates.
        var reveals: [TextTransitionPlan.Reveal] = []
        /// Old bitmaps still fading out over this view.
        var ghosts: [Ghost] = []
        /// The layer, for replicating a leaving node.
        weak var layer: CALayer?
    }

    struct Ghost {
        var layer: CALayer
        var opacity: Float
    }

    public internal(set) var tree: TransitionTree
    var visuals: [Visual]

    /// Frames in host coordinates by transition key, for a tree to grow out
    /// of when it first appears (a sent message out of the text field).
    public init(frames: [(key: String, frame: CGRect)]) {
        tree = TransitionTree(nodes: frames.map { TransitionNode(key: $0.key, parent: nil, frame: $0.frame) }, root: nil)
        visuals = frames.map { _ in Visual() }
    }

    init(tree: TransitionTree, visuals: [Visual]) {
        self.tree = tree
        self.visuals = visuals
    }

    public var isEmpty: Bool { tree.nodes.isEmpty }

    /// The frame of the keyed node, in host coordinates.
    public func frame(forKey key: String) -> CGRect? {
        guard let index = tree.nodes.firstIndex(where: { $0.key == key }) else { return nil }
        return tree.absoluteFrames[index]
    }
}

/// Plays layout transitions on one host's views: Core Animation
/// animations, all on one timing, added in the transaction that shows the
/// new layout. Nothing runs per frame on the main thread.
///
/// Each animated property (x, y, width, height, opacity, ...) is its own
/// animation. A property whose destination didn't change keeps the
/// animation it had, with its timing, when the tree is replaced; one whose
/// destination changed restarts from where it is shown, on the new timing.
/// This is how a list replaces a row's geometry tracks, so a node sized
/// like its row changes timing exactly when the row does.
@MainActor
final class NodeTransitionAnimator {
    static let ghostName = "ultraview.node.ghost"
    static let maskName = "ultraview.node.reveal"
    /// A sublayer that shows a view's own bitmap while parts of it fade in.
    static let revealedName = "ultraview.node.revealed"
    /// On a view's layer: its sublayer named `revealedName`.
    private static let revealedKey = "ultraviewRevealedLayer"
    static let keyPrefix = "ultraview.node."
    /// On an animation carried to a layer not yet shown: the value shown
    /// when it was carried.
    static let shownKey = "ultraviewShownValue"

    // MARK: Snapshots

    static func snapshot(of root: UltraNode, presented: Bool) -> NodeTransitionSnapshot {
        var nodes: [TransitionNode] = []
        var visuals: [NodeTransitionSnapshot.Visual] = []
        func visit(_ node: UltraNode, parent: Int?) {
            guard let view = node.mountedView else { return }
            let layer = view.layer
            let shown = presented ? (layer.presentation() ?? layer) : layer
            let size = shown.bounds.size
            let frame = CGRect(
                x: shown.position.x - size.width * shown.anchorPoint.x,
                y: shown.position.y - size.height * shown.anchorPoint.y,
                width: size.width,
                height: size.height
            )
            let contents = node.appliedContents
            let drawn = contentsLayer(of: layer)
            var text: TextTransitionLines?
            if case .top? = contents?.placement {
                text = node.appliedProps?.text?.lines
            }
            nodes.append(TransitionNode(
                key: parent == nil ? nil : node.appliedProps?.transitionKey,
                parent: parent,
                frame: frame,
                opacity: CGFloat(shown.opacity),
                contents: drawn.contents == nil ? nil : contents?.id,
                text: text
            ))
            var visual = NodeTransitionSnapshot.Visual()
            visual.contents = drawn.contents
            visual.contentsScale = drawn.contentsScale
            visual.contentsGravity = drawn.contentsGravity
            visual.contentsCenter = drawn.contentsCenter
            visual.backgroundColor = shown.backgroundColor
            visual.cornerRadius = shown.cornerRadius
            visual.transform = shown.transform
            visual.layer = layer
            if let mask = drawn.mask, mask.name == maskName {
                for region in mask.sublayers ?? [] where region.animation(forKey: revealKey) != nil {
                    let opacity = presented ? (region.presentation()?.opacity ?? region.opacity) : region.opacity
                    visual.reveals.append(.init(rect: region.frame, fromOpacity: CGFloat(opacity)))
                }
            }
            for ghost in layer.sublayers ?? [] where ghost.name == ghostName {
                let opacity = presented ? (ghost.presentation()?.opacity ?? ghost.opacity) : ghost.opacity
                if opacity > 0.001 { visual.ghosts.append(.init(layer: ghost, opacity: opacity)) }
            }
            visuals.append(visual)
            let index = nodes.count - 1
            for child in node.mountedChildren where child.mountedView?.superview === view {
                visit(child, parent: index)
            }
        }
        visit(root, parent: nil)
        return NodeTransitionSnapshot(tree: TransitionTree(nodes: nodes), visuals: visuals)
    }

    private static let revealKey = "ultraview.node.reveal"

    // MARK: Transitions

    /// Animates `root`'s views from `old` to how they are now.
    func animate(root: UltraNode, from old: NodeTransitionSnapshot, timing: NodeAnimationTiming) {
        let new = Self.snapshot(of: root, presented: false)
        guard !new.isEmpty else { return }
        var inFlight: [Int: [TextTransitionPlan.Reveal]] = [:]
        for (index, visual) in old.visuals.enumerated() where !visual.reveals.isEmpty {
            inFlight[index] = visual.reveals
        }
        let plan = LayoutTransitionPlan.plan(from: old.tree, to: new.tree, inFlight: inFlight)
        let layers = new.visuals.map(\.layer)
        let partners = LayoutTransitionPlan.match(old.tree, new.tree)
        let moves = Dictionary(plan.moves.map { ($0.node, $0) }, uniquingKeysWith: { first, _ in first })
        for move in plan.moves {
            guard let layer = layers[move.node] else { continue }
            let partner = partners[move.node]
            let before = partner.map { old.visuals[$0] }
            // A running animation carries over only within the same parent's
            // coordinates.
            let newParent = new.tree.nodes[move.node].parent
            let oldParent = partner.flatMap { old.tree.nodes[$0].parent }
            let sameParent = newParent.flatMap { partners[$0] } == oldParent && (newParent == nil) == (oldParent == nil)
            let carrier = sameParent ? before?.layer : nil
            let position = layer.position
            let size = layer.bounds.size
            scalar(layer, "position.x", from: move.from.midX, to: position.x, carrier: carrier, timing: timing)
            scalar(layer, "position.y", from: move.from.midY, to: position.y, carrier: carrier, timing: timing)
            scalar(layer, "bounds.size.width", from: move.from.width, to: size.width, carrier: carrier, timing: timing)
            scalar(layer, "bounds.size.height", from: move.from.height, to: size.height, carrier: carrier, timing: timing)
            scalar(layer, "opacity", from: move.fromOpacity, to: CGFloat(layer.opacity), carrier: before?.layer, timing: timing)
            if let before {
                if let color = before.backgroundColor ?? layer.backgroundColor.map({ $0.copy(alpha: 0) ?? $0 }), let current = layer.backgroundColor {
                    value(layer, "backgroundColor", from: color, to: current, same: color == current, carrier: before.layer,
                          isTarget: { ($0 as! CGColor) == current }, timing: timing)
                }
                scalar(layer, "cornerRadius", from: before.cornerRadius, to: layer.cornerRadius, carrier: before.layer, timing: timing)
                let transform = layer.transform
                value(layer, "transform", from: NSValue(caTransform3D: before.transform), to: NSValue(caTransform3D: transform),
                      same: CATransform3DEqualToTransform(before.transform, transform), carrier: before.layer,
                      isTarget: { CATransform3DEqualToTransform(($0 as! NSValue).caTransform3DValue, transform) }, timing: timing)
                // Old bitmaps still fading out keep fading, now over this view.
                for ghost in before.ghosts {
                    carryGhost(ghost, onto: layer, timing: timing)
                }
            }
        }
        for entrance in plan.entrances {
            guard let layer = layers[entrance] else { continue }
            add(layer, "opacity", from: Float(0), to: layer.opacity, timing: timing)
        }
        for content in plan.contents {
            switch content {
            case .crossfade(let oldIndex, let newIndex):
                guard let layer = layers[newIndex], let move = moves[newIndex] else { continue }
                fadeOut(old.visuals[oldIndex], over: layer, move: move, regions: nil, timing: timing)
            case .text(let oldIndex, let newIndex, let text):
                guard let layer = layers[newIndex], let move = moves[newIndex] else { continue }
                reveal(text, on: layer, move: move, timing: timing)
                if !text.fadeOut.isEmpty {
                    fadeOut(old.visuals[oldIndex], over: layer, move: move, regions: text.fadeOut, timing: timing)
                }
            }
        }
        for exit in plan.exits {
            guard let container = layers[exit.container], let source = old.visuals[exit.node].layer else { continue }
            let ghost = Self.replica(of: source)
            ghost.name = Self.ghostName
            ghost.frame = exit.frame
            ghost.opacity = 0
            container.addSublayer(ghost)
            add(ghost, "opacity", from: Float(exit.opacity), to: Float(0), timing: timing, removesLayer: true)
        }
    }

    /// Grows keyed nodes out of a smaller scale around a corner and from
    /// transparent, for a tree's first appearance.
    func appear(root: UltraNode, _ appearances: [NodeAppearance], timing: NodeAnimationTiming) {
        let new = Self.snapshot(of: root, presented: false)
        for appearance in appearances {
            guard let index = new.tree.nodes.firstIndex(where: { $0.key == appearance.key }), let layer = new.visuals[index].layer else { continue }
            if appearance.scale != 1 {
                let shift = appearance.translation(for: layer.bounds.size)
                var start = CATransform3DMakeTranslation(shift.x, shift.y, 0)
                start = CATransform3DScale(start, appearance.scale, appearance.scale, 1)
                start = CATransform3DConcat(layer.transform, start)
                add(layer, "transform", from: NSValue(caTransform3D: start), to: NSValue(caTransform3D: layer.transform), timing: timing)
            }
            if appearance.fades {
                add(layer, "opacity", from: Float(0), to: layer.opacity, timing: timing)
            }
        }
    }

    /// Moves every animation still running under `root` onto `timing`, from
    /// where it is toward where it was going. Animations added in the
    /// current transaction restart from where they started; those already
    /// on `timing` stay as they are. With an `axis`, positions and sizes
    /// along the other axis keep their timing.
    func retime(root: UltraNode, _ timing: NodeAnimationTiming, axis: TransitionAxis? = nil) {
        for layer in Self.layers(under: root) {
            for key in layer.animationKeys() ?? [] where key.hasPrefix(Self.keyPrefix) {
                guard let running = layer.animation(forKey: key) as? CABasicAnimation, let keyPath = running.keyPath,
                      !timing.isTiming(of: running) else { continue }
                if let axis, let moves = TransitionAxis(keyPath: keyPath), moves != axis { continue }
                let from: Any?
                if running.beginTime == 0 {
                    from = running.fromValue
                } else if let shown = layer.presentation()?.value(forKeyPath: keyPath) {
                    from = shown
                } else {
                    from = running.value(forKey: Self.shownKey) ?? running.fromValue
                }
                let animation = timing.animation(keyPath, from: from, to: running.toValue)
                animation.delegate = running.delegate
                layer.add(animation, forKey: key)
            }
        }
    }

    /// For a layout that replaced `old`'s at once while `old`'s views were
    /// still animating: each number they animate continues on `root`'s
    /// matching view, on its own timing, ending at the new value, shifted
    /// by how far that moved. Everything else shows the new layout at once.
    func shift(root: UltraNode, from old: NodeTransitionSnapshot) {
        let new = Self.snapshot(of: root, presented: false)
        guard !new.isEmpty else { return }
        let partners = LayoutTransitionPlan.match(old.tree, new.tree)
        for (index, visual) in new.visuals.enumerated() {
            guard let layer = visual.layer, let partner = partners[index], let carrier = old.visuals[partner].layer else { continue }
            // Positions carry over only within the same parent's coordinates.
            let newParent = new.tree.nodes[index].parent
            let oldParent = old.tree.nodes[partner].parent
            let sameParent = newParent.flatMap { partners[$0] } == oldParent && (newParent == nil) == (oldParent == nil)
            for keyPath in ["position.x", "position.y", "bounds.size.width", "bounds.size.height", "opacity", "cornerRadius"] {
                if !sameParent, keyPath.hasPrefix("position") { continue }
                let key = Self.keyPrefix + keyPath
                guard let running = carrier.animation(forKey: key) as? CABasicAnimation,
                      let from = (running.fromValue as? NSNumber)?.doubleValue, let to = (running.toValue as? NSNumber)?.doubleValue,
                      let target = (layer.value(forKeyPath: keyPath) as? NSNumber)?.doubleValue else { continue }
                let shifted = running.copy() as! CABasicAnimation
                shifted.delegate = nil
                shifted.fromValue = TransitionShift.start(from: from, to: to, target: target)
                shifted.toValue = target
                layer.add(shifted, forKey: key)
            }
        }
    }

    /// Whether any transition animation is still running under `root`.
    func isAnimating(root: UltraNode) -> Bool {
        Self.layers(under: root).contains { layer in
            (layer.animationKeys() ?? []).contains { $0.hasPrefix(Self.keyPrefix) }
        }
    }

    /// Removes every transition animation, ghost and mask under `root`.
    func cancel(root: UltraNode) {
        for layer in Self.layers(under: root) {
            for key in layer.animationKeys() ?? [] where key.hasPrefix(Self.keyPrefix) {
                layer.removeAnimation(forKey: key)
            }
            if layer.name == Self.ghostName { layer.removeFromSuperlayer() }
            Self.endReveal(on: layer)
        }
    }

    /// The node views' layers under `root`, with the layers revealing their
    /// bitmaps, those layers' masks' regions, and their ghosts.
    static func layers(under root: UltraNode) -> [CALayer] {
        var result: [CALayer] = []
        func visit(_ node: UltraNode) {
            guard let view = node.mountedView else { return }
            let layer = view.layer
            result.append(layer)
            let drawn = contentsLayer(of: layer)
            if drawn !== layer { result.append(drawn) }
            if let mask = drawn.mask, mask.name == maskName { result.append(contentsOf: mask.sublayers ?? []) }
            for ghost in layer.sublayers ?? [] where ghost.name == ghostName { result.append(ghost) }
            for child in node.mountedChildren { visit(child) }
        }
        visit(root)
        return result
    }

    // MARK: Pieces

    /// Animates one number: keeps a carrier's running animation that ends
    /// at the same value, otherwise starts from `from` on `timing`.
    private func scalar(_ layer: CALayer, _ keyPath: String, from: CGFloat, to: CGFloat, carrier: CALayer?, timing: NodeAnimationTiming) {
        value(layer, keyPath, from: Double(from), to: Double(to), same: abs(from - to) < 0.001, carrier: carrier,
              isTarget: { abs((($0 as? NSNumber)?.doubleValue ?? .nan) - Double(to)) < 0.001 }, timing: timing)
    }

    private func value(_ layer: CALayer, _ keyPath: String, from: Any, to: Any, same: Bool, carrier: CALayer?, isTarget: (Any) -> Bool, timing: NodeAnimationTiming) {
        let key = Self.keyPrefix + keyPath
        if let carrier, let running = carrier.animation(forKey: key) as? CABasicAnimation, let target = running.toValue, isTarget(target) {
            // Same destination: the running animation goes on with its
            // timing, as a list track whose target didn't change. A retime
            // before this layer is shown starts from the carrier's value.
            let carried = running.copy() as! CABasicAnimation
            if let shown = carrier.presentation()?.value(forKeyPath: keyPath) {
                carried.setValue(shown, forKey: Self.shownKey)
            }
            layer.add(carried, forKey: key)
            return
        }
        guard !same else { return }
        add(layer, keyPath, from: from, to: to, timing: timing)
    }

    private func add(_ layer: CALayer, _ keyPath: String, from: Any?, to: Any?, timing: NodeAnimationTiming, key: String? = nil, removesLayer: Bool = false, cleanup: (@MainActor () -> Void)? = nil) {
        let key = key ?? Self.keyPrefix + keyPath
        let animation = timing.animation(keyPath, from: from, to: to)
        if removesLayer || cleanup != nil {
            animation.delegate = TransitionCleanup(layer: layer, key: key, removesLayer: removesLayer, action: cleanup)
        }
        layer.add(animation, forKey: key)
    }

    /// Shows the new text bitmap through a mask: stable regions at once,
    /// new ones fading in. The bitmap moves onto a sublayer for this, and the
    /// mask goes on that sublayer: on the view's layer it would mask the old
    /// bitmap fading out over it too, so a rewritten line would show at
    /// `p · (1 - p)` of the old bitmap plus `p` of the new instead of
    /// `1 - p` plus `p`, nearly blank at the start.
    private func reveal(_ text: TextTransitionPlan, on layer: CALayer, move: LayoutTransitionPlan.Move, timing: NodeAnimationTiming) {
        guard !text.reveals.isEmpty else { return }
        let drawn = Self.revealedLayer(of: layer)
        let limit = Self.limit(move)
        let mask = CALayer()
        mask.name = Self.maskName
        mask.frame = CGRect(origin: .zero, size: move.to.size)
        for region in text.stable {
            guard let band = Self.band(region, within: limit) else { continue }
            mask.addSublayer(band)
        }
        // Every region shares the timing, so the first to finish ends them all.
        let unmask: @MainActor () -> Void = { [weak layer, weak drawn, weak mask] in
            guard let layer, let drawn, let mask, drawn.mask === mask else { return }
            Self.endReveal(on: layer)
        }
        var first = true
        for region in text.reveals {
            guard let band = Self.band(region.rect, within: limit) else { continue }
            mask.addSublayer(band)
            let from = Float(region.fromOpacity)
            add(band, "opacity", from: from, to: Float(1), timing: timing, key: Self.revealKey, cleanup: first ? unmask : nil)
            first = false
        }
        drawn.mask = mask
    }

    /// The layer that shows `layer`'s own bitmap: `layer`, or the sublayer
    /// revealing it.
    static func contentsLayer(of layer: CALayer) -> CALayer {
        layer.value(forKey: revealedKey) as? CALayer ?? layer
    }

    /// Moves `layer`'s bitmap onto a sublayer at the bottom, unless it is on
    /// one already, which then takes `layer`'s size and running size
    /// animations.
    private static func revealedLayer(of layer: CALayer) -> CALayer {
        if let drawn = layer.value(forKey: revealedKey) as? CALayer {
            drawn.bounds = CGRect(origin: .zero, size: layer.bounds.size)
            follow(layer, with: drawn)
            return drawn
        }
        let drawn = CALayer()
        drawn.name = revealedName
        drawn.contents = layer.contents
        drawn.contentsScale = layer.contentsScale
        drawn.contentsGravity = layer.contentsGravity
        drawn.contentsCenter = layer.contentsCenter
        drawn.anchorPoint = .zero
        drawn.position = .zero
        drawn.bounds = CGRect(origin: .zero, size: layer.bounds.size)
        follow(layer, with: drawn)
        layer.contents = nil
        layer.insertSublayer(drawn, at: 0)
        layer.setValue(drawn, forKey: revealedKey)
        return drawn
    }

    /// Puts `layer`'s bitmap back on it once nothing fades in.
    static func endReveal(on layer: CALayer) {
        guard let drawn = layer.value(forKey: revealedKey) as? CALayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(nil, forKey: revealedKey)
        layer.contents = drawn.contents
        layer.contentsScale = drawn.contentsScale
        drawn.removeFromSuperlayer()
        CATransaction.commit()
    }

    /// Gives a sublayer anchored at `layer`'s origin `layer`'s running size
    /// animations, the same values on the same timing, so it keeps `layer`'s
    /// size.
    private static func follow(_ layer: CALayer, with sublayer: CALayer) {
        for keyPath in ["bounds.size.width", "bounds.size.height"] {
            let key = keyPrefix + keyPath
            guard let running = layer.animation(forKey: key)?.copy() as? CAAnimation else {
                sublayer.removeAnimation(forKey: key)
                continue
            }
            running.delegate = nil
            sublayer.add(running, forKey: key)
        }
    }

    /// Puts the old bitmap over the new view's own bitmap and fades it out,
    /// following the view's size, shown only in `regions` (old view
    /// coordinates) when given, and parts of it that were still fading in
    /// only as far as they had. It goes right above the new bitmap and
    /// below the view's other sublayers: a view's bitmap draws under its
    /// children, and so does the old one.
    private func fadeOut(_ old: NodeTransitionSnapshot.Visual, over layer: CALayer, move: LayoutTransitionPlan.Move, regions: [CGRect]?, timing: NodeAnimationTiming) {
        guard let contents = old.contents else { return }
        let ghost = CALayer()
        ghost.name = Self.ghostName
        ghost.contents = contents
        ghost.contentsScale = old.contentsScale
        ghost.contentsGravity = old.contentsGravity
        ghost.contentsCenter = old.contentsCenter
        ghost.anchorPoint = .zero
        ghost.position = .zero
        ghost.bounds = CGRect(origin: .zero, size: layer.bounds.size)
        ghost.opacity = 0
        let fading = old.reveals.filter { $0.fromOpacity < 0.999 }
        if regions != nil || !fading.isEmpty {
            let mask = CALayer()
            mask.frame = CGRect(origin: .zero, size: move.from.size)
            let limit = Self.limit(move)
            let far = TextTransitionPlan.outset
            let shown = regions ?? [CGRect(x: -far, y: -far, width: 2 * far, height: 2 * far)]
            var whole = shown
            for flight in fading {
                whole = whole.flatMap { $0.subtracting(flight.rect) }
            }
            for region in whole {
                guard let band = Self.band(region, within: limit) else { continue }
                mask.addSublayer(band)
            }
            // In-flight regions don't overlap, so neither do these bands.
            for flight in fading {
                for region in shown {
                    guard let band = Self.band(region.intersection(flight.rect), within: limit) else { continue }
                    band.opacity = Float(flight.fromOpacity)
                    mask.addSublayer(band)
                }
            }
            ghost.mask = mask
        }
        layer.insertSublayer(ghost, at: Self.ghostIndex(in: layer))
        Self.follow(layer, with: ghost)
        add(ghost, "opacity", from: Float(1), to: Float(0), timing: timing, removesLayer: true)
    }

    /// Moves a ghost that was fading out over an old view onto its new
    /// counterpart, continuing from its current opacity.
    private func carryGhost(_ ghost: NodeTransitionSnapshot.Ghost, onto layer: CALayer, timing: NodeAnimationTiming) {
        let carried = CALayer()
        carried.name = Self.ghostName
        carried.contents = ghost.layer.contents
        carried.contentsScale = ghost.layer.contentsScale
        carried.contentsGravity = ghost.layer.contentsGravity
        carried.contentsCenter = ghost.layer.contentsCenter
        carried.anchorPoint = .zero
        carried.position = .zero
        carried.bounds = CGRect(origin: .zero, size: layer.bounds.size)
        carried.mask = ghost.layer.mask.map(Self.replica(of:))
        carried.opacity = 0
        layer.insertSublayer(carried, at: Self.ghostIndex(in: layer))
        Self.follow(layer, with: carried)
        add(carried, "opacity", from: ghost.opacity, to: Float(0), timing: timing, removesLayer: true)
    }

    /// Where a ghost goes among `layer`'s sublayers: right above the layer
    /// revealing its bitmap, if any, or at the bottom.
    private static func ghostIndex(in layer: CALayer) -> UInt32 {
        let drawn = contentsLayer(of: layer)
        guard drawn !== layer, let index = layer.sublayers?.firstIndex(where: { $0 === drawn }) else { return 0 }
        return UInt32(index + 1)
    }

    private static func limit(_ move: LayoutTransitionPlan.Move) -> CGRect {
        CGRect(origin: .zero, size: move.from.size).union(CGRect(origin: .zero, size: move.to.size)).insetBy(dx: -40, dy: -40)
    }

    private static func band(_ region: CGRect, within limit: CGRect) -> CALayer? {
        let clipped = region.intersection(limit)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        let band = CALayer()
        band.backgroundColor = CGColor(gray: 0, alpha: 1)
        band.frame = clipped
        return band
    }

    /// A layer tree that looks like `source` does now, without its
    /// animations.
    static func replica(of source: CALayer) -> CALayer {
        let shown = source.presentation() ?? source
        let copy = CALayer()
        copy.bounds = shown.bounds
        copy.position = shown.position
        copy.anchorPoint = shown.anchorPoint
        copy.transform = shown.transform
        copy.opacity = shown.opacity
        let drawn = contentsLayer(of: source)
        copy.contents = drawn.contents
        copy.contentsScale = drawn.contentsScale
        copy.contentsGravity = drawn.contentsGravity
        copy.contentsCenter = drawn.contentsCenter
        copy.backgroundColor = shown.backgroundColor
        copy.cornerRadius = shown.cornerRadius
        copy.maskedCorners = source.maskedCorners
        copy.borderWidth = shown.borderWidth
        copy.borderColor = shown.borderColor
        copy.masksToBounds = source.masksToBounds
        for child in source.sublayers ?? [] where child.name != ghostName && child !== drawn {
            copy.addSublayer(replica(of: child))
        }
        return copy
    }
}

/// Removes a transition's temporary layer, or runs its cleanup, once its
/// animation ends without a replacement.
private final class TransitionCleanup: NSObject, CAAnimationDelegate, @unchecked Sendable {
    // @unchecked Sendable: created, read and called only on the main thread
    // (Core Animation calls delegates there; the call hops to the main actor).
    weak var layer: CALayer?
    let key: String
    let removesLayer: Bool
    let action: (@MainActor () -> Void)?

    init(layer: CALayer, key: String, removesLayer: Bool, action: (@MainActor () -> Void)?) {
        self.layer = layer
        self.key = key
        self.removesLayer = removesLayer
        self.action = action
    }

    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        Task { @MainActor [self] in
            guard let layer else { return }
            // A retimed replacement carries this delegate on.
            guard layer.animation(forKey: key) == nil else { return }
            if removesLayer { layer.removeFromSuperlayer() }
            action?()
        }
    }
}
#endif
