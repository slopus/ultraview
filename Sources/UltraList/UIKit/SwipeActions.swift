#if canImport(UIKit)
import UIKit
import QuartzCore
import UltraCore

/// A button revealed by swiping a row. The first action of a side sits at the
/// row edge and is also performed by a full swipe.
@MainActor
public struct ListSwipeAction {
    public var title: String
    public var image: UIImage?
    public var color: UIColor
    public var isDestructive: Bool
    public var width: Double
    public var handler: @MainActor () -> Void
    public init(title: String, image: UIImage? = nil, color: UIColor? = nil, isDestructive: Bool = false, width: Double = 76, handler: @escaping @MainActor () -> Void) {
        self.title = title; self.image = image; self.color = color ?? (isDestructive ? .systemRed : .systemGray)
        self.isDestructive = isDestructive; self.width = width; self.handler = handler
    }
}

/// Reveals one row's actions at a time. The row's content moves through its
/// layer's `sublayerTransform`, which the list leaves alone; buttons are
/// sublayers of the row, so list animations carry them.
@MainActor
public final class ListSwipeController: NSObject, UIGestureRecognizerDelegate {
    public enum Side: Sendable { case leading, trailing }
    /// Moves a released row to rest. Spring curves keep the finger's velocity.
    public var transition: ListTransition = .spring(0.5)
    public var allowsFullSwipe = true
    public var revealedIdentity: String? { registry.active }
    var onChange: ((String) -> Void)?
    private(set) weak var list: UltraListView?
    let pan = RevealPan()
    let tap = RevealTap()
    private var registry = SwipeRegistry<String>()
    private var reveals: [String: Reveal] = [:]
    private var tracking: (identity: String, start: Double)?
    private let haptics = UIImpactFeedbackGenerator(style: .medium)
    private(set) var hapticCount = 0
    private var reconciled: (pass: UInt64, range: Range<Int>, count: Int)?
    private var labels: [LabelKey: CGImage] = [:]
    private var pendingLabels: Set<LabelKey> = []
    private var customActionOwners: [ObjectIdentifier: [UIAccessibilityCustomAction]] = [:]
    static let animationKey = "ultraview.swipe"

