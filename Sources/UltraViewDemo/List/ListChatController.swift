#if canImport(UIKit)
import UIKit
import UltraView
import os

@MainActor
final class ListChatController: UIViewController, UITextViewDelegate, ListChaosRowHost {
    let list: UltraListView
    private let composer = UITextView(), send = UIButton(type: .system), stream = UIButton(type: .system)
    private let composerBar = UIStackView()
    private let keyboardLayoutInput = UIView()
    private let placeholder = UILabel()
    private var composerHeight: NSLayoutConstraint?
    private var composerBottom: NSLayoutConstraint?
    private var composerAnimationCurves: [String: ListCurve] = [:]
    private var waitsForSentCollection = false
    private var pendingComposerHeight: CGFloat?
    private var keyboardProbe: ListKeyboardGeometryProbe?
    private var keyboardTransition: ListTransition?
    private var gestureKeyboardTransition: ListTransition?
    private var keyboardHeight = 0.0
    private var keyboardFullHeight = 0.0
    private var gestureKeyboardFullHeight: Double?
    private var keyboardIsVisible = false
    private var followsComposer = true
    private var gestureKeyboardTop = 0.0
    private var keyboardGesture = KeyboardInsetGesture()
    private var keyboardDragHasEnded = false
    private var pendingKeyboardResolution: KeyboardInsetGesture.Resolution?
    private var keyboardResolutionGeneration: UInt64 = 0
    private var isTrackingKeyboard: Bool { keyboardGesture.isTracking || (list.isTracking && !keyboardDragHasEnded) }
    private var rows: [DemoListRow] = []
    private var swipeProbe: ListSwipeProbe?
    private var nextID = 100
    private var streaming: Task<Void, Never>?
    private let monitor = ListFrameMonitor(name: "chat")
    var chaosRows: [DemoListRow] { get { rows } set { rows = newValue } }
    private var composerInset = 0.0
    private var hostProbe: Bool { UserDefaults.standard.bool(forKey: "listHostProbe") }
    init(mode: ScrollEngineMode) { list = UltraListView(engineMode: mode); super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemGroupedBackground; view.clipsToBounds = true
        list.contentView.transform = .init(scaleX: 1, y: -1)
        list.keyboardDismissMode = .interactive
        list.accessibilityIdentifier = "chatList"
        rows = (0..<60).map { index -> DemoListRow in
            let title = index % 2 == 0 ? "You" : "Assistant"
            let body = index == 0 ? "Tap Stream to watch this reply grow while the conversation stays in place." : "Message \(60 - index). The list keeps only the nearby conversation loaded."
            let height: Double = 92 + Double(index % 3) * 24
            let tint: UIColor = index % 2 == 0 ? .systemIndigo : .systemTeal
            var row = DemoListRow(identity: "message-\(index)", title: title, body: body, height: height, tint: tint, inverted: true)
            if hostProbe { row.extraAttachments = headers(group: index / 5, sender: title) }
            return withSwipeActions(row)
        }
        composer.accessibilityIdentifier = "composer"; composer.accessibilityLabel = "Message"
        composer.delegate = self; composer.font = .preferredFont(forTextStyle: .body)
        composer.adjustsFontForContentSizeCategory = true
        composer.textContainerInset = .init(top: 8, left: 4, bottom: 8, right: 4)
        composer.isScrollEnabled = false; composer.backgroundColor = .secondarySystemGroupedBackground
        composer.layer.cornerRadius = 8; composer.layer.borderWidth = 1; composer.layer.borderColor = UIColor.separator.cgColor
        composer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        composer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        placeholder.text = "Message"; placeholder.textColor = .placeholderText; placeholder.font = composer.font
        placeholder.isAccessibilityElement = false; placeholder.translatesAutoresizingMaskIntoConstraints = false; composer.addSubview(placeholder)
        NSLayoutConstraint.activate([placeholder.topAnchor.constraint(equalTo: composer.topAnchor, constant: 8), placeholder.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 9)])
        send.setTitle("Send", for: .normal); send.addTarget(self, action: #selector(sendMessage), for: .touchUpInside)
        stream.setTitle("Stream", for: .normal); stream.addTarget(self, action: #selector(beginStreaming), for: .touchUpInside)
        for button in [stream, send] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        }
        for control in [composer, stream, send] { composerBar.addArrangedSubview(control) }
        composerBar.spacing = 8; composerBar.alignment = .bottom; composerBar.accessibilityIdentifier = "composerBar"
        for v in [list, composerBar] { v.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(v) }
        let initialHeight = max(44, ceil((composer.font?.lineHeight ?? 21) + composer.textContainerInset.top + composer.textContainerInset.bottom))
        let height = composerBar.heightAnchor.constraint(equalToConstant: initialHeight); composerHeight = height
        let bottom = composerBar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8); composerBottom = bottom
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: view.topAnchor), list.leadingAnchor.constraint(equalTo: view.leadingAnchor), list.trailingAnchor.constraint(equalTo: view.trailingAnchor), list.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            composerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12), composerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12), bottom, height,
            composer.heightAnchor.constraint(equalTo: composerBar.heightAnchor), composer.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
        ])
        // A dependent view makes interactive guide movement lay out the chat.
        // It supplies finger samples; the owned inset still positions the bar.
        keyboardLayoutInput.translatesAutoresizingMaskIntoConstraints = false
        keyboardLayoutInput.backgroundColor = .clear; keyboardLayoutInput.isOpaque = false
        keyboardLayoutInput.isUserInteractionEnabled = false; keyboardLayoutInput.accessibilityElementsHidden = true
        keyboardLayoutInput.accessibilityIdentifier = "keyboardLayoutInput"
        view.addSubview(keyboardLayoutInput)
        NSLayoutConstraint.activate([
            keyboardLayoutInput.topAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            keyboardLayoutInput.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardLayoutInput.widthAnchor.constraint(equalToConstant: 1),
            keyboardLayoutInput.heightAnchor.constraint(equalToConstant: 1),
        ])
        list.onVisibleWindowChanged = { [weak self] in
            guard let self, waitsForSentCollection, let height = pendingComposerHeight,
                  list.items.first?.identity == rows.first?.identity,
                  !list.loadedIndexRange.isEmpty else { return }
            waitsForSentCollection = false; pendingComposerHeight = nil
            composerInset = list.viewportInsets.top
            resizeComposer(to: height, animated: true, duration: 0.3, synchronizesWithList: true)
        }
        let initialIndex = UserDefaults.standard.integer(forKey: "listInitialRow")
        list.applyChanges(items: rows, scrollTo: initialIndex > 0 ? .init(index: initialIndex) : nil)
        list.onScrollInput = { [weak self] event in
            if event.phase == .touchDown { self?.keyboardDragHasEnded = false }
        }
        list.willBeginDragging = { [weak self] in
            guard let self else { return }
            gestureKeyboardTop = view.keyboardLayoutGuide.layoutFrame.minY
            keyboardDragBegan(height: view.bounds.maxY - gestureKeyboardTop)
            followsComposer = true
        }
        list.onUserScrollDelta = { [weak self] _, _ in
            guard let self, isTrackingKeyboard else { return }
            if abs(view.keyboardLayoutGuide.layoutFrame.minY - gestureKeyboardTop) > 1 { followsComposer = false }
        }
        list.didEndDragging = { [weak self] in
            guard let self else { return }
            followsComposer = abs(view.keyboardLayoutGuide.layoutFrame.minY - gestureKeyboardTop) <= 1
            keyboardDragEnded(height: view.bounds.maxY - view.keyboardLayoutGuide.layoutFrame.minY)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardDidHide), name: UIResponder.keyboardDidHideNotification, object: nil)
        if UserDefaults.standard.bool(forKey: "listKeyboardGeometryProbe") || UserDefaults.standard.bool(forKey: "listComposerMetrics") {
            keyboardProbe = ListKeyboardGeometryProbe(owner: view, composer: composerBar, list: list,
                                                     keyboardEdge: keyboardLayoutInput, followsComposer: { [weak self] in self?.followsComposer ?? false })
            keyboardProbe?.start()
        }
        if UserDefaults.standard.bool(forKey: "listKeyboardGeometryProbe") {
            let dismiss = UIButton(type: .system)
            dismiss.setTitle("Hide", for: .normal)
            dismiss.accessibilityIdentifier = "dismissKeyboard"
            dismiss.addAction(UIAction { [weak self] _ in self?.followsComposer = true; self?.composer.resignFirstResponder() }, for: .touchUpInside)
            dismiss.setContentHuggingPriority(.required, for: .horizontal)
            dismiss.setContentCompressionResistancePriority(.required, for: .horizontal)
            dismiss.heightAnchor.constraint(equalToConstant: 44).isActive = true
            composerBar.addArrangedSubview(dismiss)
        }
        if UserDefaults.standard.bool(forKey: "listSwipeProbe") { swipeProbe = ListSwipeProbe(owner: view, list: list) }
        monitor.start()
        ListStreamSendProbe.startIfRequested(chat: self)
        ListComposerTimingProbe.startIfRequested(chat: self)
        ListComposerMotionProbe.startIfRequested(chat: self)
        ListComposerKeystrokeProbe.startIfRequested(chat: self)
        if UserDefaults.standard.bool(forKey: "listProbe") {
            Task { [weak self] in
                let delay = UserDefaults.standard.double(forKey: "listProbeDelay")
                try? await Task.sleep(for: .seconds(delay > 0 ? delay : 2))
                if UserDefaults.standard.bool(forKey: "listFlingProbe") {
                    await self?.probeFlingTowardNewest()
                    return
                }
                self?.beginStreaming()
                try? await Task.sleep(for: .seconds(1))
                if self?.hostProbe == true { self?.recordHostState("stream-pin") }
                else { self?.list.beginMomentum(velocity: 3500) }
                if UserDefaults.standard.bool(forKey: "listKeyboardProbe") {
                    try? await Task.sleep(for: .seconds(2))
                    self?.monitor.measureAction("keyboard-show") { self?.composer.becomeFirstResponder() }
                    try? await Task.sleep(for: .seconds(1))
                    self?.recordHostState("after-keyboard-show")
                    self?.monitor.measureAction("keyboard-fill-composer") { self?.composer.text = "A reply during streaming"; self?.updateComposerHeight() }
                    self?.sendMessage()
                    try? await Task.sleep(for: .seconds(1))
                    self?.recordHostState("after-send")
                    self?.monitor.measureAction("keyboard-dismiss") { self?.composer.resignFirstResponder() }
                    try? await Task.sleep(for: .seconds(3))
                    self?.recordHostState("after-keyboard-dismiss")
                } else { try? await Task.sleep(for: .seconds(7)) }
                self?.monitor.finish()
            }
        }
    }
    override func viewDidLayoutSubviews() {
        let started = CACurrentMediaTime()
        defer { MainThreadMonitor.shared.note("composer layout \((CACurrentMediaTime() - started) * 1000) ms") }
        super.viewDidLayoutSubviews()
        updateComposerHeight()
        let guideHeight = Double(view.bounds.maxY - view.keyboardLayoutGuide.layoutFrame.minY)
        if isTrackingKeyboard, abs(view.keyboardLayoutGuide.layoutFrame.minY - gestureKeyboardTop) > 1 { followsComposer = false }
        // The guide can lay out its destination before our keyboard notification.
        // Only tracking reads it directly; notifications own animated targets.
        let inset = (isTrackingKeyboard ? max(guideHeight, view.safeAreaInsets.bottom) : effectiveKeyboardHeight)
            + (composerHeight?.constant ?? composerBar.bounds.height) + 8
        if isTrackingKeyboard {
            keyboardTrackingLayout(inset: inset, height: guideHeight, inputIsTracking: keyboardInputIsTracking,
                                   animationDuration: UIView.inheritedAnimationDuration)
        } else if keyboardGesture.awaitsOutcome {
            _ = keyboardGuideChanged(height: guideHeight)
        } else if pendingKeyboardResolution == nil {
            applyComposerInset(inset, transition: keyboardTransition ?? .none)
        }
    }
    private var effectiveKeyboardHeight: Double {
        keyboardIsVisible ? max(keyboardHeight, view.safeAreaInsets.bottom) : view.safeAreaInsets.bottom
    }
    private var keyboardInputIsTracking: Bool {
        if let scroll = list.contentView as? UIScrollView {
            let pan = scroll.panGestureRecognizer
            return pan.numberOfTouches > 0 && (pan.state == .began || pan.state == .changed)
        }
        return list.isTracking && list.isDragging
    }
    func keyboardTrackingLayout(inset: Double, height: Double, inputIsTracking: Bool, animationDuration: Double) {
        // The guide can publish its animation destination after lift but before
        // didEndDragging. That destination must not replace the last finger sample.
        if animationDuration > 0 || !inputIsTracking, keyboardGesture.recognizesOutcome(height: height) {
            if animationDuration > 0 { gestureKeyboardTransition = .keyboard(animationDuration) }
            if let resolution = keyboardGesture.keyboardOutcome(height: height) {
                finishKeyboardGesture(resolution)
                return
            }
        }
        if keyboardGesture.isTracking {
            guard inputIsTracking else { return }
            keyboardDragChanged(inset: inset, height: height)
        } else if !keyboardGesture.awaitsOutcome, pendingKeyboardResolution == nil {
            applyComposerInset(inset, transition: .none)
        }
    }
    private func applyComposerInset(_ inset: Double, transition: ListTransition, compensatesInsetChange: Bool? = nil, finishesAnimation: Bool = false) {
        guard abs(inset - composerInset) > 0.5 else {
            if finishesAnimation {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                removeComposerAnimations(); list.finishViewportTransition()
                CATransaction.commit()
            }
            return
        }
        let modelFrame = composerBar.frame
        let oldHeight = modelFrame.height + composerAnimationResidual("ultraview.chat.composerHeight")
        let oldCenter = modelFrame.midY + composerAnimationResidual("ultraview.chat.composerPosition")
        let oldFrame = CGRect(x: modelFrame.minX, y: oldCenter - oldHeight / 2, width: modelFrame.width, height: oldHeight)
        composerInset = inset
        let height = composerHeight?.constant ?? composerBar.bounds.height
        composerBottom?.constant = -(inset - height)
        let top = view.bounds.maxY - inset
        CATransaction.begin(); CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation {
            composerBar.frame = .init(x: oldFrame.minX, y: top, width: oldFrame.width, height: height)
        }
        let start = CACurrentMediaTime()
        let compensates = compensatesInsetChange ?? (!isTrackingKeyboard && followsComposer)
        list.applyChanges(newInsets: .init(top: inset), compensatesInsetChange: compensates, transition: transition)
        if !transition.isImmediate,
           let animation = list.contentView.layer.animation(forKey: "ultraview.list.viewportOffset") as? CAPropertyAnimation {
            keyboardProbe?.recordKeyboardTransition(transition)
            animateComposerProperty("position.y", key: "ultraview.chat.composerPosition",
                                    from: oldFrame.midY - composerBar.frame.midY, using: animation, transition: transition)
            animateComposerProperty("bounds.size.height", key: "ultraview.chat.composerHeight",
                                    from: oldFrame.height - height, using: animation, transition: transition)
        } else if transition.isImmediate {
            removeComposerAnimations()
        }
        CATransaction.commit()
        keyboardProbe?.recordInsetUpdate(milliseconds: (CACurrentMediaTime() - start) * 1000)
    }
    private func removeComposerAnimations() {
        composerBar.layer.removeAnimation(forKey: "ultraview.chat.composerPosition")
        composerBar.layer.removeAnimation(forKey: "ultraview.chat.composerHeight")
        composerAnimationCurves.removeAll(keepingCapacity: true)
    }
    private func composerAnimationResidual(_ key: String) -> Double {
        guard let animation = composerBar.layer.animation(forKey: key) as? CAPropertyAnimation else { return 0 }
        let initial = (animation as? CABasicAnimation)?.fromValue as? Double
            ?? ((animation as? CAKeyframeAnimation)?.values?.first as? Double) ?? 0
        guard animation.beginTime != 0 else { return initial }
        let elapsed = max(0, composerBar.layer.convertTime(CACurrentMediaTime(), from: nil) - animation.beginTime) * Double(animation.speed)
        guard elapsed < animation.duration else { return 0 }
        if let values = (animation as? CAKeyframeAnimation)?.values as? [Double], values.count >= 2 {
            let index = elapsed / animation.duration * Double(values.count - 1)
            let lower = min(values.count - 2, Int(index)), fraction = index - Double(lower)
            return values[lower] + (values[lower + 1] - values[lower]) * fraction
        }
        guard let curve = composerAnimationCurves[key] else { return 0 }
        return initial * (1 - curve.value(at: elapsed / animation.duration, duration: animation.duration))
    }
    private func animateComposerProperty(_ path: String, key: String, from displacement: Double, using template: CAPropertyAnimation, transition: ListTransition) {
        guard abs(displacement) > 0.5 else {
            composerBar.layer.removeAnimation(forKey: key); composerAnimationCurves.removeValue(forKey: key)
            return
        }
        let animation = template.copy() as! CAPropertyAnimation
        animation.keyPath = path
        if let keyframes = animation as? CAKeyframeAnimation, let curve = transition.viewportCurve {
            keyframes.values = curve.progress.map { displacement * (1 - $0) }
        } else if let basic = animation as? CABasicAnimation {
            basic.fromValue = displacement; basic.toValue = 0
        }
        animation.isAdditive = true; animation.delegate = nil
        animation.isRemovedOnCompletion = true
        if animation.beginTime != 0 { animation.beginTime = composerBar.layer.convertTime(animation.beginTime, from: list.contentView.layer) }
        composerAnimationCurves[key] = transition.curve
        composerBar.layer.add(animation, forKey: key)
    }
    @objc private func keyboardWillChange(_ notification: Notification) {
        let started = CACurrentMediaTime()
        defer { MainThreadMonitor.shared.note("keyboard frame handler \((CACurrentMediaTime() - started) * 1000) ms") }
        guard view.window != nil, let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0
        let raw = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt) ?? 7
        let local = view.convert(frame, from: nil)
        let windowBottom = view.window.map { view.convert($0.bounds, from: $0).maxY } ?? view.bounds.maxY
        let begin = (notification.userInfo?[UIResponder.keyboardFrameBeginUserInfoKey] as? CGRect).map { view.convert($0, from: nil) }
        let alreadyHidden = begin.map { $0.minY >= windowBottom - 0.5 && local.minY >= windowBottom - 0.5 } ?? false
        keyboardFrameChanged(height: max(0, view.bounds.maxY - local.minY), duration: duration, curve: raw,
                             fullHeight: frame.height, finishesHide: alreadyHidden,
                             physicalBeginHeight: begin.map { view.bounds.maxY - $0.minY },
                             physicalEndHeight: view.bounds.maxY - local.minY)
    }
    @objc private func keyboardDidHide() {
        keyboardFrameChanged(height: 0, duration: 0, curve: 7, finishesHide: true)
    }
    func keyboardDragBegan(height: Double) {
        if let pendingKeyboardResolution {
            self.pendingKeyboardResolution = nil
            resolveKeyboardGesture(pendingKeyboardResolution, transition: keyboardReturnTransition())
        }
        if keyboardGesture.awaitsOutcome, let resolution = keyboardGesture.keyboardOutcome(height: height) {
            resolveKeyboardGesture(resolution, transition: keyboardReturnTransition())
        }
        keyboardResolutionGeneration &+= 1; pendingKeyboardResolution = nil
        keyboardDragHasEnded = false
        gestureKeyboardTransition = nil
        if !keyboardGesture.resumeTracking(inset: composerInset) {
            gestureKeyboardFullHeight = height > view.safeAreaInsets.bottom + 0.5 && keyboardFullHeight > 0 ? keyboardFullHeight : nil
            keyboardGesture.begin(inset: composerInset, height: height, restingHeight: view.safeAreaInsets.bottom)
        }
    }
    func keyboardDragChanged(inset: Double, height: Double) {
        let appliedInset = abs(inset - composerInset) > 0.5 ? inset : composerInset
        guard keyboardGesture.track(inset: appliedInset, height: height) else { return }
        if abs(height - keyboardHeight) > 1 { followsComposer = false }
        applyComposerInset(inset, transition: .none)
    }
    func keyboardDragEnded(height: Double) {
        keyboardDragHasEnded = true
        if let resolution = keyboardGesture.end(height: height) {
            finishKeyboardGesture(resolution)
        }
    }
    @discardableResult func keyboardGuideChanged(height: Double) -> Bool {
        if keyboardGesture.isTracking, !keyboardGesture.recognizesOutcome(height: height) { return false }
        if UIView.inheritedAnimationDuration > 0 { gestureKeyboardTransition = .keyboard(UIView.inheritedAnimationDuration) }
        guard let resolution = keyboardGesture.keyboardOutcome(height: height) else { return false }
        finishKeyboardGesture(resolution)
        return true
    }
    private func finishKeyboardGesture(_ resolution: KeyboardInsetGesture.Resolution) {
        if gestureKeyboardTransition != nil || UIView.inheritedAnimationDuration > 0 {
            resolveKeyboardGesture(resolution, transition: keyboardReturnTransition())
            return
        }
        pendingKeyboardResolution = resolution
        keyboardResolutionGeneration &+= 1
        let generation = keyboardResolutionGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, keyboardResolutionGeneration == generation, let pendingKeyboardResolution else { return }
            self.pendingKeyboardResolution = nil
            resolveKeyboardGesture(pendingKeyboardResolution, transition: .keyboard(0.25))
        }
    }
    private func keyboardReturnTransition() -> ListTransition {
        let duration = UIView.inheritedAnimationDuration
        if duration > 0 { return .keyboard(duration) }
        if let gestureKeyboardTransition { return gestureKeyboardTransition }
        if let keyboardTransition, keyboardTransition.duration > 0 { return keyboardTransition }
        return .keyboard(0.25)
    }
    private func resolveKeyboardGesture(_ resolution: KeyboardInsetGesture.Resolution, transition: ListTransition) {
        gestureKeyboardTransition = nil; keyboardTransition = transition
        let fullHeight = gestureKeyboardFullHeight ?? keyboardFullHeight
        gestureKeyboardFullHeight = nil
        switch resolution {
        case let .returned(inset, height, displacement):
            keyboardHeight = height
            keyboardIsVisible = height > view.safeAreaInsets.bottom + 0.5
            followsComposer = true
            // An interactive return covers only the remaining part of the
            // keyboard's full travel, with an ease-in-out release curve.
            let remaining = min(1, abs(displacement) / max(1, fullHeight))
            let returning = ListTransition.easeInOut(transition.duration * remaining)
            keyboardTransition = returning
            applyComposerInset(inset, transition: returning, compensatesInsetChange: true)
        case let .dismissed(height):
            keyboardHeight = height
            keyboardIsVisible = false
            followsComposer = false
            applyComposerInset(max(keyboardHeight, view.safeAreaInsets.bottom) + (composerHeight?.constant ?? composerBar.bounds.height) + 8, transition: transition, compensatesInsetChange: false)
        }
    }
    func keyboardFrameChanged(height: Double, duration: Double, curve raw: UInt, tracking: Bool? = nil, fullHeight: Double? = nil, finishesHide: Bool = false,
                              physicalBeginHeight: Double? = nil, physicalEndHeight: Double? = nil) {
        let tracking = finishesHide ? false : (tracking ?? isTrackingKeyboard)
        let duration = finishesHide ? 0 : duration
        if let fullHeight { keyboardFullHeight = fullHeight }
        else if height > view.safeAreaInsets.bottom + 0.5 { keyboardFullHeight = height }
        if !tracking, height > keyboardHeight + 1 { followsComposer = true }
        keyboardHeight = max(height, view.safeAreaInsets.bottom)
        keyboardIsVisible = height > view.safeAreaInsets.bottom + 0.5
        var transition: ListTransition = duration > 0 ? .keyboard(duration) : .none
        if duration > 0, keyboardGesture.isTracking { gestureKeyboardTransition = transition }
        // A duration identifies the release animation. Tracking notifications
        // with a zero duration do not decide whether the keyboard stays open.
        var resolution = duration > 0 || !tracking
            ? keyboardGesture.keyboardOutcome(height: keyboardHeight) : nil
        if duration > 0, let pendingKeyboardResolution {
            resolution = pendingKeyboardResolution
            self.pendingKeyboardResolution = nil; keyboardResolutionGeneration &+= 1
        }
        if duration > 0, raw == 7, !tracking, resolution == nil, !keyboardGesture.awaitsOutcome,
           let physicalBeginHeight, let physicalEndHeight {
            let motion = KeyboardViewportMotion(beginHeight: physicalBeginHeight, endHeight: physicalEndHeight,
                                                restingHeight: view.safeAreaInsets.bottom)
            // Keep the keyboard's clock, but clamp its full physical travel
            // where it crosses the chat's resting edge.
            let samples = (0...480).map { step in
                step == 480 ? 1 : transition.curve.value(at: Double(step) / 480, duration: duration)
            }
            if let curve = motion.viewportCurve(physicalProgress: samples) {
                transition.viewportCurve = curve
            }
        }
        keyboardTransition = transition
        let appliedTransition = transition
        updateComposerHeight()
        guard !tracking else {
            if let resolution { resolveKeyboardGesture(resolution, transition: duration > 0 ? transition : keyboardReturnTransition()) }
            return
        }
        UIView.animate(withDuration: duration, delay: 0, options: [.init(rawValue: raw << 16), .beginFromCurrentState, .allowUserInteraction]) {
            if let resolution { self.resolveKeyboardGesture(resolution, transition: duration > 0 ? transition : self.keyboardReturnTransition()) }
            self.view.layoutIfNeeded()
            if !self.keyboardGesture.awaitsOutcome {
                self.applyComposerInset(self.effectiveKeyboardHeight + (self.composerHeight?.constant ?? self.composerBar.bounds.height) + 8,
                                        transition: appliedTransition, finishesAnimation: duration == 0 && !self.keyboardIsVisible)
            }
        }
        // The sampled curve belongs to this notification's physical frames.
        // Later composer layout and gestures use the ordinary keyboard clock.
        keyboardTransition?.viewportCurve = nil
    }
    func textViewDidChange(_ textView: UITextView) {
        waitsForSentCollection = false; pendingComposerHeight = nil
        if !isTrackingKeyboard { followsComposer = true }
        keyboardTransition = ListTransition.none
        updateComposerHeight()
        view.layoutIfNeeded()
    }
    private func updateComposerHeight(animated: Bool = false, duration: Double = 0.18) {
        let started = CACurrentMediaTime()
        defer { MainThreadMonitor.shared.note("composer measure \((CACurrentMediaTime() - started) * 1000) ms") }
        placeholder.isHidden = !(composer.text ?? "").isEmpty
        guard composer.bounds.width > 0 else { return }
        let line = composer.font?.lineHeight ?? 21
        let singleLine = max(44, ceil(line + composer.textContainerInset.top + composer.textContainerInset.bottom))
        let available = max(0, view.bounds.height - max(keyboardHeight, view.safeAreaInsets.bottom))
        let maximum = min(ceil(line * 5 + composer.textContainerInset.top + composer.textContainerInset.bottom), max(singleLine, floor(available * 0.4)))
        let measured = ceil(composer.sizeThatFits(.init(width: composer.bounds.width, height: .greatestFiniteMagnitude)).height)
        let desired = max(44, min(maximum, measured))
        let scrolls = measured > maximum + 0.5
        if composer.isScrollEnabled != scrolls { composer.isScrollEnabled = scrolls }
        if waitsForSentCollection { pendingComposerHeight = desired; return }
        resizeComposer(to: desired, animated: animated, duration: duration)
    }
    private func resizeComposer(to desired: CGFloat, animated: Bool, duration: Double, synchronizesWithList: Bool = true) {
        guard let composerHeight else { return }
        guard abs(composerHeight.constant - desired) > 0.5 else { return }
        composerHeight.constant = desired
        if animated {
            keyboardTransition = .easeInOut(duration)
            UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { self.view.layoutIfNeeded() }
            let content = list.contentView.layer
            let start = synchronizesWithList ? content.animation(forKey: "ultraview.list.viewportOffset").map { content.convertTime($0.beginTime, to: nil) } : nil
            if let start {
                // UIKit creates the layout tracks; use the prepared pass's
                // clock even if applying that pass took part of a frame.
                for view in [composerBar] + composerBar.arrangedSubviews {
                    for key in view.layer.animationKeys() ?? [] {
                        guard let animation = view.layer.animation(forKey: key)?.copy() as? CABasicAnimation,
                              let path = animation.keyPath, path.hasPrefix("position") || path.hasPrefix("bounds"),
                              abs(animation.duration - duration) < 0.000001 else { continue }
                        animation.beginTime = view.layer.convertTime(start, from: nil)
                        view.layer.add(animation, forKey: key)
                    }
                }
            }
        } else { view.setNeedsLayout() }
    }
    private func headers(group: Int, sender: String) -> [String: any ListAttachment] {
        ["date": ChatHeader(group: group, title: group < 0 ? "Now" : "Today", isSender: false), "sender": ChatHeader(group: group, title: sender, isSender: true)]
    }
    private func probeFlingTowardNewest() async {
        list.scrollTo(.init(index: 40), transition: .none)
        try? await Task.sleep(for: .seconds(1))
        monitor.recordState("fling-start", values: ["index": list.loadedIndexRange.lowerBound])
        list.beginMomentum(velocity: -9000)
        try? await Task.sleep(for: .milliseconds(150))
        if UserDefaults.standard.bool(forKey: "listStall") {
            monitor.measureAction("fling-main-stall") { ListFrameMonitor.stallForProbe(milliseconds: 250) }
        }
        for index in 0..<60 {
            try? await Task.sleep(for: .milliseconds(50))
            let first = list.loadedIndexRange.lowerBound
            let finite = list.loadedIndexRange.allSatisfy { row in
                guard let frame = list.settledFrame(at: row) else { return false }
                return frame.minY.isFinite && frame.maxY.isFinite
            }
            monitor.recordState("fling-sample", values: ["sample": index, "flightActive": list.isScrollFlightActive, "index": first, "framesFinite": finite])
        }
        monitor.finish()
    }
    private func recordHostState(_ name: String) {
        guard hostProbe else { return }
        let rects = list.loadedAttachmentViews.map { $0.convert($0.bounds, to: list) }
        monitor.recordState(name, values: ["inset": composerInset, "pinHeld": list.holdsPinnedRow, "pinStrict": list.isStrictlyPinnedToBottomEdge, "attachmentCount": rects.count, "attachmentsFinite": rects.allSatisfy { $0.minY.isFinite && $0.maxY.isFinite }])
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); streaming?.cancel(); monitor.finish(); keyboardProbe?.stop() }
    /// Reply from the leading edge; Delete, also by a full swipe, from the trailing edge.
    private func withSwipeActions(_ row: DemoListRow) -> DemoListRow {
        var row = row
        let identity = row.identity
        row.leadingSwipeActions = [ListSwipeAction(title: "Reply", image: UIImage(systemName: "arrowshape.turn.up.left"), color: .systemBlue) { [weak self] in self?.reply(to: identity) }]
        row.trailingSwipeActions = [ListSwipeAction(title: "Delete", image: UIImage(systemName: "trash"), isDestructive: true) { [weak self] in self?.deleteMessage(identity) }]
        return row
    }
    private func reply(to identity: String) {
        guard let row = rows.first(where: { $0.identity == identity }) else { return }
        swipeProbe?.record("reply:\(identity)")
        composer.text = "Reply to \(row.title): "; updateComposerHeight(animated: true)
    }
    private func deleteMessage(_ identity: String) {
        guard let index = rows.firstIndex(where: { $0.identity == identity }) else { return }
        swipeProbe?.willRemove(identity, action: "delete")
        rows.remove(at: index)
        list.applyChanges(items: rows)
    }
    @objc private func sendMessage() {
        followsComposer = true
        nextID += 1
        let body = monitor.measureAction("send-read-composer") { let text = composer.text ?? ""; return text.isEmpty ? "A new message" : text }
        if let pinned = rows.firstIndex(where: \.pinsToBottomEdge) { rows[pinned].pinsToBottomEdge = false }
        var row = DemoListRow(identity: "sent-\(nextID)", title: "You", body: body, height: 100, tint: .systemIndigo, inverted: true)
        if hostProbe { row.extraAttachments = headers(group: -1, sender: "You") }
        rows.insert(withSwipeActions(row), at: 0)
        // Keep the old bar height until the asynchronously prepared collection
        // applies, then start its shrink alongside the list's viewport track.
        waitsForSentCollection = true
        monitor.measureAction("send-clear-composer") { composer.text = ""; updateComposerHeight() }
        let singleLine = max(44, ceil((composer.font?.lineHeight ?? 21) + composer.textContainerInset.top + composer.textContainerInset.bottom))
        let inset = max(keyboardHeight, view.safeAreaInsets.bottom) + singleLine + 8
        monitor.measureAction("send-apply-list") { list.applyChanges(items: rows, newInsets: .init(top: inset), scrollTo: .init(index: 0), animatesInsertions: false, transition: .easeInOut(0.3)) }
    }
    @objc private func beginStreaming() {
        followsComposer = true
        streaming?.cancel()
        nextID += 1
        let id = "stream-\(nextID)"
        var row = DemoListRow(identity: id, title: "Assistant · streaming", body: "A reply", height: hostProbe ? 420 : 84, tint: .systemTeal, inverted: true, pinsToBottomEdge: hostProbe)
        if hostProbe { row.extraAttachments = headers(group: -1, sender: "Assistant") }
        rows.insert(withSwipeActions(row), at: 0)
        let visibleHeight = max(0, list.bounds.height - composerInset)
        let target = hostProbe ? ListScrollTarget(index: 0, resolve: { height, _ in visibleHeight + max(0, height - visibleHeight / 2) - height }) : ListScrollTarget(index: 0)
        list.applyChanges(items: rows, scrollTo: target, transition: .easeInOut(0.3))
        streaming = Task { [weak self] in
            for token in 1...40 {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self, let index = rows.firstIndex(where: { $0.identity == id }) else { return }
                rows[index].revision += 1
                rows[index].body += " \(token % 5 == 0 ? "rendered smoothly." : "another word")"
                if token % 4 == 0 { rows[index].height += 20 }
                list.applyChanges(items: rows, anchorMode: .preserveVisibleContent, transition: .easeInOut(0.2))
            }
        }
    }
}

