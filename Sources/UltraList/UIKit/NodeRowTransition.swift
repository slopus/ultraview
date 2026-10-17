#if canImport(UIKit)
import QuartzCore
import UIKit
import UltraCore

/// How a node row's content enters the first time it is shown, on the
/// timing of the pass that shows it. The row's own geometry stays the
/// pass's: only nodes inside the row move.
@MainActor
public enum NodeRowAppearance {
    /// Keyed nodes grow out of frames in window coordinates, such as a text
    /// field a message was typed in. Frames are read as the row first shows,
    /// and placed where they are on screen when the pass's animations begin.
    case growing(from: @MainActor () -> [(key: String, frame: CGRect)])
    /// Keyed nodes scale and fade in about a corner.
    case appearing([NodeAppearance])
}

/// A node row view's layer. It reports the animations the list adds to it,
/// so the content's node animations can take the same timing.
final class NodeRowLayer: CALayer {
    var onAnimationAdded: (@MainActor (CAAnimation, String) -> Void)?

    override func add(_ animation: CAAnimation, forKey key: String?) {
        super.add(animation, forKey: key)
        guard let key, let onAnimationAdded else { return }
        // The list adds row animations on the main thread, where the
        // callback reads the animation and nothing else holds it.
        nonisolated(unsafe) let added = animation
        MainActor.assumeIsolated { onAnimationAdded(added, key) }
    }
}

/// Identities whose animated node rows are in a window, so a new revision
/// of one is drawn before its pass applies.
@MainActor
enum NodeRowLiveness {
    private struct Entry {
        weak var view: UIView?
    }

    private static var views: [String: [Entry]] = [:]

    static func isLive(_ identity: String) -> Bool {
        guard var entries = views[identity] else { return false }
        entries.removeAll { $0.view?.window == nil }
        views[identity] = entries.isEmpty ? nil : entries
        return !entries.isEmpty
    }

    static func add(_ view: UIView, identity: String) {
        var entries = views[identity, default: []]
        entries.removeAll { $0.view == nil || $0.view === view }
        entries.append(Entry(view: view))
        views[identity] = entries
    }
}

/// The motion of one animated node row's content: when the list replaces
/// the row's revision, the new tree's nodes animate from where the old
/// tree's were, on the timing of the row's own geometry.
///
/// Inside a pass the animations start with the pass's transition, in the
/// transaction that changes the row; when the list then adds the row's
/// height or width animation, they move onto that animation's timing, so a
/// node sized with the row keeps its edges on the row's edges in every
/// frame. Content that arrives after its pass joins the row's running
/// height animation at its phase.
@MainActor
final class NodeRowMotion {
    static let heightKey = "ultraview.list.height"
    static let widthKey = "ultraview.list.width"

    weak var view: UIView?
    /// The host on screen, while its content animates.
    weak var displayed: NodeHostView?
    private var transition: ListTransition?
    private var transitionTime: CFTimeInterval = 0
    /// Within the main-thread turn of a pass that applied to the row.
    private var inPass = false
    /// The content as shown when the latest pass began.
    private var origin: NodeTransitionSnapshot?
    private var originTime: CFTimeInterval = 0
    private var turnEndScheduled = false
    private var turnStart: CFTimeInterval = 0
    private var turnStartTime: CFTimeInterval = 0
    private var passStarted: CFTimeInterval = 0
    private var pendingAppearance: (host: NodeHostView, appearance: NodeRowAppearance)?

    private var now: CFTimeInterval {
        view?.layer.convertTime(CACurrentMediaTime(), from: nil) ?? CACurrentMediaTime()
    }

    /// A pass applies `transition` to the row.
    func passWillApply(_ transition: ListTransition) {
        let started = CACurrentMediaTime()
        defer { MainThreadMonitor.shared.note("node row snapshot \((CACurrentMediaTime() - started) * 1000) ms") }
        passStarted = started
        self.transition = transition
        transitionTime = now
        markTurn()
        if let displayed { origin = displayed.transitionSnapshot(); originTime = transitionTime }
    }

    /// `new` replaces `old` on screen, in the current transaction.
    func show(_ new: NodeHostView, replacing old: NodeHostView?, appearance: NodeRowAppearance?) {
        let started = CACurrentMediaTime()
        defer { MainThreadMonitor.shared.note("node row transition \((CACurrentMediaTime() - started) * 1000) ms") }
        displayed = new
        if let old {
            // The snapshot from the pass's start, unless it is from a pass
            // long gone.
            let fresh = origin.flatMap { now - originTime < 1 ? $0 : nil }
            let start = fresh ?? old.transitionSnapshot()
            origin = nil
            if let timing = replacementTiming() {
                new.animateTransition(from: start, timing: timing)
            } else {
                // A change at once: what still moves with the row keeps
                // moving with it, toward the new layout.
                new.continueTransitions(from: start)
            }
        } else if let appearance {
            // Where a node starts depends on the whole pass (the viewport's
            // motion), which is complete at the end of the turn.
            new.layer.opacity = 0
            pendingAppearance = (new, appearance)
            markTurn()
        }
    }

