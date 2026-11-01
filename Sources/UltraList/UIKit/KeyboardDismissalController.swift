#if canImport(UIKit)
import UIKit

/// Opt-in keyboard dismissal driven together with an app's accessory and list.
/// Call `refresh()` after layout and `invalidate()` when the owner leaves its window.
/// The callback must apply its inset and accessory frame synchronously. Its supplied
/// transition uses the keyboard's release curve; the client resolves its resting inset.
/// Private keyboard hierarchy access is optional. A docked keyboard it can't move
/// is left to the scroll view's system interactive dismissal; with no keyboard up
/// the scroll view keeps no keyboard input.
/// Release this controller on the main thread, as required by its UIKit resources.
@MainActor
public final class KeyboardDismissalController: NSObject {
    enum Ownership: Equatable { case idle, tracking, returning, dismissing, awaitingHide, recoveringShow }
    private(set) var ownership = Ownership.idle
    private weak var coordinateView: UIView?
    private weak var scrollView: UltraScrollView?
    private weak var attachedWindow: UIWindow?
    private var recognizer: KeyboardDismissalRecognizer?
    private var layoutCommitView: KeyboardDismissalLayoutView?
    private enum LayoutChange {
        case tracking(KeyboardDismissalGesture.Tracking)
        case release(KeyboardDismissalGesture.Release)
    }
    private var pendingLayout: (generation: UInt64, change: LayoutChange)?
    private var host: KeyboardHostLookup.Host?
    private var gesture = KeyboardDismissalGesture()
    private var generation: UInt64 = 0
    private var updateRequest: UInt64 = 0
    private var keyboardTop = 0.0
    private var offset = 0.0
    private var touchHasClaimed = false
    /// The last `begin` found the keyboard still on its way into place.
    fileprivate private(set) var beginWaitsForHost = false
    private let hasInput: () -> Bool
    private let lookupHost: (UIWindowScene?) -> KeyboardHostLookup.Host?
    private let accessoryHeight: () -> Double
    private let restingHeight: () -> Double
    private let update: (KeyboardDismissalUpdate) -> Void
    private static let animationKey = "ultraview.keyboard.dismissal"

    public private(set) var isAvailable = false
    /// True while finger or release motion owns the app's keyboard inset.
    public var isDriving: Bool { ownership != .idle }
    public var dismissedInTouchSequence: Bool { gesture.dismissedInTouchSequence }
    /// Return false for a touched view or any ancestor to decline this gesture.
    public var shouldBegin: ((UIView) -> Bool)?

    public convenience init(scrollView: UltraScrollView, coordinateView: UIView,
                accessoryHeight: @escaping () -> Double, restingHeight: @escaping () -> Double, hasInput: @escaping () -> Bool,
                update: @escaping (KeyboardDismissalUpdate) -> Void) {
        self.init(scrollView: scrollView, coordinateView: coordinateView, accessoryHeight: accessoryHeight,
                  restingHeight: restingHeight, hasInput: hasInput, lookupHost: { KeyboardHostLookup.find(in: $0) }, update: update)
    }

