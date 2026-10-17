#if canImport(UIKit)
import UIKit
import UltraView
import os

@MainActor
final class ListChatController: UIViewController, UITextViewDelegate, ListChaosRowHost {
    let list: UltraListView
    private let composer = UITextView(), send = UIButton(type: .system), stream = UIButton(type: .system)
    private let composerBar = UIStackView()
    private let placeholder = UILabel()
    private var composerHeight: NSLayoutConstraint?
    private var waitsForSentCollection = false
    private var pendingComposerHeight: CGFloat?
    private var keyboardProbe: ListKeyboardGeometryProbe?
    private var keyboardTransition: ListTransition?
    private var keyboardHeight = 0.0
    private var followsComposer = true
    private var gestureKeyboardTop = 0.0
    private var rows: [DemoListRow] = []
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
            return row
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
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: view.topAnchor), list.leadingAnchor.constraint(equalTo: view.leadingAnchor), list.trailingAnchor.constraint(equalTo: view.trailingAnchor), list.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            composerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12), composerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12), composerBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8), height,
            composer.heightAnchor.constraint(equalTo: composerBar.heightAnchor), composer.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
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
        list.willBeginDragging = { [weak self] in
            guard let self else { return }
            gestureKeyboardTop = view.keyboardLayoutGuide.layoutFrame.minY
            followsComposer = true
        }
        list.onUserScrollDelta = { [weak self] _, _ in
            guard let self, list.isTracking else { return }
            if abs(view.keyboardLayoutGuide.layoutFrame.minY - gestureKeyboardTop) > 1 { followsComposer = false }
        }
        list.didEndDragging = { [weak self] in
            guard let self else { return }
            followsComposer = abs(view.keyboardLayoutGuide.layoutFrame.minY - gestureKeyboardTop) <= 1
        }
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        if UserDefaults.standard.bool(forKey: "listKeyboardGeometryProbe") || UserDefaults.standard.bool(forKey: "listComposerMetrics") {
            keyboardProbe = ListKeyboardGeometryProbe(owner: view, composer: composerBar, list: list, followsComposer: { [weak self] in self?.followsComposer ?? false })
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
        monitor.start()
        ListStreamSendProbe.startIfRequested(chat: self)
        ListComposerTimingProbe.startIfRequested(chat: self)
        ListComposerMotionProbe.startIfRequested(chat: self)
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
        if list.isTracking, abs(view.keyboardLayoutGuide.layoutFrame.minY - gestureKeyboardTop) > 1 { followsComposer = false }
        // The guide can lay out its destination before our keyboard notification.
        // Only tracking reads it directly; notifications own animated targets.
        let inset = list.isTracking
            ? max(0, view.bounds.maxY - composerBar.frame.minY)
            : max(keyboardHeight, view.safeAreaInsets.bottom) + (composerHeight?.constant ?? composerBar.bounds.height) + 8
        applyComposerInset(inset, transition: list.isTracking ? .none : keyboardTransition ?? .none)
    }
    private func applyComposerInset(_ inset: Double, transition: ListTransition) {
        guard abs(inset - composerInset) > 0.5 else { return }
        composerInset = inset
        let start = CACurrentMediaTime()
        list.applyChanges(newInsets: .init(top: inset), compensatesInsetChange: !list.isTracking && followsComposer, transition: transition)
        keyboardProbe?.recordInsetUpdate(milliseconds: (CACurrentMediaTime() - start) * 1000)
    }
    @objc private func keyboardWillChange(_ notification: Notification) {
        let started = CACurrentMediaTime()
        defer { MainThreadMonitor.shared.note("keyboard frame handler \((CACurrentMediaTime() - started) * 1000) ms") }
        guard view.window != nil, let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let local = view.convert(frame, from: nil)
        let overlap = max(0, view.bounds.maxY - local.minY)
        if !list.isTracking, overlap > keyboardHeight + 1 { followsComposer = true }
        keyboardHeight = max(overlap, view.safeAreaInsets.bottom)
        updateComposerHeight()
        if list.isTracking {
            keyboardTransition = ListTransition.none
            return
        }
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0
        let raw = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt) ?? 7
        let transition: ListTransition = duration > 0 ? .keyboard(duration) : .none
        keyboardTransition = transition
        UIView.animate(withDuration: duration, delay: 0, options: [.init(rawValue: raw << 16), .beginFromCurrentState, .allowUserInteraction]) {
            self.view.layoutIfNeeded()
            self.applyComposerInset(self.keyboardHeight + (self.composerHeight?.constant ?? self.composerBar.bounds.height) + 8, transition: transition)
        }
    }
    func textViewDidChange(_ textView: UITextView) {
        waitsForSentCollection = false; pendingComposerHeight = nil
        if !list.isTracking { followsComposer = true }
        updateComposerHeight(animated: true)
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
    @objc private func sendMessage() {
        followsComposer = true
        nextID += 1
        let body = monitor.measureAction("send-read-composer") { let text = composer.text ?? ""; return text.isEmpty ? "A new message" : text }
        if let pinned = rows.firstIndex(where: \.pinsToBottomEdge) { rows[pinned].pinsToBottomEdge = false }
        var row = DemoListRow(identity: "sent-\(nextID)", title: "You", body: body, height: 100, tint: .systemIndigo, inverted: true)
        if hostProbe { row.extraAttachments = headers(group: -1, sender: "You") }
        rows.insert(row, at: 0)
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
        rows.insert(row, at: 0)
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