    /// The list finished a pass that may have changed the row: everything
    /// the pass animates is in place.
    func passDidComplete() {
        guard inPass else { return }
        if passStarted > 0 { MainThreadMonitor.shared.note("node row pass \((CACurrentMediaTime() - passStarted) * 1000) ms") }
        passStarted = 0
        turnDidEnd()
    }

    /// The list added `animation` under `key` to the row's layer.
    func rowDidAnimate(_ animation: CAAnimation, key: String) {
        guard key == Self.heightKey || key == Self.widthKey else { return }
        markTurn()
        // A re-installed animation with an explicit begin keeps a timing the
        // content already follows.
        guard animation.beginTime == 0, let timing = NodeAnimationTiming(matching: animation) else { return }
        if let displayed, displayed.isAnimatingTransition {
            let started = CACurrentMediaTime()
            // Content moves along each axis on the timing of the row's size
            // along it (a turned row sizes its width under the height key).
            let axis = (animation as? CAPropertyAnimation)?.keyPath.flatMap(TransitionAxis.init(keyPath:))
            displayed.retimeTransitions(timing, axis: axis)
            MainThreadMonitor.shared.note("node row retime \((CACurrentMediaTime() - started) * 1000) ms")
        }
    }

    // MARK: Timing

    private func replacementTiming() -> NodeAnimationTiming? {
        if inPass {
            guard let transition, !transition.isImmediate, let view else { return nil }
            return Self.timing(for: transition, in: view)
        }
        // Content that arrived after its pass joins the row's running size
        // animation where the row is along it, from where the content is
        // shown, so it covers the rest of its way as the row covers the rest.
        guard let transition, !transition.isImmediate else { return nil }
        if let layer = view?.layer, let running = layer.animation(forKey: Self.heightKey) as? CABasicAnimation, running.beginTime != 0,
           let timing = NodeAnimationTiming(matching: running), now < timing.beginTime + timing.activeDuration {
            if timing.staysWithinItsEnds, let progress = Self.progress(of: running, on: layer), progress < 0.98 {
                return timing.joined(at: progress)
            }
            // A spring that overshoots would carry the content's overshoot
            // further than the row's; past the end, nothing is left to join.
            return NodeAnimationTiming(duration: 0.15, timingFunction: CAMediaTimingFunction(name: .easeOut))
        }
        // Otherwise only content changes animate, over what is left of the
        // pass's transition.
        guard let view else { return nil }
        let remaining = transitionTime + transition.duration - now
        guard remaining > 0.05 else { return nil }
        return Self.timing(for: .init(duration: remaining, curve: transition.curve), in: view)
    }

    /// The share of its way `animation` has covered on `layer` as shown.
    private static func progress(of animation: CABasicAnimation, on layer: CALayer) -> Double? {
        guard let keyPath = animation.keyPath, let from = (animation.fromValue as? NSNumber)?.doubleValue,
              let to = (animation.toValue as? NSNumber)?.doubleValue, abs(to - from) >= 0.5,
              let shown = (layer.presentation()?.value(forKeyPath: keyPath) as? NSNumber)?.doubleValue else { return nil }
        return max(0, (shown - from) / (to - from))
    }

    /// The timing of animations the pass added in this turn: the row's own,
    /// else the viewport's it moves with, else the pass's transition.
    private func appearanceTiming() -> NodeAnimationTiming? {
        func fresh(_ animation: CAAnimation?) -> NodeAnimationTiming? {
            guard let animation, animation.beginTime == 0 || animation.beginTime >= turnStart - 0.001 else { return nil }
            return NodeAnimationTiming(matching: animation)
        }
        if let layer = view?.layer {
            for key in ["ultraview.list.opacity", "ultraview.list.positionY", Self.heightKey] {
                if let timing = fresh(layer.animation(forKey: key)) { return timing }
            }
            var ancestor = layer.superlayer
            while let current = ancestor {
                if let timing = fresh(current.animation(forKey: "ultraview.list.viewportOffset")) { return timing }
                ancestor = current.superlayer
            }
        }
        guard inPass, let transition, !transition.isImmediate, let view else { return nil }
        return Self.timing(for: transition, in: view)
    }

