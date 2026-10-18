#if canImport(UIKit)
import UIKit
import UltraView
import os

@MainActor
final class ListChatController: UIViewController, UITextViewDelegate, ListChaosRowHost {
    private static let stopsMomentumOnKeyboardDismissal = false
    let list: UltraListView
    private let composer = UITextView(), send = UIButton(type: .system), stream = UIButton(type: .system)
    private let composerBar = UIStackView()
    private let keyboardLayoutInput = UIView()
    private let placeholder = UILabel()
    private var composerHeight: NSLayoutConstraint?
    private var composerBottom: NSLayoutConstraint?
    private var waitsForSentCollection = false
    private var pendingComposerHeight: CGFloat?
    private var keyboardProbe: ListKeyboardGeometryProbe?
    var keyboardDismissal: KeyboardDismissalController?
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
    private var isTrackingKeyboard: Bool {
        keyboardDismissal?.isAvailable != true && (keyboardGesture.isTracking || (list.isTracking && !keyboardDragHasEnded))
    }
    private var swipeProbe: ListSwipeProbe?
    private var rows: [any ListRow] = []
    /// The conversation as bubbles. Chaos runs keep the card rows they mutate.
    private var thread: ChatThread?
    /// The sent draft as it looked, until its bubble takes its place.
    private var draftSnapshot: UIView?
    private var nextID = 100
    private var streaming: Task<Void, Never>?
    private let monitor = ListFrameMonitor(name: "chat")
    var chaosRows: [DemoListRow] { get { rows.compactMap { $0 as? DemoListRow } } set { rows = newValue } }
    private var composerInset = 0.0
    private var composerInsetRequest: UInt64 = 0
    private var hostProbe: Bool { UserDefaults.standard.bool(forKey: "listHostProbe") }
    init(mode: ScrollEngineMode) { list = UltraListView(engineMode: mode); super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemGroupedBackground; view.clipsToBounds = true
        list.contentView.transform = .init(scaleX: 1, y: -1)
        list.keyboardDismissMode = .interactive
        list.accessibilityIdentifier = "chatList"
        // Chaos runs mutate card rows; `-chatCards YES` shows them too.
        if UserDefaults.standard.string(forKey: "listChaos") == nil, !UserDefaults.standard.bool(forKey: "chatCards") {
            let thread = ChatThread(seeded: 60)
            if hostProbe {
                thread.attachments = { [weak self] message, _ in
                    // Seeded messages keep their groups as new ones arrive.
                    let group = Int(message.id.dropFirst("message-".count)).map { $0 / 5 } ?? -1
                    return self?.headers(group: group, sender: message.outgoing ? "You" : "Assistant") ?? [:]
                }
            }
            thread.onTap = { [weak self] id in self?.edit(id) }
            thread.swipeActions = { [weak self] id in self?.swipeActions(for: id) ?? (leading: [], trailing: []) }
            self.thread = thread
            rows = thread.rows
        } else {
            rows = (0..<60).map { index -> DemoListRow in
                let title = index % 2 == 0 ? "You" : "Assistant"
                let body = index == 0 ? "Tap Stream to watch this reply grow while the conversation stays in place." : "Message \(60 - index). The list keeps only the nearby conversation loaded."
                let height: Double = 92 + Double(index % 3) * 24
                let tint: UIColor = index % 2 == 0 ? .systemIndigo : .systemTeal
                var row = DemoListRow(identity: "message-\(index)", title: title, body: body, height: height, tint: tint, inverted: true)
                if hostProbe { row.extraAttachments = headers(group: index / 5, sender: title) }
                return withSwipeActions(row)
            }
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
            guard let self, keyboardDismissal?.isAvailable != true else { return }
            gestureKeyboardTop = view.keyboardLayoutGuide.layoutFrame.minY
            keyboardDragBegan(height: view.bounds.maxY - gestureKeyboardTop)
            followsComposer = true
        }
        list.onUserScrollDelta = { [weak self] _, _ in
            guard let self, isTrackingKeyboard else { return }
            if abs(view.keyboardLayoutGuide.layoutFrame.minY - gestureKeyboardTop) > 1 { followsComposer = false }
        }
        list.didEndDragging = { [weak self] in
            guard let self, keyboardDismissal?.isAvailable != true else { return }
            followsComposer = abs(view.keyboardLayoutGuide.layoutFrame.minY - gestureKeyboardTop) <= 1
            keyboardDragEnded(height: view.bounds.maxY - view.keyboardLayoutGuide.layoutFrame.minY)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardDidHide(_:)), name: UIResponder.keyboardDidHideNotification, object: nil)
        if !UserDefaults.standard.bool(forKey: "listSystemKeyboardDismissal") {
            keyboardDismissal = KeyboardDismissalController(scrollView: list, coordinateView: view,
                accessoryHeight: { [weak self] in Double(self?.composerBar.bounds.height ?? 0) },
                restingHeight: { [weak self] in Double(self?.view.safeAreaInsets.bottom ?? 0) },
                hasInput: { [weak self] in self?.composer.isFirstResponder == true },
                update: { [weak self] update in self?.applyDrivenKeyboard(update) })
        }
        list.shouldStopScrolling = { [weak self] _ in
            Self.stopsMomentumOnKeyboardDismissal && self?.keyboardDismissal?.dismissedInTouchSequence == true
        }
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
        ChatBubbleProbe.startIfRequested(chat: self)
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
        keyboardDismissal?.refresh()
        if keyboardDismissal?.isDriving == true {
            // Auto Layout rounds its constraint result to pixels. Keep the
            // owned bottom anchor exact after that layout has finished.
            UIView.performWithoutAnimation {
                composerBar.frame.origin.y = view.bounds.maxY + (composerBottom?.constant ?? -8) - composerBar.frame.height
            }
            return
        }
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
    func applyDrivenKeyboard(_ update: KeyboardDismissalUpdate) {
        keyboardHeight = update.height
        keyboardIsVisible = update.height > view.safeAreaInsets.bottom + 0.5
        followsComposer = true
        keyboardTransition = update.transition
        applyComposerInset(max(update.height, view.safeAreaInsets.bottom) + (composerHeight?.constant ?? composerBar.bounds.height) + 8,
                           transition: update.transition, compensatesInsetChange: !list.isTracking && !list.isDragging,
                           finishesAnimation: update.transition.isImmediate && update.phase != .tracking,
                           minimumChange: 1e-6)
        keyboardTransition = nil
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
    private func applyComposerInset(_ inset: Double, transition: ListTransition, compensatesInsetChange: Bool? = nil, finishesAnimation: Bool = false, minimumChange: Double = 0.5) {
        composerInsetRequest &+= 1
        let request = composerInsetRequest
        list.performAfterCurrentPass { [weak self] in
            guard let self, composerInsetRequest == request else { return }
            applyComposerInsetNow(inset, transition: transition, compensatesInsetChange: compensatesInsetChange, finishesAnimation: finishesAnimation, minimumChange: minimumChange)
        }
    }
    private func applyComposerInsetNow(_ inset: Double, transition: ListTransition, compensatesInsetChange: Bool?, finishesAnimation: Bool, minimumChange: Double) {
        guard abs(inset - composerInset) > minimumChange else {
            if finishesAnimation {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                removeComposerAnimations(); list.finishViewportTransition()
                CATransaction.commit()
            }
            return
        }
        let modelFrame = composerBar.frame
        let presented = composerBar.layer.presentation()
        let geometry = composerBar.layer.animationKeys()?.compactMap { composerBar.layer.animation(forKey: $0) as? CAPropertyAnimation } ?? []
        let movingHeight = geometry.contains { ["bounds", "bounds.size", "bounds.size.height"].contains($0.keyPath ?? "") }
        let movingPosition = geometry.contains { ["position", "position.y"].contains($0.keyPath ?? "") }
        let oldHeight = movingHeight ? presented?.bounds.height ?? modelFrame.height : modelFrame.height
        let oldCenter = movingPosition ? presented?.position.y ?? modelFrame.midY : modelFrame.midY
        let oldFrame = CGRect(x: modelFrame.minX, y: oldCenter - oldHeight / 2, width: modelFrame.width, height: oldHeight)
        composerInset = inset
        let height = composerHeight?.constant ?? composerBar.bounds.height
        composerBottom?.constant = -(inset - height)
        let top = view.bounds.maxY - inset
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let start = CACurrentMediaTime()
        let compensates = compensatesInsetChange ?? (!isTrackingKeyboard && followsComposer)
        list.applyChanges(newInsets: .init(top: inset), compensatesInsetChange: compensates, transition: transition)
        UIView.performWithoutAnimation {
            composerBar.frame = .init(x: oldFrame.minX, y: top, width: oldFrame.width, height: height)
        }
        if !transition.isImmediate { keyboardProbe?.recordKeyboardTransition(transition) }
        list.applyViewportMotion(to: composerBar.layer, keyPath: "position.y", displacement: Double(oldFrame.midY - composerBar.frame.midY))
        list.applyViewportMotion(to: composerBar.layer, keyPath: "bounds.size.height", displacement: Double(oldFrame.height - height))
        CATransaction.commit()
        keyboardProbe?.recordInsetUpdate(milliseconds: (CACurrentMediaTime() - start) * 1000)
    }
    private func removeComposerAnimations() {
        list.applyViewportMotion(to: composerBar.layer, keyPath: "position.y", displacement: 0)
        list.applyViewportMotion(to: composerBar.layer, keyPath: "bounds.size.height", displacement: 0)
    }
    @objc private func keyboardWillChange(_ notification: Notification) {
        let started = CACurrentMediaTime()
        defer { MainThreadMonitor.shared.note("keyboard frame handler \((CACurrentMediaTime() - started) * 1000) ms") }
        guard keyboardDismissal?.handle(notification) != true, view.window != nil,
              let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0
        let raw = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt) ?? 7
        let local = keyboardDismissal?.resolvedKeyboardFrame(frame) ?? view.convert(frame, from: nil)
        let windowBottom = view.window.map { view.convert($0.bounds, from: $0).maxY } ?? view.bounds.maxY
        let begin = (notification.userInfo?[UIResponder.keyboardFrameBeginUserInfoKey] as? CGRect).map { view.convert($0, from: nil) }
        let alreadyHidden = begin.map { $0.minY >= windowBottom - 0.5 && local.minY >= windowBottom - 0.5 } ?? false
        keyboardFrameChanged(height: max(0, view.bounds.maxY - local.minY), duration: duration, curve: raw,
                             fullHeight: frame.height, finishesHide: alreadyHidden,
                             physicalBeginHeight: begin.map { view.bounds.maxY - $0.minY },
                             physicalEndHeight: view.bounds.maxY - local.minY)
    }
    @objc private func keyboardDidHide(_ notification: Notification) {
        guard keyboardDismissal?.handle(notification) != true else { return }
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
        let smallChange = keyboardDismissal?.isAvailable == true && !tracking && keyboardIsVisible
            && height > view.safeAreaInsets.bottom + 0.5 && abs(height - keyboardHeight) <= 44
        let duration = finishesHide || smallChange ? 0 : duration
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
        // A new draft replaces the sent one's picture at once.
        draftSnapshot?.removeFromSuperview(); draftSnapshot = nil
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
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if !animated { keyboardDismissal?.dismissImmediately() }
        if keyboardDismissal?.isDriving != true { keyboardDismissal?.invalidate() }
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); keyboardDismissal?.refresh() }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        keyboardDismissal?.invalidate()
        streaming?.cancel(); monitor.finish(); keyboardProbe?.stop()
    }
    /// Reply from the leading edge; Delete, also by a full swipe, from the trailing edge.
    private func withSwipeActions(_ row: DemoListRow) -> DemoListRow {
        var row = row
        (row.leadingSwipeActions, row.trailingSwipeActions) = swipeActions(for: row.identity)
        return row
    }
    private func swipeActions(for identity: String) -> (leading: [ListSwipeAction], trailing: [ListSwipeAction]) {
        ([ListSwipeAction(title: "Reply", image: UIImage(systemName: "arrowshape.turn.up.left"), color: .systemBlue) { [weak self] in self?.reply(to: identity) }],
         [ListSwipeAction(title: "Delete", image: UIImage(systemName: "trash"), isDestructive: true) { [weak self] in self?.deleteMessage(identity) }])
    }
    private func reply(to identity: String) {
        let sender: String
        if let thread { guard let index = thread.index(of: identity) else { return }; sender = thread.messages[index].outgoing ? "You" : "Assistant" }
        else { guard let row = chaosRows.first(where: { $0.identity == identity }) else { return }; sender = row.title }
        swipeProbe?.record("reply:\(identity)")
        composer.text = "Reply to \(sender): "; updateComposerHeight(animated: true)
    }
    private func deleteMessage(_ identity: String) {
        guard let index = rows.firstIndex(where: { $0.identity == identity }) else { return }
        swipeProbe?.willRemove(identity, action: "delete")
        if let thread { thread.remove(identity); rows = thread.rows } else { rows.remove(at: index) }
        list.applyChanges(items: rows)
    }
    @objc private func sendMessage() {
        followsComposer = true
        nextID += 1
        let body = monitor.measureAction("send-read-composer") { let text = composer.text ?? ""; return text.isEmpty ? "A new message" : text }
        let transition: ListTransition
        if let thread {
            thread.pinnedID = nil
            // The bubble grows out of the draft where it is now; until the
            // bubble shows, a snapshot keeps the draft in the field.
            let source = draftFrames()
            showDraftSnapshot()
            let message = ChatMessage(id: "sent-\(nextID)", text: body, outgoing: true, time: ChatThread.now())
            thread.insert(message, appearance: .growing(from: { [weak self] in
                self?.draftDidLeave()
                return source
            }))
            rows = thread.rows
            transition = thread.config.send
        } else {
            var cards = chaosRows
            if let pinned = cards.firstIndex(where: \.pinsToBottomEdge) { cards[pinned].pinsToBottomEdge = false }
            var row = DemoListRow(identity: "sent-\(nextID)", title: "You", body: body, height: 100, tint: .systemIndigo, inverted: true)
            if hostProbe { row.extraAttachments = headers(group: -1, sender: "You") }
            cards.insert(withSwipeActions(row), at: 0)
            rows = cards
            transition = .easeInOut(0.3)
        }
        // Keep the old bar height until the asynchronously prepared collection
        // applies, then start its shrink alongside the list's viewport track.
        waitsForSentCollection = true
        monitor.measureAction("send-clear-composer") { composer.text = ""; updateComposerHeight() }
        let singleLine = max(44, ceil((composer.font?.lineHeight ?? 21) + composer.textContainerInset.top + composer.textContainerInset.bottom))
        let inset = max(keyboardHeight, view.safeAreaInsets.bottom) + singleLine + 8
        monitor.measureAction("send-apply-list") { list.applyChanges(items: rows, newInsets: .init(top: inset), scrollTo: .init(index: 0), animatesInsertions: false, transition: transition) }
    }
    @objc private func beginStreaming() {
        followsComposer = true
        streaming?.cancel()
        nextID += 1
        let id = "stream-\(nextID)"
        let transition: ListTransition, interval: Duration
        if let thread {
            if hostProbe { thread.pinnedID = id }
            let appearance = NodeAppearance(key: "bubble", scale: thread.config.appearScale, anchor: CGPoint(x: 0, y: 1))
            thread.insert(ChatMessage(id: id, text: ChatStreamScript.opening, outgoing: false, time: ChatThread.now()), appearance: .appearing([appearance]))
            rows = thread.rows
            transition = thread.config.incoming; interval = thread.config.streamInterval
        } else {
            var cards = chaosRows
            var row = DemoListRow(identity: id, title: "Assistant · streaming", body: "A reply", height: hostProbe ? 420 : 84, tint: .systemTeal, inverted: true, pinsToBottomEdge: hostProbe)
            if hostProbe { row.extraAttachments = headers(group: -1, sender: "Assistant") }
            cards.insert(withSwipeActions(row), at: 0)
            rows = cards
            transition = .easeInOut(0.3); interval = .milliseconds(100)
        }
        let visibleHeight = max(0, list.bounds.height - composerInset)
        let target = hostProbe ? ListScrollTarget(index: 0, resolve: { height, _ in visibleHeight + max(0, height - visibleHeight / 2) - height }) : ListScrollTarget(index: 0)
        list.applyChanges(items: rows, scrollTo: target, transition: transition)
        streaming = Task { [weak self] in
            for token in 1...ChatStreamScript.tokenCount {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, rows.contains(where: { $0.identity == id }) else { return }
                if let thread {
                    let started = CACurrentMediaTime()
                    defer { MainThreadMonitor.shared.note("chat token \((CACurrentMediaTime() - started) * 1000) ms") }
                    thread.update(id) { $0.text += ChatStreamScript.token(token) }
                    rows = thread.rows
                    list.applyChanges(items: rows, anchorMode: .preserveVisibleContent, transition: thread.config.growth)
                } else {
                    var cards = chaosRows
                    guard let index = cards.firstIndex(where: { $0.identity == id }) else { return }
                    cards[index].revision += 1
                    cards[index].body += " \(token % 5 == 0 ? "rendered smoothly." : "another word")"
                    if token % 4 == 0 { cards[index].height += 20 }
                    rows = cards
                    list.applyChanges(items: rows, anchorMode: .preserveVisibleContent, transition: .easeInOut(0.2))
                }
            }
        }
    }
    /// A tapped bubble swaps in its edited text.
    func edit(_ id: String) {
        guard let thread else { return }
        thread.toggleEdit(id)
        rows = thread.rows
        list.applyChanges(items: rows, transition: thread.config.growth)
    }
    /// The draft's field and its first line, in window coordinates.
    private func draftFrames() -> [(key: String, frame: CGRect)] {
        let inset = composer.textContainerInset, padding = composer.textContainer.lineFragmentPadding
        let start = composer.caretRect(for: composer.beginningOfDocument)
        let width = composer.bounds.width - inset.left - inset.right - 2 * padding
        let height = max(start.height, composer.contentSize.height - inset.top - inset.bottom)
        let text = CGRect(x: start.minX, y: start.minY, width: max(1, width), height: height)
        return [("bubble", composer.convert(composer.bounds, to: nil)), ("text", composer.convert(text, to: nil))]
    }
    private func showDraftSnapshot() {
        draftSnapshot?.removeFromSuperview()
        guard let snapshot = composer.snapshotView(afterScreenUpdates: false) else { return }
        snapshot.frame = composer.convert(composer.bounds, to: view)
        snapshot.isUserInteractionEnabled = false
        view.addSubview(snapshot)
        draftSnapshot = snapshot
        // A bubble that never shows doesn't leave the draft behind.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak snapshot] in snapshot?.removeFromSuperview() }
    }
    /// The sent bubble shows over the field: the field steps aside and
    /// returns as the bubble leaves it.
    private func draftDidLeave() {
        draftSnapshot?.removeFromSuperview(); draftSnapshot = nil
        // A new draft already in the field stays as it is.
        let duration = (thread?.config.send.duration ?? 0.3) * list.animationDurationScale
        guard duration > 0, composer.text.isEmpty else { return }
        let reveal = CAMediaTimingFunction(name: .easeIn)
        func fade(_ layer: CALayer, _ keyPath: String, from: Any) {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = from; animation.duration = duration; animation.timingFunction = reveal
            layer.add(animation, forKey: "chat.send.\(keyPath)")
        }
        fade(composer.layer, "backgroundColor", from: UIColor.clear.cgColor)
        fade(composer.layer, "borderColor", from: UIColor.clear.cgColor)
        fade(placeholder.layer, "opacity", from: 0)
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