    func attach(to list: UltraListView) {
        self.list = list
        pan.delegate = self; pan.addTarget(self, action: #selector(panned))
        pan.maximumNumberOfTouches = 1
        tap.delegate = self; tap.addTarget(self, action: #selector(tapped))
        tap.isEnabled = false
        pan.controller = self; tap.controller = self
        list.addGestureRecognizer(pan); list.addGestureRecognizer(tap)
        listPan(of: list)?.addTarget(self, action: #selector(listPanned(_:)))
    }

    // MARK: Public control

    public func close(animated: Bool = true) {
        for identity in Array(reveals.keys) { settle(identity, to: .closed, velocity: 0, animated: animated) }
    }

    // MARK: Gesture input

    private func listPan(of list: UltraListView) -> UIPanGestureRecognizer? {
        (list.engine as? PhysicsEngine)?.pan ?? (list.engine as? PlatformEngine)?.scroll.panGestureRecognizer
    }
    var listIsMoving: Bool {
        guard let list else { return false }
        // The engine's own state covers replayed and programmatic momentum too.
        if list.isDecelerating || list.isDragging || list.isScrollFlightActive { return true }
        // A forced pan caught moving content in this touch, whichever recognizer saw it first.
        return (list.engine as? PhysicsEngine)?.pan.forced == true
    }
    /// A touch on moving content catches it. The list's pan takes that touch
    /// at once, which it can only do if no reveal is still pending.
    public func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        recognizer !== pan || !listIsMoving
    }
    private var rightToLeft: Bool { list?.effectiveUserInterfaceLayoutDirection == .rightToLeft }
    private func edgeIsRight(_ side: Side) -> Bool { (side == .trailing) != rightToLeft }
    /// The row under a point in the list's coordinates.
    func row(at point: CGPoint) -> (identity: String, index: Int, view: ListRowView)? {
        guard let list else { return nil }
        for index in list.loadedIndexRange {
            guard let view = list.loadedItemView(at: index), view.convert(view.bounds, to: list).contains(point) else { continue }
            return (list.items[index].identity, index, view)
        }
        return nil
    }
    func actions(_ identity: String, _ side: Side) -> [ListSwipeAction] {
        guard let list, let index = list.index(forRowIdentity: identity) else { return [] }
        let item = list.items[index]
        return side == .leading ? item.leadingSwipeActions : item.trailingSwipeActions
    }
    func hasActions(_ identity: String) -> Bool { !actions(identity, .leading).isEmpty || !actions(identity, .trailing).isEmpty }

    @objc private func listPanned(_ recognizer: UIPanGestureRecognizer) {
        if recognizer.state == .began, !reveals.isEmpty { close() }
    }
    @objc private func panned() {
        guard let list, let candidate = pan.candidate else { return }
        let started = CACurrentMediaTime(), phase = pan.state.rawValue
        defer { MainThreadMonitor.shared.note("swipe pan \(phase) \((CACurrentMediaTime() - started) * 1000) ms") }
        let dx = pan.translation(in: list).x
        switch pan.state {
        case .began: beginTracking(candidate, dx: dx)
        case .changed: continueTracking(candidate, dx: dx)
        case .ended: endTracking(candidate, velocity: pan.velocity(in: list).x)
        case .cancelled: endTracking(candidate, velocity: 0)
        default: break
        }
    }
    /// Feeds a recorded or shared horizontal gesture on the row `identity`
    /// without synthesizing UIKit touches. Translation and velocity are along
    /// the list's x axis, in points and points per second. A gesture begins
    /// under a touch's rules: the row has actions or is revealed, and the list
    /// is still. Input comes from one source at a time.
    public func receiveInput(_ event: GestureRecording.Event, row identity: String) {
        switch event.phase {
        case .touchDown: break
        case .began:
            guard tracking == nil, !listIsMoving, currentRow(identity) != nil,
                  hasActions(identity) || registry.active == identity else { return }
            beginTracking(identity, dx: event.translation.x)
        case .changed: continueTracking(identity, dx: event.translation.x)
        case .ended: endTracking(identity, velocity: event.velocity.x)
        case .cancelled: endTracking(identity, velocity: 0)
        }
    }
    private func beginTracking(_ identity: String, dx: Double) {
        haptics.prepare()
        if let closing = registry.begin(identity) { settle(closing, to: .closed, velocity: 0, animated: true) }
        let reveal = catchReveal(identity)
        let start = reveal.map { proposed(for: $0.offset, reveal: $0) } ?? 0
        tracking = (identity, start)
        track(identity, proposedOffset: start + dx)
    }
    private func continueTracking(_ identity: String, dx: Double) {
        guard let tracking = tracked(identity) else { return }
        track(identity, proposedOffset: tracking.start + dx)
    }
    private func endTracking(_ identity: String, velocity: Double) {
        guard tracked(identity) != nil else { return }
        self.tracking = nil
        release(identity, velocity: velocity)
    }
    /// The gesture on `identity`, while that row is still the revealed one.
    /// Closing it (`close()`, an action, a reconcile) ends the gesture's hold
    /// on it: later movement must not reveal a row the registry doesn't know.
    private func tracked(_ identity: String) -> (identity: String, start: Double)? {
        guard let tracking, tracking.identity == identity else { return nil }
        guard registry.active == identity else { self.tracking = nil; return nil }
        return tracking
    }
    @objc private func tapped() {
        guard tap.state == .ended, let identity = registry.active else { return }
        let started = CACurrentMediaTime()
        defer { MainThreadMonitor.shared.note("swipe tap \((CACurrentMediaTime() - started) * 1000) ms") }
        if let button = tap.button, let reveal = reveals[identity], let side = reveal.side {
            let actions = actions(identity, side)
            if actions.indices.contains(button) { perform(actions[button], identity: identity, side: side, index: button) }
        } else { close() }
    }

    public func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer === pan, let list, let candidate = pan.candidate else { return true }
        let translation = pan.translation(in: list)
        var lock = AxisLock(slop: 0)
        guard lock.force(dx: translation.x, dy: translation.y) == .horizontal else { return false }
        // A closed row only starts toward a side that has actions.
        if reveals[candidate].map({ abs($0.offset) > 0.5 }) == true { return true }
        let rightEdge: Side = rightToLeft ? .leading : .trailing, leftEdge: Side = rightToLeft ? .trailing : .leading
        return !actions(candidate, translation.x < 0 ? rightEdge : leftEdge).isEmpty
    }
    public func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        // The list's own pan, the keyboard pan on the list and every ancestor's
        // pan wait until a horizontal reveal is ruled out.
        guard recognizer === pan, let list, let view = other.view, other is UIPanGestureRecognizer,
              !(other is UIScreenEdgePanGestureRecognizer), other !== pan else { return false }
        return view === list.contentView || list.isDescendant(of: view)
    }
    public func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        guard recognizer === tap || other === tap, let list else { return false }
        let peer = recognizer === tap ? other : recognizer
        guard let view = peer.view else { return false }
        return peer === pan || view === list.contentView || list.isDescendant(of: view)
    }

    // MARK: Motion

    private func layout(_ identity: String, _ side: Side, width: Double) -> SwipeRevealLayout {
        let actions = actions(identity, side)
        return .init(widths: actions.map(\.width), rowWidth: width, allowsFullSwipe: allowsFullSwipe)
    }
    /// The finger position that shows `offset`.
    private func proposed(for offset: Double, reveal: Reveal) -> Double {
        guard abs(offset) > 1e-9 else { return 0 }
        let side = side(forOffset: offset), magnitude = layout(reveal.identity, side, width: reveal.rowWidth).proposed(abs(offset))
        return offset < 0 ? -magnitude : magnitude
    }
    private func side(forOffset offset: Double) -> Side {
        let rightEdge: Side = rightToLeft ? .leading : .trailing
        return offset < 0 ? rightEdge : (rightEdge == .trailing ? .leading : .trailing)
    }
    /// Stops a moving row where it is shown and makes that its model state.
    private func catchReveal(_ identity: String) -> Reveal? {
        guard let reveal = reveals[identity], let view = reveal.view else { return nil }
        let presented = (view.layer.presentation()?.value(forKeyPath: "sublayerTransform.translation.x") as? Double) ?? reveal.offset
        reveal.generation &+= 1
        removeAnimations(reveal)
        apply(reveal, offset: presented, expanded: reveal.expanded, animated: nil)
        return reveal
    }
    private func track(_ identity: String, proposedOffset: Double) {
        guard let row = currentRow(identity), reveals[identity] != nil || hasActions(identity) else { return }
        let reveal = reveals[identity] ?? makeReveal(identity, view: row.view)
        let side = side(forOffset: proposedOffset)
        let layout = layout(identity, side, width: reveal.rowWidth)
        let shown = layout.displayed(abs(proposedOffset)) * (proposedOffset < 0 ? -1 : 1)
        let expanded = layout.isExpanded(abs(shown))
        if expanded, !reveal.expanded, reveal.hapticArmed {
            haptics.impactOccurred(); hapticCount += 1; reveal.hapticArmed = false
        }
        if let threshold = layout.fullSwipeThreshold, abs(shown) < threshold - 16 { reveal.hapticArmed = true }
        let crossing = expanded != reveal.expanded && reveal.side == side
        apply(reveal, offset: shown, expanded: expanded, animated: crossing ? .spring(0.3832) : nil, layoutOnly: true)
    }
    private func release(_ identity: String, velocity: Double) {
        guard let reveal = reveals[identity] else { registry.remove(identity); return }
        let side = side(forOffset: reveal.offset)
        let layout = layout(identity, side, width: reveal.rowWidth)
        let opening = edgeIsRight(side) ? -velocity : velocity
        let outcome = abs(reveal.offset) < 1e-9 ? .closed : SwipeRelease.decide(reveal: abs(reveal.offset), velocity: opening, openWidth: layout.openWidth, fullSwipeThreshold: layout.fullSwipeThreshold)
        settle(identity, to: outcome, velocity: velocity, animated: true)
        if outcome == .fullSwipe, let action = actions(identity, side).first {
            perform(action, identity: identity, side: side, index: 0)
        }
    }
    private func perform(_ action: ListSwipeAction, identity: String, side: Side, index: Int) {
        action.handler()
        // A row the handler kept closes; a removed row departs with its buttons.
        if list?.index(forRowIdentity: identity) != nil, reveals[identity] != nil { settle(identity, to: .closed, velocity: 0, animated: true) }
    }
    private func settle(_ identity: String, to outcome: SwipeOutcome, velocity: Double, animated: Bool) {
        guard let reveal = reveals[identity] else { registry.remove(identity); return }
        registry.settle(identity, outcome: outcome)
        if outcome == .closed, registry.active == identity { registry.remove(identity) }
        let side = reveal.side ?? .trailing
        let layout = layout(identity, side, width: reveal.rowWidth)
        let target = layout.target(outcome) * (edgeIsRight(side) ? -1 : 1)
        let motion = SwipeMotion(from: reveal.offset, to: target, velocity: velocity, transition: animated ? transition : .immediate)
        reveal.generation &+= 1
        let generation = reveal.generation
        CATransaction.begin()
        if outcome == .closed {
            CATransaction.setCompletionBlock { [weak self, weak reveal] in
                guard let self, let reveal, reveal.generation == generation, reveals[identity] === reveal else { return }
                finish(reveal)
            }
        }
        apply(reveal, offset: target, expanded: outcome == .fullSwipe, animated: animated ? transition : nil, motion: motion)
        CATransaction.commit()
        tap.isEnabled = registry.active != nil
        onChange?(identity)
    }
    /// Removes a closed row's buttons and gives back its clipping.
    private func finish(_ reveal: Reveal) {
        guard abs(reveal.offset) < 1e-9 else { return }
        reveals.removeValue(forKey: reveal.identity)
        guard let view = reveal.view else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        removeAnimations(reveal)
        for button in reveal.buttons { button.removeFromSuperlayer() }
        view.layer.sublayerTransform = CATransform3DIdentity
        view.layer.masksToBounds = reveal.savedMasks
        CATransaction.commit()
        onChange?(reveal.identity)
    }
    private func currentRow(_ identity: String) -> (index: Int, view: ListRowView)? {
        guard let list, let index = list.index(forRowIdentity: identity), let view = list.loadedItemView(at: index) else { return nil }
        return (index, view)
    }
    private func makeReveal(_ identity: String, view: ListRowView) -> Reveal {
        assert(CATransform3DIsIdentity(view.layer.sublayerTransform), "Swipe actions own the row layer's sublayerTransform")
        let reveal = Reveal(identity: identity, view: view)
        reveals[identity] = reveal
        return reveal
    }
    private func removeAnimations(_ reveal: Reveal) {
        for layer in reveal.buttons + [reveal.view?.layer].compactMap({ $0 }) {
            for key in layer.animationKeys() ?? [] where key.hasPrefix(Self.animationKey) { layer.removeAnimation(forKey: key) }
        }
    }

    /// Writes the model state and, if asked, animates there from the current
    /// model state. `layoutOnly` animates only a change of button layout and
    /// leaves the content on the finger.
    private func apply(_ reveal: Reveal, offset: Double, expanded: Bool, animated transition: ListTransition?, layoutOnly: Bool = false, motion: SwipeMotion? = nil) {
        guard let view = reveal.view else { return }
        let side = side(forOffset: offset == 0 ? reveal.offset : offset)
        if reveal.side != side || reveal.buttons.isEmpty { rebuildButtons(reveal, side: side) }
        let layout = layout(reveal.identity, side, width: reveal.rowWidth)
        let oldOffset = reveal.offset
        let oldFrames = buttonFrames(reveal, layout: layout, offset: layoutOnly ? offset : oldOffset, expanded: reveal.expanded)
        let frames = buttonFrames(reveal, layout: layout, offset: offset, expanded: expanded)
        reveal.offset = offset; reveal.expanded = expanded
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if !view.layer.masksToBounds { view.layer.masksToBounds = true }
        view.layer.sublayerTransform = CATransform3DMakeTranslation(offset, 0, 0)
        for (button, frame) in zip(reveal.buttons, frames) {
            button.position = .init(x: frame.x, y: 0)
            button.bounds = .init(x: 0, y: 0, width: frame.width, height: reveal.rowHeight)
        }
        CATransaction.commit()
        guard let transition, !transition.isImmediate else { return }
        // Every animated value is affine in the reveal, so one normalized
        // velocity and curve keep the buttons on the content's edge.
        let normalized = motion?.normalizedVelocity ?? 0
        func add(_ layer: CALayer, _ keyPath: String, from: Double, to: Double) {
            guard abs(from - to) > 1e-6 else { return }
            let track = AnimationTrack(generation: reveal.generation, from: from - to, to: 0, startTime: 0, transition: transition)
            let animation = AnimationController.compile(.width, track: track)
            animation.keyPath = keyPath; animation.isAdditive = true
            animation.isRemovedOnCompletion = true; animation.fillMode = .backwards
            animation.preferredFrameRateRange = .init(minimum: 30, maximum: 120, preferred: 120)
            if let spring = animation as? CASpringAnimation { spring.initialVelocity = normalized }
            reveal.serial &+= 1
            layer.add(animation, forKey: "\(Self.animationKey).\(keyPath).\(reveal.serial)")
        }
        if !layoutOnly { add(view.layer, "sublayerTransform.translation.x", from: oldOffset, to: offset) }
        for (button, (old, new)) in zip(reveal.buttons, zip(oldFrames, frames)) {
            add(button, "position.x", from: old.x, to: new.x)
            add(button, "bounds.size.width", from: old.width, to: new.width)
        }
    }
    /// Button frames in the row's sublayer space, where the content is drawn.
    private func buttonFrames(_ reveal: Reveal, layout: SwipeRevealLayout, offset: Double, expanded: Bool) -> [(x: Double, width: Double)] {
        let spans = layout.spans(reveal: abs(offset), expanded: expanded)
        let right = offset < 0 || (offset == 0 && reveal.side.map(edgeIsRight) == true)
        return spans.map { span in
            // Screen-space span measured from the edge, then into sublayer space.
            let minX = right ? reveal.rowWidth - span.upperBound : span.lowerBound
            return (minX - offset, span.upperBound - span.lowerBound)
        }
    }
    private func rebuildButtons(_ reveal: Reveal, side: Side) {
        guard let view = reveal.view else { return }
        for button in reveal.buttons { button.removeFromSuperlayer() }
        reveal.side = side
        let actions = actions(reveal.identity, side)
        let traits = view.traitCollection, scale = traits.displayScale > 0 ? traits.displayScale : 3
        reveal.buttons = actions.map { action in
            let layer = CALayer()
            layer.anchorPoint = .zero; layer.masksToBounds = true
            layer.backgroundColor = action.color.resolvedColor(with: traits).cgColor
            layer.contentsGravity = .center; layer.contentsScale = scale
            layer.contents = label(for: action, traits: traits)
            layer.name = "swipe:\(action.title)"
            return layer
        }
        // The edge-most button covers the others when it expands.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for layer in reveal.buttons.reversed() { view.layer.addSublayer(layer) }
        CATransaction.commit()
    }

    // MARK: Labels

    private struct LabelKey: Hashable { var title: String; var image: ObjectIdentifier?; var scale: Double; var size: Double }
    private var fontSizes: [UIContentSizeCategory: Double] = [:]
    /// Labels are drawn off the main thread and requested as rows with actions
    /// load, so a reveal finds them ready; a button shows its colour until then.
    private func label(for action: ListSwipeAction, traits: UITraitCollection) -> CGImage? {
        let scale = traits.displayScale > 0 ? traits.displayScale : 3
        let category = traits.preferredContentSizeCategory
        let size = fontSizes[category] ?? UIFontMetrics.default.scaledValue(for: 15, compatibleWith: traits)
        fontSizes[category] = size
        let key = LabelKey(title: action.title, image: action.image.map(ObjectIdentifier.init), scale: scale, size: size)
        if let image = labels[key] { return image }
        guard pendingLabels.insert(key).inserted else { return nil }
        let title = action.title, icon = action.image
        Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) { Self.renderLabel(title: title, icon: icon, scale: scale, size: size) }.value
            guard let self else { return }
            pendingLabels.remove(key)
            guard let image else { return }
            labels[key] = image
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for reveal in reveals.values { for layer in reveal.buttons where layer.contents == nil && layer.name == "swipe:\(title)" { layer.contents = image } }
            CATransaction.commit()
        }
        return nil
    }
    nonisolated private static func renderLabel(title: String, icon: UIImage?, scale: Double, size: Double) -> CGImage? {
        let font = UIFont.systemFont(ofSize: size, weight: .semibold)
        let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: UIColor.white])
        let textSize = text.boundingRect(with: .init(width: 160, height: 100), options: [.usesLineFragmentOrigin], context: nil).size
        let iconSize = icon.map { _ in CGSize(width: 22, height: 22) } ?? .zero
        let gap = icon == nil ? 0 : 4.0
        let width = ceil(max(textSize.width, iconSize.width)), height = ceil(textSize.height + iconSize.height + gap)
        guard width > 0, height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat(); format.scale = scale; format.opaque = false
        let image = UIGraphicsImageRenderer(size: .init(width: width, height: height), format: format).image { _ in
            if let icon {
                icon.withTintColor(.white, renderingMode: .alwaysOriginal).draw(in: .init(x: (width - iconSize.width) / 2, y: 0, width: iconSize.width, height: iconSize.height))
            }
            text.draw(with: .init(x: (width - textSize.width) / 2, y: iconSize.height + gap, width: textSize.width, height: textSize.height), options: [.usesLineFragmentOrigin], context: nil)
        }
        return image.cgImage
    }

    // MARK: Reconciliation

    /// Called after each list pass and window change. Cheap unless the window changed.
    func reconcile() {
        guard let list else { return }
        let state = (list.appliedPassCount, list.loadedIndexRange, list.items.count)
        if let reconciled, reconciled.pass == state.0, reconciled.range == state.1, reconciled.count == state.2 { return }
        reconciled = state
        let started = CACurrentMediaTime()
        defer { MainThreadMonitor.shared.note("swipe reconcile \((CACurrentMediaTime() - started) * 1000) ms") }
        for (identity, reveal) in reveals {
            guard let view = reveal.view else { reveals.removeValue(forKey: identity); registry.remove(identity); continue }
            if list.index(forRowIdentity: identity) == nil {
                // Deleted: the departing view keeps its buttons and collapses with the row.
                reveals.removeValue(forKey: identity); registry.remove(identity)
                if tracking?.identity == identity { tracking = nil }
                collapse(view)
                continue
            }
            guard let current = currentRow(identity), current.view === view else {
                reveals.removeValue(forKey: identity); registry.remove(identity)
                reveal.offset = 0; finish(reveal); continue
            }
            if abs(view.bounds.width - reveal.rowWidth) > 0.5 || abs(view.bounds.height - reveal.rowHeight) > 0.5 || reveal.side.map({ actions(identity, $0).count != reveal.buttons.count }) == true {
                let offset = reveal.offset, expanded = reveal.expanded
                reveal.rowWidth = view.bounds.width; reveal.rowHeight = view.bounds.height
                if reveal.side.map({ actions(identity, $0).isEmpty }) == true {
                    reveal.offset = 0; registry.remove(identity); finish(reveal); continue
                }
                reveal.buttons.forEach { $0.removeFromSuperlayer() }; reveal.buttons = []
                apply(reveal, offset: offset, expanded: expanded, animated: nil)
                if let resize = view.layer.animation(forKey: "ultraview.list.height") {
                    for button in reveal.buttons { button.add(resize, forKey: "\(Self.animationKey).height") }
                }
            }
        }
        tap.isEnabled = registry.active != nil
        updateCustomActions()
    }
    /// A revealed row that is deleted shrinks to nothing on its fade's timing,
    /// keeping the edge whose neighbour stays still, so the rows sliding into
    /// its place stay against it.
    private func collapse(_ view: ListRowView) {
        guard let list, view.superview != nil, let fade = view.layer.animation(forKey: "ultraview.list.opacity") as? CABasicAnimation else { return }
        let space = list.contentView, ghost = view.convert(view.bounds, to: space)
        let neighbours = list.loadedIndexRange.compactMap { list.loadedItemView(at: $0) }.map { ($0, $0.convert($0.bounds, to: space)) }
        // A row moves through its position track or through the position layers its neighbours' heights add.
        func moving(_ entry: (ListRowView, CGRect)?) -> Bool? {
            entry.map { $0.0.layer.animationKeys()?.contains { $0 == "ultraview.list.positionY" || $0.hasPrefix("ultraview.list.size") } == true }
        }
        let below = neighbours.filter { $0.1.minY >= ghost.minY - 0.5 }.min { $0.1.minY < $1.1.minY }
        let above = neighbours.filter { $0.1.maxY <= ghost.maxY + 0.5 }.max { $0.1.maxY < $1.1.maxY }
        let keepsTop = moving(below) ?? !(moving(above) ?? false)
        let size = view.bounds.size
        func copy(_ keyPath: String, from: Double, to: Double, additive: Bool) {
            guard let animation = fade.copy() as? CABasicAnimation else { return }
            animation.keyPath = keyPath; animation.fromValue = from; animation.toValue = to
            animation.isAdditive = additive; animation.delegate = nil
            animation.fillMode = .both; animation.isRemovedOnCompletion = false
            view.layer.add(animation, forKey: "\(Self.animationKey).collapse.\(keyPath)")
        }
        copy("bounds.size.height", from: size.height, to: 0, additive: false)
        // Placement accounts for a flipped row, whose layer grows upward from its position.
        let start = view.placementOffset(size: size), end = view.placementOffset(size: .init(width: size.width, height: 0))
        let shift = (keepsTop ? 0 : size.height) + end.y - start.y
        if abs(shift) > 1e-6 { copy("position.y", from: 0, to: shift, additive: true) }
        view.layer.masksToBounds = true
    }
    private func updateCustomActions() {
        guard let list else { return }
        var owned: [ObjectIdentifier: [UIAccessibilityCustomAction]] = [:]
        let traits = list.traitCollection
        for index in list.loadedIndexRange {
            guard let view = list.loadedItemView(at: index) else { continue }
            let item = list.items[index], identity = item.identity, key = ObjectIdentifier(view)
            for action in item.leadingSwipeActions + item.trailingSwipeActions { _ = label(for: action, traits: traits) }
            let entries = item.leadingSwipeActions.enumerated().map { (Side.leading, $0.offset, $0.element.title) }
                + item.trailingSwipeActions.enumerated().map { (Side.trailing, $0.offset, $0.element.title) }
            let previous = customActionOwners[key]
            // Custom actions the row set itself are left alone.
            let current = view.accessibilityCustomActions ?? []
            let ownsCurrent = previous.map { current.elementsEqual($0, by: ===) } ?? current.isEmpty
            guard ownsCurrent else { continue }
            if entries.isEmpty {
                if previous != nil { view.accessibilityCustomActions = nil }
                continue
            }
            let names = entries.map(\.2)
            if let previous, previous.map(\.name) == names, previous.count == names.count {
                owned[key] = previous; continue
            }
            let custom = entries.map { side, offset, title in
                UIAccessibilityCustomAction(name: title) { [weak self] _ in
                    // Look the action up again so a newer row revision's handler runs.
                    guard let self else { return false }
                    let actions = actions(identity, side)
                    guard actions.indices.contains(offset) else { return false }
                    perform(actions[offset], identity: identity, side: side, index: offset)
                    return true
                }
            }
            view.accessibilityCustomActions = custom; owned[key] = custom
        }
        customActionOwners = owned
    }

    // MARK: Testing

    /// Drives a reveal without touches, as a pan on the row would.
    func simulateBegin(_ identity: String) {
        if let closing = registry.begin(identity) { settle(closing, to: .closed, velocity: 0, animated: true) }
        let reveal = catchReveal(identity)
        tracking = (identity, reveal.map { proposed(for: $0.offset, reveal: $0) } ?? 0)
    }
    func simulateDrag(_ dx: Double) {
        guard let tracking else { return }
        continueTracking(tracking.identity, dx: dx)
    }
    func simulateRelease(velocity: Double) {
        guard let tracking else { return }
        endTracking(tracking.identity, velocity: velocity)
    }
    func simulateTap(button: Int?) {
        guard let identity = registry.active else { return }
        if let button, let side = reveals[identity]?.side {
            let actions = actions(identity, side)
            if actions.indices.contains(button) { perform(actions[button], identity: identity, side: side, index: button) }
        } else { close() }
    }
    func revealOffset(_ identity: String) -> Double? { reveals[identity]?.offset }
    func buttonLayers(_ identity: String) -> [CALayer] { reveals[identity]?.buttons ?? [] }
}