    /// `transition` as the list compiles it for a row in `view`'s list.
    static func timing(for transition: ListTransition, in view: UIView) -> NodeAnimationTiming? {
        guard !transition.isImmediate else { return nil }
        var scale = 1.0
        var ancestor = view.superview
        while let current = ancestor {
            if let list = current as? UltraListView { scale = list.animationDurationScale; break }
            ancestor = current.superview
        }
        let track = AnimationTrack(generation: 0, from: 0, to: 1, startTime: 0, transition: transition.scaled(by: scale))
        return NodeAnimationTiming(matching: AnimationController.compile(.height, track: track))
    }

    // MARK: Turns

    /// Notes that the current turn changed the row; the end of the turn
    /// finishes what depends on the whole pass.
    private func markTurn() {
        if !inPass { turnStart = now; turnStartTime = CACurrentMediaTime() }
        inPass = true
        guard !turnEndScheduled else { return }
        turnEndScheduled = true
        // The list reports the end of its pass; this is for changes outside
        // one. It runs after the current run loop source, which may be after
        // Core Animation commits the turn.
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [weak self] in
            MainActor.assumeIsolated {
                self?.turnEndScheduled = false
                self?.turnDidEnd()
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    private func turnDidEnd() {
        defer { inPass = false }
        guard let (host, appearance) = pendingAppearance else { return }
        pendingAppearance = nil
        let started = CACurrentMediaTime()
        defer { MainThreadMonitor.shared.note("node row appearance \((CACurrentMediaTime() - started) * 1000) ms") }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        host.layer.opacity = 1
        guard host.superview != nil, let timing = appearanceTiming() else { return }
        switch appearance {
        case .growing(let frames):
            let start = frames().map { (key: $0.key, frame: host.convertFromWindowAtAnimationStart($0.frame, since: turnStartTime)) }
            host.animateTransition(from: NodeTransitionSnapshot(frames: start), timing: timing)
            // The content starts outside the row's slot: let it show there
            // until it arrives.
            if let view, view.clipsToBounds {
                view.clipsToBounds = false
                let restore = max(0.05, timing.beginTime + timing.activeDuration - now) + 0.05
                DispatchQueue.main.asyncAfter(deadline: .now() + (timing.beginTime == 0 ? timing.activeDuration + 0.05 : restore)) { [weak view] in
                    view?.clipsToBounds = true
                }
            }
        case .appearing(let appearances):
            host.animateAppearance(appearances, timing: timing)
        }
    }
}

extension UIView {
    /// `rect`, in window coordinates, in this view's coordinates as they
    /// are when the animations added since `time` (media time) begin: the
    /// frame a node must start at to appear at `rect` on screen when they
    /// start. Ancestors may translate, flip and scale, not rotate.
    func convertFromWindowAtAnimationStart(_ rect: CGRect, since time: CFTimeInterval) -> CGRect {
        let origin = pointInWindowAtAnimationStart(.zero, since: time)
        let unit = pointInWindowAtAnimationStart(CGPoint(x: 1, y: 1), since: time)
        let scaleX = unit.x - origin.x, scaleY = unit.y - origin.y
        guard abs(scaleX) > 1e-9, abs(scaleY) > 1e-9 else { return rect }
        let x0 = (rect.minX - origin.x) / scaleX, x1 = (rect.maxX - origin.x) / scaleX
        let y0 = (rect.minY - origin.y) / scaleY, y1 = (rect.maxY - origin.y) / scaleY
        return CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
    }

    private func pointInWindowAtAnimationStart(_ point: CGPoint, since time: CFTimeInterval) -> CGPoint {
        var point = point
        var current: CALayer? = layer
        let top = window?.layer
        while let layer = current, layer !== top {
            point = layer.pointInSuperlayerAtAnimationStart(point, since: time)
            current = layer.superlayer
        }
        return point
    }
}

extension CALayer {
    /// Model geometry, plus the starting values of additive translations
    /// added since `time`: in the current transaction, or committed since.
    fileprivate func pointInSuperlayerAtAnimationStart(_ point: CGPoint, since time: CFTimeInterval) -> CGPoint {
        var origin = bounds.origin
        var position = self.position
        for key in animationKeys() ?? [] {
            guard let animation = animation(forKey: key) as? CABasicAnimation, animation.isAdditive,
                  animation.beginTime == 0 || convertTime(animation.beginTime, to: nil) >= time - 0.001,
                  let from = (animation.fromValue as? NSNumber)?.doubleValue else { continue }
            switch animation.keyPath {
            case "bounds.origin.x": origin.x += from
            case "bounds.origin.y": origin.y += from
            case "position.x": position.x += from
            case "position.y": position.y += from
            default: break
            }
        }
        let size = bounds.size
        let local = CGPoint(x: point.x - origin.x - anchorPoint.x * size.width, y: point.y - origin.y - anchorPoint.y * size.height)
        let mapped = local.applying(CATransform3DGetAffineTransform(transform))
        return CGPoint(x: position.x + mapped.x, y: position.y + mapped.y)
    }
}
#endif