@MainActor
private struct ChatHeader: ListAttachment {
    let group: Int
    let title: String
    let isSender: Bool
    var edge: BoundaryEdge { .bottom }
    var reservesSpace: Bool { !isSender }
    var stackingGroup: String? { isSender ? "sender" : "date" }
    var yieldsTo: String? { isSender ? "date" : nil }
    var yieldGap: Double { 32 }
    func makeView() -> ListAttachmentView { DemoHeaderView() }
    func apply(to view: ListAttachmentView, transition: ListTransition) {
        (view as? DemoHeaderView)?.title = title; (view as? DemoHeaderView)?.inverted = true
    }
    func combines(with other: any ListAttachment) -> Bool {
        guard let other = other as? ChatHeader else { return false }
        return group == other.group && title == other.title && isSender == other.isSender
    }
}

@MainActor
final class ListFrameMonitor: NSObject {
    private var link: CADisplayLink?
    private var previous: Double?
    private var gaps: [Double] = []
    private var ownsMainMonitor = false
    private var initialMainWork = 0
    private var hitches = 0
    private var framePeriod = 1000.0 / 60
    private var startedAt = 0.0
    private var actions: [[String: Any]] = []
    private let signposter = OSSignposter(subsystem: "dev.ultraview.listdemo", category: "PointsOfInterest")
    private let name: String
    init(name: String) { self.name = name }
    static func stallForProbe(milliseconds: Int = 120) { Thread.sleep(forTimeInterval: Double(milliseconds) / 1000) }
    @discardableResult
    func measureAction<Result>(_ name: StaticString, _ action: () -> Result) -> Result {
        guard UserDefaults.standard.bool(forKey: "listProbe") else { return action() }
        let start = CACurrentMediaTime()
        let interval = signposter.beginInterval(name, id: signposter.makeSignpostID())
        defer {
            signposter.endInterval(name, interval)
            actions.append(["name": name.description, "at": start - startedAt, "milliseconds": (CACurrentMediaTime() - start) * 1000])
        }
        return action()
    }
    func recordState(_ name: String, values: [String: Any]) {
        var state = values; state["name"] = name; state["at"] = CACurrentMediaTime() - startedAt
        actions.append(state)
    }
    func start() {
        link?.invalidate(); gaps.removeAll(); previous = nil; hitches = 0
        startedAt = CACurrentMediaTime(); actions.removeAll()
        initialMainWork = Diagnostics.shared.counts.mainThreadWork
        if !MainThreadMonitor.shared.isRunning {
            MainThreadMonitor.shared.start(phase: "list-\(name)"); ownsMainMonitor = true
        }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = .init(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common); self.link = link
    }
    @objc private func tick(_ link: CADisplayLink) {
        let time = CACurrentMediaTime()
        framePeriod = (link.targetTimestamp - link.timestamp) * 1000
        if let previous {
            let gap = (time - previous) * 1000
            gaps.append(gap)
            if gap > framePeriod * 1.5 { hitches += 1 }
        }
        previous = time
    }
    func finish() {
        guard link != nil else { return }
        link?.invalidate(); link = nil
        if ownsMainMonitor { MainThreadMonitor.shared.stop(); ownsMainMonitor = false }
        var document: [String: Any] = ["screen": name, "samples": gaps.count, "maximumMainGapMilliseconds": gaps.max() ?? 0, "gapsAbove16_7": gaps.filter { $0 > 16.7 }.count, "missedFramesAbove25": gaps.filter { $0 > 25 }.count, "injectedStall": UserDefaults.standard.bool(forKey: "listStall"), "mainThreadLayoutTextDrawOperations": Diagnostics.shared.counts.mainThreadWork - initialMainWork]
        document["runID"] = UserDefaults.standard.string(forKey: "listProbeRunID") ?? ""
        document["callbackHitches"] = hitches; document["targetFrameMilliseconds"] = framePeriod
        document["keyboardProbe"] = UserDefaults.standard.bool(forKey: "listKeyboardProbe")
        document["actions"] = actions
        if let summary = MainThreadMonitor.shared.summaries.first(where: { $0.phase == "list-\(name)" }) {
            document["maximumBusyTurnMilliseconds"] = summary.maxTurnMilliseconds
            document["p99BusyTurnMilliseconds"] = summary.p99TurnMilliseconds
            document["busyTurnsAbove16_7"] = summary.stalls
            document["stalls"] = MainThreadMonitor.shared.stalls.map { ["milliseconds": $0.milliseconds, "at": $0.startTime, "notes": $0.notes] as [String: Any] }
        }
        if let data = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]), let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? data.write(to: url.appendingPathComponent("list-\(name)-timing.json"))
            print("LIST-TIMING \(String(data: data, encoding: .utf8) ?? "")")
        }
    }
}
#endif