    init(scrollView: UltraScrollView, coordinateView: UIView,
         accessoryHeight: @escaping () -> Double, restingHeight: @escaping () -> Double, hasInput: @escaping () -> Bool,
         lookupHost: @escaping (UIWindowScene?) -> KeyboardHostLookup.Host?, update: @escaping (KeyboardDismissalUpdate) -> Void) {
        self.scrollView = scrollView; self.coordinateView = coordinateView
        self.accessoryHeight = accessoryHeight; self.restingHeight = restingHeight; self.hasInput = hasInput; self.update = update
        self.lookupHost = lookupHost
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged), name: UIResponder.keyboardDidShowNotification, object: nil)
    }

    private func takeOwnership(_ value: Ownership) {
        generation &+= 1
        pendingLayout = nil
        ownership = value
    }

    deinit {
        MainActor.assumeIsolated {
            NotificationCenter.default.removeObserver(self)
            if let recognizer { attachedWindow?.removeGestureRecognizer(recognizer) }
            layoutCommitView?.removeFromSuperview()
            if isDriving, let host {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                host.view.layer.removeAnimation(forKey: Self.animationKey)
                host.view.layer.bounds.origin.y = 0
                CATransaction.commit()
            }
        }
    }

    /// Re-resolves the optional keyboard host and attaches to the client's window.
    public func refresh() {
        guard let view = coordinateView, let window = view.window else { invalidate(); return }
        if attachedWindow !== window {
            if let recognizer { attachedWindow?.removeGestureRecognizer(recognizer) }
            layoutCommitView?.removeFromSuperview(); pendingLayout = nil
            let input = KeyboardDismissalRecognizer(owner: self)
            window.addGestureRecognizer(input); recognizer = input; attachedWindow = window
            let commitView = KeyboardDismissalLayoutView(owner: self)
            window.addSubview(commitView); layoutCommitView = commitView
        }
        guard !isDriving else { return }
        host = lookupHost(window.windowScene)
        if let found = host {
            let frame = KeyboardHostLookup.frame(of: found, in: window)
            if frame.width < window.bounds.width - 1 || abs(frame.maxY - window.bounds.maxY) > 1 { host = nil }
        }
        isAvailable = host != nil
        let docked = KeyboardFrameTracker.shared.dockedTop(in: window) != nil
        setScrollMode(KeyboardInputPolicy.controllerMode(drivesKeyboard: isAvailable, keyboardDocked: docked))
    }

    private func setScrollMode(_ mode: KeyboardInputPolicy.Mode) {
        let value: UIScrollView.KeyboardDismissMode = mode == .interactive ? .interactive : .none
        if scrollView?.keyboardDismissMode != value { scrollView?.keyboardDismissMode = value }
    }

    /// Converts a notified screen frame to the client's coordinates. A visible
    /// docked host can correct its origin when both sources describe the same size.
    public func resolvedKeyboardFrame(_ screenFrame: CGRect) -> CGRect? {
        guard let view = coordinateView, let window = view.window else { return nil }
        var result = view.convert(keyboardFrameInWindow(screenFrame, window: window), from: window)
        guard result.minY < view.convert(window.bounds, from: window).maxY,
              let found = lookupHost(window.windowScene),
              abs(found.view.bounds.height - screenFrame.height) <= 0.5 else { return result }
        let actual = KeyboardHostLookup.frame(of: found, in: window)
        guard abs(actual.maxY - window.bounds.maxY) <= 1,
              abs(actual.width - window.bounds.width) <= 1 else { return result }
        result.origin.y = view.convert(actual, from: window).minY
        return result
    }

    /// Forward frame-change and did-hide notifications before applying their
    /// ordinary inset update. Returns true when this controller consumes them.
    /// This explicit handoff does not depend on observer registration order.
    @discardableResult public func handle(_ notification: Notification) -> Bool {
        if notification.name == UIResponder.keyboardDidHideNotification {
            guard isDriving else { refresh(); return hasInput() && isAvailable }
            if hasInput(), let window = attachedWindow, lookupHost(window.windowScene) != nil { return true }
            finishHiddenKeyboard()
            return true
        }
        guard notification.name == UIResponder.keyboardWillChangeFrameNotification else { return false }
        guard isDriving else { return false }
        if ownership == .recoveringShow, let window = attachedWindow,
           let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
           abs(Double(keyboardFrameInWindow(frame, window: window).minY) - keyboardTop) > 0.5 {
            invalidate(); refresh()
            return false
        }
        guard ownership == .awaitingHide, let window = attachedWindow,
              let screenFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return true }
        let target = keyboardFrameInWindow(screenFrame, window: window)
        guard target.minY < window.bounds.maxY - 0.5 else { return true }
        guard let currentHost = lookupHost(window.windowScene) else { invalidate(); return false }
        if let oldHost = host, oldHost.view !== currentHost.view {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            oldHost.view.layer.removeAnimation(forKey: Self.animationKey)
            oldHost.view.layer.bounds.origin.y = 0
            CATransaction.commit()
        }
        host = currentHost
        let host = currentHost
        let shownOffset = -(host.view.layer.presentation()?.bounds.origin.y ?? host.view.layer.bounds.origin.y)
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0
        offset = shownOffset; keyboardTop = target.minY
        takeOwnership(.recoveringShow)
        let currentGeneration = generation
        let recover: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.performUpdate { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.takeOwnership(.recoveringShow)
                let motionGeneration = self.generation
                let finish: @MainActor @Sendable () -> Void = { [weak self] in
                    guard let self, self.generation == motionGeneration else { return }
                    self.finishReturning()
                }
                let holdOrigin = host.view.layer.animation(forKey: Self.animationKey).flatMap { animation in
                    animation.beginTime > 0 ? host.view.layer.convertTime(animation.beginTime, to: nil) : nil
                }
                guard let nativeKeys = KeyboardHostMotion.positionKeys(host, in: window, targetTop: self.keyboardTop,
                                                                       notBefore: holdOrigin, ownedKey: Self.animationKey) else {
                    finish()
                    return
                }
                let frame = self.presentedHostFrame() ?? KeyboardHostLookup.frame(of: host, in: window)
                let held = -(host.view.layer.presentation()?.bounds.origin.y ?? host.view.layer.bounds.origin.y)
                self.offset = max(0, Double(frame.minY + held) - self.keyboardTop)
                self.apply(offset: 0, duration: duration, phase: .returning,
                           followsSystemClock: true, replacingPositionKeys: nativeKeys, completion: finish)
                if duration <= 0 { finish() }
            }
        }
        // Hold below the resting edge until Core Animation commits the native
        // show. The owner then replaces its position motion and starts the
        // keyboard and app together on one new transaction clock.
        if duration > 0 {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let hold = CABasicAnimation(keyPath: "bounds.origin.y")
            hold.fromValue = 0; hold.toValue = 0; hold.isAdditive = true; hold.duration = duration
            hold.delegate = KeyboardDismissalCompletion(nil, started: recover)
            host.view.layer.add(hold, forKey: Self.animationKey)
            CATransaction.commit()
            scheduleCompletion(recover, generation: currentGeneration, after: duration + 0.05)
        } else { recover() }
        return true
    }

    private func presentedHostFrame() -> CGRect? {
        guard let host, let window = attachedWindow, let shown = host.view.layer.presentation(),
              let root = host.window.layer.presentation() else { return nil }
        return KeyboardHostLookup.transfer(shown.convert(shown.bounds, to: root), from: host.window, to: window)
    }
    private func keyboardFrameInWindow(_ frame: CGRect, window: UIWindow) -> CGRect {
        if let screen = window.windowScene?.screen { return window.convert(frame, from: screen.coordinateSpace) }
        return frame.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
    }

    public func invalidate() {
        takeOwnership(.idle)
        gesture.cancelTracking(); touchHasClaimed = false
        if let recognizer { attachedWindow?.removeGestureRecognizer(recognizer) }
        layoutCommitView?.removeFromSuperview(); layoutCommitView = nil
        recognizer = nil; attachedWindow = nil
        if let host {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            host.view.layer.removeAnimation(forKey: Self.animationKey)
            host.view.layer.bounds.origin.y = 0
            CATransaction.commit()
        }
        host = nil; isAvailable = false; offset = 0
        // Until the next refresh nothing claims the keyboard for this scroll view.
        setScrollMode(.none)
    }

    /// Removes keyboard motion during an immediate navigation dismissal.
    public func dismissImmediately() {
        takeOwnership(.idle)
        gesture.cancelTracking(); touchHasClaimed = false
        coordinateView?.window?.endEditing(true)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let host {
            removeAnimations(in: host.window)
            host.view.layer.bounds.origin.y = 0
        }
        update(.init(height: 0, transition: .immediate, phase: .dismissing))
        CATransaction.commit()
        offset = 0
    }

    private func removeAnimations(in view: UIView) {
        view.layer.removeAllAnimations()
        for child in view.subviews { removeAnimations(in: child) }
    }

    fileprivate func begin(_ touch: UITouch) -> Bool {
        guard let window = coordinateView?.window else { return false }
        return begin(y: touch.location(in: window).y, time: CACurrentMediaTime(), touchedView: touch.view)
    }

    /// Tries again for a touch whose view was accepted when it began.
    fileprivate func resumeBegin(_ touch: UITouch) -> Bool {
        guard let window = coordinateView?.window else { return false }
        return begin(y: touch.location(in: window).y, time: CACurrentMediaTime(), touchedView: nil, viewAccepted: true)
    }

    fileprivate func resetTouchOutcome() { gesture.beginTouchSequence() }

    func begin(y: Double, time: Double, touchedView: UIView?) -> Bool {
        begin(y: y, time: time, touchedView: touchedView, viewAccepted: false)
    }

    private func begin(y: Double, time: Double, touchedView: UIView?, viewAccepted: Bool) -> Bool {
        resetTouchOutcome()
        refresh()
        touchHasClaimed = false
        beginWaitsForHost = false
        if !isDriving { gesture = .init() }
        guard ownership != .awaitingHide, ownership != .dismissing, let window = attachedWindow,
              let view = coordinateView, hasInput() else { return false }
        if !viewAccepted {
            guard let touchedView, touchedView === view || touchedView.isDescendant(of: view) else { return false }
            var ancestor: UIView? = touchedView
            while let current = ancestor {
                if shouldBegin?(current) == false { return false }
                if current === window { break }
                ancestor = current.superview
            }
        }
        // A phone's keyboard with no docked host yet, or one still moving
        // into place, is on its way: the finger's moves try again.
        let onItsWay = UIDevice.current.userInterfaceIdiom == .phone
        guard let host else { beginWaitsForHost = onItsWay; return false }
        let frame = KeyboardHostLookup.frame(of: host, in: window)
        let top = Double(frame.minY), screenHeight = Double(window.bounds.maxY)
        // An out-of-process or floating keyboard cannot be driven by this path.
        guard frame.width >= window.bounds.width - 1, abs(frame.maxY - window.bounds.maxY) <= 1 else {
            beginWaitsForHost = onItsWay
            return false
        }
        if let presented = presentedHostFrame(),
           abs(Double(presented.minY) - top) > 0.5 || abs(presented.height - frame.height) > 0.5 {
            beginWaitsForHost = true
            return false
        }
        let armed = gesture.begin(y: y, time: time,
                                  geometry: .init(screenHeight: screenHeight, keyboardTop: top, accessoryHeight: accessoryHeight()),
                                  hasFirstResponder: true)
        guard armed else { return false }
        if !isDriving { offset = 0 }
        keyboardTop = top
        return true
    }

    fileprivate func move(_ touch: UITouch) -> Bool {
        guard let window = attachedWindow else { return false }
        return move(y: touch.location(in: window).y, time: CACurrentMediaTime())
    }

    @discardableResult func move(y: Double, time: Double) -> Bool {
        synchronizeGeometry()
        guard let value = gesture.move(y: y, time: time) else { return false }
        if !touchHasClaimed {
            if isDriving, let host {
                let presented = -(host.view.layer.presentation()?.bounds.origin.y ?? host.view.layer.bounds.origin.y)
                // A touch above the returning keyboard leaves that return running
                // until the finger reaches it. Grabbing it cannot jump to zero.
                guard value.offset >= presented else { return false }
                offset = presented
            }
            takeOwnership(.tracking); touchHasClaimed = true
        }
        stage(.tracking(value))
        return true
    }

    fileprivate func end(_ touch: UITouch, cancelled: Bool) {
        guard let window = attachedWindow else { return }
        end(y: touch.location(in: window).y, time: CACurrentMediaTime(), cancelled: cancelled)
    }

    func end(y: Double, time: Double, cancelled: Bool = false) {
        synchronizeGeometry()
        guard let release = gesture.end(y: y, time: time, cancelled: cancelled) else { return }
        guard touchHasClaimed || release.dismisses else { return }
        takeOwnership(release.dismisses ? .dismissing : .returning)
        stage(.release(release))
    }

    private func stage(_ change: LayoutChange) {
        updateRequest &+= 1
        pendingLayout = (generation, change)
        if let layoutCommitView {
            layoutCommitView.setNeedsLayout()
            attachedWindow?.setNeedsLayout()
        } else { commitPendingLayout() }
    }

    fileprivate func commitPendingLayout() {
        guard let pending = pendingLayout else { return }
        pendingLayout = nil
        performUpdate { [weak self] in
            guard let self, self.generation == pending.generation else { return }
            switch pending.change {
            case .tracking(let value):
                var value = value
                if self.synchronizeGeometry() != nil { value.offset = max(0, value.boundary - self.keyboardTop) }
                let interactive = self.attachedWindow.map { value.boundary != Double($0.bounds.maxY) } ?? false
                self.apply(offset: value.offset, duration: 0, phase: .tracking, isInteractive: interactive)
                self.gesture.commit(value)
            case .release(let value):
                self.release(value)
            }
        }
    }

    private func performUpdate(_ update: @escaping @MainActor () -> Void) {
        updateRequest &+= 1
        let request = updateRequest
        let current: @MainActor () -> Void = { [weak self] in
            guard let self, self.updateRequest == request else { return }
            update()
        }
        if let list = scrollView as? UltraListView { list.performAfterCurrentPass(current) }
        else { current() }
    }

    private func release(_ release: KeyboardDismissalGesture.Release) {
        let keyboardHeight = synchronizeGeometry()
        let targetOffset = release.dismisses ? keyboardHeight ?? release.targetOffset : 0
        if !touchHasClaimed, let host, host.view.layer.animation(forKey: Self.animationKey) != nil {
            offset = -(host.view.layer.presentation()?.bounds.origin.y ?? host.view.layer.bounds.origin.y)
        }
        takeOwnership(release.dismisses ? .dismissing : .returning)
        let duration = KeyboardDismissalMotion.releaseTransition(dismisses: release.dismisses).duration
        let currentGeneration = generation
        apply(offset: targetOffset, duration: duration, phase: release.dismisses ? .dismissing : .returning,
              nativeRelease: true) { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            if release.dismisses {
                self.apply(offset: self.synchronizeGeometry() ?? targetOffset, duration: 0, phase: .dismissing)
                self.takeOwnership(.awaitingHide)
                self.coordinateView?.window?.endEditing(true)
            } else {
                self.finishReturning()
            }
        }
    }

    @discardableResult private func synchronizeGeometry(lookupCurrentHost: Bool = false) -> Double? {
        guard hasInput(), let window = attachedWindow,
              let current = lookupCurrentHost ? lookupHost(window.windowScene) : host else { return nil }
        let frame = KeyboardHostLookup.frame(of: current, in: window)
        guard frame.width >= window.bounds.width - 1, abs(frame.maxY - window.bounds.maxY) <= 1 else { return nil }
        let top = Double(frame.minY)
        if !lookupCurrentHost || abs(top - keyboardTop) > 0.5 { keyboardTop = top }
        gesture.updateGeometry(screenHeight: Double(window.bounds.maxY), keyboardTop: keyboardTop)
        return max(0, Double(window.bounds.maxY) - keyboardTop)
    }

    private func finishReturning() {
        synchronizeGeometry(lookupCurrentHost: true)
        apply(offset: 0, duration: 0, phase: .returning)
        takeOwnership(.idle); refresh()
    }

    private func apply(offset target: Double, duration: Double, phase: KeyboardDismissalUpdate.Phase,
                       followsSystemClock: Bool = false,
                       replacingPositionKeys: [String] = [],
                       nativeRelease: Bool = false, isInteractive: Bool = false,
                       completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard let host, let view = coordinateView, let window = attachedWindow else { return }
        let bottom = Double(view.convert(view.bounds, to: window).maxY)
        let motion = KeyboardDismissalMotion(beginHeight: bottom - keyboardTop - offset,
                                            endHeight: bottom - keyboardTop - target, restingHeight: restingHeight())
        let progress = duration > 0 && !nativeRelease ? KeyboardDismissalMotion.progress(duration: duration) : []
        let scale = (scrollView as? UltraListView)?.animationDurationScale ?? 1
        let playbackDuration = followsSystemClock ? duration : duration * scale
        let transitionDuration = followsSystemClock ? duration / scale : duration
        let transition: ListTransition = duration <= 0 ? .immediate : nativeRelease
            ? KeyboardDismissalMotion.releaseTransition(dismisses: phase == .dismissing)
            : motion.transition(duration: transitionDuration, progress: progress)
        if followsSystemClock { CATransaction.begin(); CATransaction.setDisableActions(true) }
        let previousOffset = offset
        offset = target
        update(.init(height: bottom - keyboardTop - target, transition: transition, phase: phase, isInteractive: isInteractive))
        UIView.performWithoutAnimation { host.view.layer.bounds.origin.y = -target }
        for key in replacingPositionKeys { host.view.layer.removeAnimation(forKey: key) }
        if duration > 0 {
            let animation: CAPropertyAnimation
            if nativeRelease {
                animation = KeyboardDismissalAnimation.make(dismisses: phase == .dismissing, from: previousOffset,
                    to: target, durationScale: scale, maximumFramesPerSecond: window.windowScene?.screen.maximumFramesPerSecond ?? 60)
            } else {
                let sampled = CAKeyframeAnimation(keyPath: "bounds.origin.y")
                sampled.values = progress.map { (target - previousOffset) * (1 - $0) }
                sampled.duration = playbackDuration; sampled.isAdditive = true
                sampled.calculationMode = .linear
                animation = sampled
            }
            if let completion { animation.delegate = KeyboardDismissalCompletion(completion) }
            host.view.layer.add(animation, forKey: Self.animationKey)
            if let completion { scheduleCompletion(completion, generation: generation, after: playbackDuration + 0.05) }
        } else { host.view.layer.removeAnimation(forKey: Self.animationKey) }
        if followsSystemClock { CATransaction.commit() }
    }

    private func scheduleCompletion(_ completion: @escaping @MainActor @Sendable () -> Void, generation: UInt64, after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == generation else { return }
            if let host = self.host, let animation = host.view.layer.animation(forKey: Self.animationKey), animation.beginTime > 0 {
                let now = host.view.layer.convertTime(CACurrentMediaTime(), from: nil)
                let remaining = animation.beginTime + animation.duration / max(0.001, Double(animation.speed)) - now
                if remaining > 0 {
                    self.scheduleCompletion(completion, generation: generation, after: max(0.05, remaining)); return
                }
            }
            completion()
        }
    }

    @objc private func keyboardChanged() { refresh() }
    private func finishHiddenKeyboard() {
        takeOwnership(.idle)
        gesture.cancelTracking(); touchHasClaimed = false
        CATransaction.begin(); CATransaction.setDisableActions(true)
        host?.view.layer.removeAnimation(forKey: Self.animationKey)
        host?.view.layer.bounds.origin.y = 0
        update(.init(height: 0, transition: .immediate, phase: .dismissing))
        CATransaction.commit()
        offset = 0
        refresh()
    }
}