@MainActor
final class Reveal {
    let identity: String
    weak var view: ListRowView?
    var side: ListSwipeController.Side?
    var offset = 0.0
    var expanded = false
    var hapticArmed = true
    var buttons: [CALayer] = []
    var rowWidth: Double
    var rowHeight: Double
    var savedMasks: Bool
    var generation: UInt64 = 0
    var serial: UInt64 = 0
    init(identity: String, view: ListRowView) {
        self.identity = identity; self.view = view
        rowWidth = view.bounds.width; rowHeight = view.bounds.height; savedMasks = view.layer.masksToBounds
    }
}

/// Begins only for a mostly horizontal motion on a row that can reveal.
@MainActor
final class RevealPan: UIPanGestureRecognizer {
    weak var controller: ListSwipeController?
    private(set) var candidate: String?
    override func reset() { super.reset(); candidate = nil }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard candidate == nil else { return }
        guard let controller, let list = controller.list, let touch = touches.first, !controller.listIsMoving,
              let row = controller.row(at: touch.location(in: list)),
              controller.hasActions(row.identity) || controller.revealedIdentity == row.identity else {
            state = .failed; return
        }
        candidate = row.identity
    }
}

/// While a row is revealed, a tap on a button performs it and any other tap
/// closes the row without reaching the content beneath.
@MainActor
final class RevealTap: UIGestureRecognizer {
    weak var controller: ListSwipeController?
    private(set) var button: Int?
    private var start = CGPoint.zero
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = true; delaysTouchesBegan = false; delaysTouchesEnded = false
    }
    override func reset() { super.reset(); button = nil }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let controller, let list = controller.list, let touch = touches.first, let identity = controller.revealedIdentity,
              let revealed = controller.buttonFrames(of: identity) else { state = .failed; return }
        start = touch.location(in: list)
        guard let row = controller.row(at: start), row.identity == identity else {
            state = .ended; return
        }
        let x = row.view.convert(start, from: list).x
        button = revealed.firstIndex { $0.contains(x) }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let list = controller?.list, let touch = touches.first else { return }
        let point = touch.location(in: list)
        if hypot(point.x - start.x, point.y - start.y) > 10 { state = .failed }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { if state == .possible { state = .ended } }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
}

extension ListSwipeController {
    /// The shown buttons' horizontal spans in row coordinates, edge-most first.
    func buttonFrames(of identity: String) -> [ClosedRange<Double>]? {
        guard let reveal = reveals[identity], let view = reveal.view else { return nil }
        let offset = (view.layer.presentation()?.value(forKeyPath: "sublayerTransform.translation.x") as? Double) ?? reveal.offset
        return reveal.buttons.map { button in
            let layer = button.presentation() ?? button
            let minX = layer.position.x + offset
            return minX...(minX + layer.bounds.width)
        }
    }
}
#endif