@MainActor
private final class KeyboardDismissalLayoutView: UIView {
    private weak var owner: KeyboardDismissalController?
    init(owner: KeyboardDismissalController) {
        self.owner = owner
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false; accessibilityElementsHidden = true
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layoutSubviews() {
        super.layoutSubviews()
        owner?.commitPendingLayout()
    }
}

/// Starts at three points without delaying, cancelling, or competing with scroll input.
@MainActor
private final class KeyboardDismissalRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private weak var owner: KeyboardDismissalController?
    private var primary = KeyboardPrimaryTouch()
    /// The touch began while the keyboard was still on its way: each move
    /// tries again, from where the finger is, until one arms. The view the
    /// touch began on may be gone by then.
    private var waitsToBegin = false
    init(owner: KeyboardDismissalController) {
        self.owner = owner
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
        delegate = self
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard !primary.isActive else { return }
        owner?.resetTouchOutcome()
        guard touches.count == 1, let touch = touches.first, primary.begin(ObjectIdentifier(touch)), let owner else {
            primary = .init(); state = .failed; return
        }
        if owner.begin(touch) { return }
        if owner.beginWaitsForHost { waitsToBegin = true; return }
        primary = .init(); state = .failed
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first(where: { primary.matches(ObjectIdentifier($0)) }), let owner else { return }
        if waitsToBegin {
            if owner.resumeBegin(touch) { waitsToBegin = false }
            return
        }
        if owner.move(touch) { state = state == .possible ? .began : .changed }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, cancelled: true) }
    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        guard let touch = touches.first(where: { primary.matches(ObjectIdentifier($0)) }), primary.end(ObjectIdentifier(touch)) else { return }
        owner?.end(touch, cancelled: cancelled)
        state = state == .possible ? .failed : (cancelled ? .cancelled : .ended)
    }
    override func reset() { primary = .init(); waitsToBegin = false; super.reset() }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

private final class KeyboardDismissalCompletion: NSObject, CAAnimationDelegate {
    private let completion: (@MainActor @Sendable () -> Void)?
    private let started: (@MainActor @Sendable () -> Void)?
    init(_ completion: (@MainActor @Sendable () -> Void)?, started: (@MainActor @Sendable () -> Void)? = nil) {
        self.completion = completion; self.started = started
    }
    func animationDidStart(_ animation: CAAnimation) {
        guard let callback = started else { return }
        Task { @MainActor in callback() }
    }
    func animationDidStop(_ animation: CAAnimation, finished: Bool) {
        guard let callback = completion else { return }
        Task { @MainActor in callback() }
    }
}

#endif