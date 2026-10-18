#if canImport(UIKit)
import QuartzCore
import UIKit
import UltraView

/// Self-driven list scenarios for device video QA, opted into with
/// `-listScenario <name>`. A scenario drives the demo only through what a
/// person could do (buttons, the composer, the blocker) plus the list's public
/// momentum and input APIs, so it needs no UI automation. `-listRecord YES`
/// records the screen while it runs; with or without recording, a per-frame
/// log of list and keyboard geometry and the main thread's telemetry go to
/// Documents/video/<clip>.json.
///
/// Scenarios: keyboard, fling-newest, fling-oldest, stream (Chat); mutations,
/// jump, pair (10k feed); compare, blocker (Compare); touch, which only records
/// for `-listScenarioDuration` seconds while a UI test supplies real
/// touches. Options: `-listScenarioStall
/// <ms>` blocks main once during a fling, `-listScenarioTransition none` makes
/// feed mutations immediate, `-listScenarioBlocker <ms>` selects a blocker
/// level, `-listScenarioPair Resize,Move -listScenarioGap <ms>` taps the
/// second button that long after the first (0: in the same turn). Recording: `-listRecordMethod hierarchy|layers`, `-listRecordScale
/// <pixels per point>` (default 1), `-listRecordEvery <n>` display frames
/// (default 2).
@MainActor
final class ListVideoScenario: NSObject {
    private static var running: ListVideoScenario?
    private let window: UIWindow
    private let name: String, clip: String
    private let defaults = UserDefaults.standard
    private var recorder: ListVideoRecorder?
    private var link: CADisplayLink?
    private var samples: [[String: Any]] = []
    private var events: [[String: Any]] = []
    private var keyboardNotifications: [[String: Any]] = []
    private var keyboardWindows: [[String: Any]] = []
    private var resignedActive = 0
    private var startedAt = 0.0, startedAtWall = 0.0
    private var previousTick: Double?
    private var callbackGaps: [Double] = []
    private var keyboardMarker: UIView?
    private var commitObserver: CFRunLoopObserver?
    private var commits: [[String: Any]] = []
    private var initialMainWork = 0

    static func startIfRequested(window: UIWindow) {
        if UserDefaults.standard.bool(forKey: "listKeyboardCycle") { return cycleKeyboard(window: window) }
        guard running == nil, let name = UserDefaults.standard.string(forKey: "listScenario") else { return }
        let scenario = ListVideoScenario(window: window, name: name)
        running = scenario
        Task { await scenario.run(); running = nil }
    }

    /// `-listKeyboardCycle YES`: shows and hides the keyboard from code, as a
    /// Hide button would, at fixed times after launch: show 2.0 s, hide 3.6 s,
    /// show 5.2 s, hide 6.8 s, show 8.4 s, then leaves it up. Nothing else
    /// runs: no samples, display link, log or marker, so the video is the only record.
    private static func cycleKeyboard(window: UIWindow) {
        Task { @MainActor in
            var elapsed = 0.0
            for (time, show) in [(2.0, true), (3.6, false), (5.2, true), (6.8, false), (8.4, true)] {
                try? await Task.sleep(for: .seconds(time - elapsed)); elapsed = time
                let tabs = window.rootViewController as? UITabBarController
                guard let screen = (tabs?.selectedViewController as? ListsScreenController)?.children.first,
                      let composer = descendants(of: screen.view, as: UITextView.self).first(where: { $0.accessibilityIdentifier == "composer" })
                else { continue }
                if show { composer.becomeFirstResponder() } else { composer.resignFirstResponder() }
            }
        }
    }

    private init(window: UIWindow, name: String) {
        self.window = window; self.name = name
        let engine = UserDefaults.standard.string(forKey: "listEngine") ?? "keyframe"
        clip = UserDefaults.standard.string(forKey: "listClip") ?? "\(name)-\(engine)"
    }

    // MARK: Driving the demo

    private var screen: UIViewController? {
        let tabs = window.rootViewController as? UITabBarController
        return (tabs?.selectedViewController as? ListsScreenController)?.children.first
    }
    private var lists: [UltraListView] { screen.map { Self.descendants(of: $0.view, as: UltraListView.self) } ?? [] }
    private var composer: UITextView? {
        screen.flatMap { Self.descendants(of: $0.view, as: UITextView.self).first { $0.accessibilityIdentifier == "composer" } }
    }
    private static func descendants<View: UIView>(of view: UIView, as type: View.Type) -> [View] {
        var found: [View] = []
        var stack = [view]
        while let next = stack.popLast() {
            if let match = next as? View { found.append(match) } else { stack.append(contentsOf: next.subviews.reversed()) }
        }
        return found
    }
    private func tap(_ title: String) {
        guard let screen, let button = Self.descendants(of: screen.view, as: UIButton.self).first(where: { $0.title(for: .normal) == title }) else {
            mark("missing-button", ["title": title]); return
        }
        mark("tap", ["title": title])
        button.sendActions(for: .touchUpInside)
    }
    private func selectBlocker(milliseconds: Int) {
        guard let controls = window.rootViewController.map({ Self.descendants(of: $0.view, as: UISegmentedControl.self) }),
              let blocker = controls.first(where: { $0.accessibilityIdentifier == "listMainBlocker" }),
              let index = [0, 50, 100, 250].firstIndex(of: milliseconds) else { return }
        blocker.selectedSegmentIndex = index
        blocker.sendActions(for: .valueChanged)
        mark("blocker", ["milliseconds": milliseconds])
    }
    private func mark(_ event: String, _ values: [String: Any] = [:]) {
        var entry = values; entry["name"] = event; entry["time"] = CACurrentMediaTime()
        events.append(entry)
    }
    private func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
    private func stallIfRequested(after seconds: Double) async {
        let milliseconds = defaults.integer(forKey: "listScenarioStall")
        guard milliseconds > 0 else { return }
        await wait(seconds)
        mark("stall-begin", ["milliseconds": milliseconds])
        // Deliberate, opt-in main-thread stall during the flight.
        ListFrameMonitor.stallForProbe(milliseconds: milliseconds)
        mark("stall-end")
    }

    /// Puts the screen in its starting state before recording begins.
    private func setUp() async {
        switch name {
        case "fling-newest": lists.first?.scrollTo(.init(index: 40), transition: .none)
        case "mutations":
            if defaults.string(forKey: "listScenarioTransition") == "none" { lists.first?.defaultTransition = .none }
        case "blocker": selectBlocker(milliseconds: defaults.integer(forKey: "listScenarioBlocker"))
        default: break
        }
        await wait(0.8)
    }

    private func perform() async {
        switch name {
        case "keyboard":
            for show in [true, false, true, false] {
                mark(show ? "keyboard-show" : "keyboard-hide")
                if show { composer?.becomeFirstResponder() } else { composer?.resignFirstResponder() }
                if show { await wait(0.6); keyboardWindows = ListVideoRecorder.windowDescriptions() }
                await wait(show ? 1.0 : 1.6)
            }
        case "fling-newest", "fling-oldest":
            let velocity = name == "fling-newest" ? -9000.0 : 9000
            mark("fling", ["velocity": velocity])
            lists.first?.beginMomentum(velocity: velocity)
            await stallIfRequested(after: 0.15)
            await wait(3.5)
        case "stream":
            tap("Stream"); await wait(5)
        case "mutations":
            for title in ["Insert", "Delete", "Move", "Resize", "Resize"] { tap(title); await wait(1.1) }
        case "jump":
            tap("5,000"); await wait(3); tap("Top"); await wait(3)
        case "across":
            // The Across screen's buttons act on its left-to-right list.
            for title in ["Insert", "Delete", "Move", "Resize", "Resize", "End", "Start"] {
                tap(title); await wait(["End", "Start"].contains(title) ? 2.2 : 1.2)
            }
        case "pair":
            let titles = (defaults.string(forKey: "listScenarioPair") ?? "Resize,Move").split(separator: ",").map(String.init)
            let gap = defaults.double(forKey: "listScenarioGap") / 1000
            for (index, title) in titles.enumerated() {
                if index > 0, gap > 0 { await wait(gap) }
                tap(title)
            }
            await wait(1.6)
        case "compare":
            await sharedDrag(distance: -320, duration: 0.25, release: -2600)
            await wait(2.2)
            await sharedDrag(distance: 260, duration: 0.3, release: 2000)
            await wait(2.2)
        case "blocker":
            await wait(0.2)
            mark("fling", ["velocity": 7000])
            for list in lists { list.beginMomentum(velocity: 7000) }
            await wait(3.5)
        case "touch":
            // Notes when a person taps the chat's buttons.
            if let screen {
                for button in Self.descendants(of: screen.view, as: UIButton.self) where ["Stream", "Send", "Hide"].contains(button.title(for: .normal) ?? "") {
                    button.addTarget(self, action: #selector(buttonTapped(_:)), for: .touchUpInside)
                }
            }
            let duration = defaults.double(forKey: "listScenarioDuration")
            await wait(duration > 0 ? duration : 8)
        default:
            mark("unknown-scenario")
        }
    }

    /// One synthetic drag, sent to every list as the same input stream.
    private func sharedDrag(distance: Double, duration: Double, release: Double) async {
        let steps = max(2, Int(duration * 60))
        func send(_ phase: GestureRecording.Event.Phase, _ translation: Double, _ velocity: Double) {
            let event = GestureRecording.Event(time: CACurrentMediaTime(), phase: phase, translation: .init(x: 0, y: translation), velocity: .init(x: 0, y: velocity))
            for list in lists { list.receiveScrollInput(event) }
        }
        mark("drag-begin", ["distance": distance, "release": release])
        send(.touchDown, 0, 0); send(.began, 0, 0)
        for step in 1...steps {
            try? await Task.sleep(for: .seconds(duration / Double(steps)))
            send(.changed, distance * Double(step) / Double(steps), distance / duration)
        }
        send(.ended, distance, release)
        mark("drag-end")
    }

    // MARK: Recording and telemetry

    /// A marker that follows the chat's keyboard layout guide, re-attached
    /// when a probe rebuilds the chat.
    /// `-listVideoNoMarker YES` leaves the chat without it: a view constrained
    /// to the guide makes the chat lay out on every guide change.
    private func attachKeyboardMarker() {
        guard !defaults.bool(forKey: "listVideoNoMarker") else { return }
        guard let chat = screen as? ListChatController, keyboardMarker?.superview !== chat.view else { return }
        keyboardMarker?.removeFromSuperview()
        let marker = UIView(); marker.isUserInteractionEnabled = false; marker.alpha = 0
        marker.translatesAutoresizingMaskIntoConstraints = false; chat.view.addSubview(marker)
        NSLayoutConstraint.activate([
            marker.topAnchor.constraint(equalTo: chat.view.keyboardLayoutGuide.topAnchor),
            marker.leadingAnchor.constraint(equalTo: chat.view.leadingAnchor),
            marker.widthAnchor.constraint(equalToConstant: 1), marker.heightAnchor.constraint(equalToConstant: 1),
        ])
        keyboardMarker = marker
    }

    private func run() async {
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChange(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resignActive), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(textChange(_:)), name: UITextView.textDidChangeNotification, object: nil)
        await wait(max(0.5, defaults.double(forKey: "listScenarioDelay")))
        attachKeyboardMarker()
        await setUp()
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("video")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(clip).json"))
        let stateAtStart = UIApplication.shared.applicationState
        if defaults.bool(forKey: "listRecord") {
            let scale = defaults.double(forKey: "listRecordScale"), every = defaults.integer(forKey: "listRecordEvery")
            let recorder = ListVideoRecorder(url: directory.appendingPathComponent("\(clip).mp4"),
                                             method: defaults.string(forKey: "listRecordMethod").flatMap(ListVideoRecorder.Method.init) ?? .hierarchy,
                                             pixelsPerPoint: scale > 0 ? scale : 1, interval: every > 0 ? every : 2)
            if let marker = keyboardMarker, let host = marker.superview {
                // The guide rests at the chat's bottom while the keyboard is hidden.
                recorder.overlay = { [weak self, weak marker, weak host] in
                    guard let self, let marker, let host, let top = presented(marker)?.minY,
                          top < host.convert(host.bounds, to: nil).maxY - 0.5 else { return nil }
                    return CGRect(x: 0, y: top, width: window.bounds.width, height: window.bounds.maxY - top)
                }
            }
            self.recorder = recorder
            recorder.start(screen: window.windowScene?.screen ?? window.screen)
        }
        startedAt = CACurrentMediaTime(); startedAtWall = Date().timeIntervalSince1970
        initialMainWork = Diagnostics.shared.counts.mainThreadWork
        let phase = "video-\(clip)"
        if MainThreadMonitor.shared.isRunning { MainThreadMonitor.shared.beginPhase(phase) } else { MainThreadMonitor.shared.start(phase: phase) }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = .init(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common); self.link = link
        startCommitLog()
        mark("lead-in"); await wait(0.6)
        await perform()
        mark("tail"); await wait(0.4)
        link.invalidate(); self.link = nil
        stopCommitLog()
        let summary = MainThreadMonitor.shared.summaries.last { $0.phase == phase }
        MainThreadMonitor.shared.beginPhase("video-after")
        let stateAtEnd = UIApplication.shared.applicationState
        let result = await recorder?.stop()
        write(to: directory.appendingPathComponent("\(clip).json"), summary: summary, result: result,
              states: [Self.describe(stateAtStart), Self.describe(stateAtEnd)])
    }

    @objc private func buttonTapped(_ button: UIButton) {
        mark("button", ["title": button.title(for: .normal) ?? ""])
    }

    /// Each keystroke in the composer, with the text view's content height
    /// at that moment (before layout reacts to it).
    @objc private func textChange(_ notification: Notification) {
        guard let view = notification.object as? UITextView else { return }
        mark("text", ["length": view.text.count, "contentHeight": Double(view.contentSize.height),
                      "fitHeight": Double(view.sizeThatFits(CGSize(width: view.bounds.width, height: .greatestFiniteMagnitude)).height)])
    }

    private static func describe(_ state: UIApplication.State) -> String {
        switch state { case .active: "active"; case .inactive: "inactive"; case .background: "background"; @unknown default: "unknown" }
    }

    @objc private func resignActive() { resignedActive += 1 }

    @objc private func keyboardChange(_ notification: Notification) {
        let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0
        keyboardNotifications.append(["time": CACurrentMediaTime(), "endFrame": Self.array(frame), "duration": duration])
    }

    private static func array(_ rect: CGRect) -> [Double] {
        [rect.minX, rect.minY, rect.width, rect.height].map { (Double($0) * 100).rounded() / 100 }
    }

    /// The presentation-tree frame of `view` in window coordinates.
    private func presented(_ view: UIView) -> CGRect? {
        guard let layer = view.layer.presentation(), let root = window.layer.presentation() else { return nil }
        return layer.convert(layer.bounds, to: root)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if let previousTick { callbackGaps.append((now - previousTick) * 1000) }
        previousTick = now
        var sample: [String: Any] = ["time": now, "frame": link.timestamp]
        let lists = lists
        sample["offsets"] = lists.map { $0.currentScrollOffset }
        sample["presented"] = lists.map { Double(($0.contentView.layer.presentation() ?? $0.contentView.layer).bounds.minY) }
        sample["flights"] = lists.map(\.isScrollFlightActive)
        sample["tracking"] = lists.map(\.isTracking)
        sample["loaded"] = lists.map { [$0.loadedIndexRange.lowerBound, $0.loadedIndexRange.upperBound] }
        // Presented screen positions of loaded rows, [index, minY, height,
        // minX, width]: a model of the motion that survives coordinate rebasing.
        sample["rows"] = lists.map { list in
            list.loadedIndexRange.compactMap { index -> [Double]? in
                guard let row = list.loadedItemView(at: index), let rect = presented(row) else { return nil }
                return [Double(index), (Double(rect.minY) * 100).rounded() / 100, (Double(rect.height) * 100).rounded() / 100,
                        (Double(rect.minX) * 100).rounded() / 100, (Double(rect.width) * 100).rounded() / 100]
            }
        }
        if defaults.bool(forKey: "listVideoViews"), let views = contentViews(presented: true) { sample["views"] = views }
        if let first = lists.first, let row = first.loadedItemView(at: first.loadedIndexRange.lowerBound), let rect = presented(row) {
            sample["firstLoadedRow"] = Self.array(rect)
        }
        if let chat = screen as? ListChatController {
            attachKeyboardMarker()
            if let row = chat.list.loadedItemView(at: 0), let rect = presented(row) { sample["newestRow"] = Self.array(rect) }
            if let bar = composer?.superview, let rect = presented(bar) { sample["composerBar"] = Self.array(rect) }
            if let keyboardMarker, let rect = presented(keyboardMarker) { sample["keyboardTop"] = rect.minY }
            sample["firstResponder"] = composer?.isFirstResponder ?? false
            if let composer, let rect = presented(composer) {
                sample["textView"] = Self.array(rect)
                if let end = composer.selectedTextRange?.end {
                    sample["caret"] = Self.array(composer.convert(composer.caretRect(for: end), to: nil))
                }
                sample["textLength"] = composer.text.count
            }
        }
        samples.append(sample)
    }

    /// With `-listVideoViews YES`, every view under the first list's
    /// content, loaded or not, so a view that outlives its row can be
    /// followed: [group, child order, address, loaded index or -1, opacity,
    /// hidden, minY, height, layers with contents in its tree, a signature of
    /// those contents objects, the tallest bitmap among them in points,
    /// sublayers, snapshot views among them, the last snapshot's minY and height,
    /// minX, width].
    /// `presented` reads the presentation tree; otherwise the model tree, as
    /// the last commit left it.
    private func contentViews(presented: Bool) -> [[Double]]? {
        guard let first = lists.first else { return nil }
        func state(_ layer: CALayer) -> CALayer { presented ? layer.presentation() ?? layer : layer }
        func painted(_ layer: CALayer, depth: Int) -> (count: Int, signature: UInt, tallest: Double) {
            var result = (count: 0, signature: UInt(0), tallest: 0.0)
            if let contents = state(layer).contents {
                let object = contents as AnyObject
                result.count = 1
                result.signature = UInt(bitPattern: ObjectIdentifier(object).hashValue) % 1_000_000_007
                if CFGetTypeID(object) == CGImage.typeID {
                    result.tallest = Double((object as! CGImage).height) / Double(max(1, layer.contentsScale))
                }
            }
            guard depth < 12 else { return result }
            for sublayer in layer.sublayers ?? [] {
                let inner = painted(sublayer, depth: depth + 1)
                result = (result.count + inner.count, (result.signature &* 31 &+ inner.signature) % 1_000_000_007, max(result.tallest, inner.tallest))
            }
            return result
        }
        let root = state(window.layer)
        let loaded = Dictionary(first.loadedIndexRange.compactMap { index in first.loadedItemView(at: index).map { (ObjectIdentifier($0), index) } },
                                uniquingKeysWith: { a, _ in a })
        var views: [[Double]] = []
        func append(_ group: Int, _ order: Int, _ child: CALayer, index: Int, hidden: Bool) {
            let layer = state(child)
            let rect = layer.convert(layer.bounds, to: root), contents = painted(child, depth: 0)
            // Snapshot views draw through the render server and have no contents
            // of their own; count them by class, with the lowest one's window rect.
            let snapshots = (child.sublayers ?? []).filter { String(describing: type(of: $0.delegate as AnyObject)).contains("Replicant") || String(describing: type(of: $0.delegate as AnyObject)).contains("Snapshot") }
            let lowest = snapshots.last.map { state($0) }.map { $0.convert($0.bounds, to: root) } ?? .zero
            views.append([Double(group), Double(order), Double(UInt(bitPattern: ObjectIdentifier(child).hashValue) % 1_000_000_007),
                          Double(index), Double(layer.opacity), hidden || layer.isHidden ? 1 : 0,
                          (Double(rect.minY) * 100).rounded() / 100, (Double(rect.height) * 100).rounded() / 100,
                          Double(contents.count), Double(contents.signature), (contents.tallest * 100).rounded() / 100,
                          Double(child.sublayers?.count ?? 0), Double(snapshots.count), (Double(lowest.minY) * 100).rounded() / 100, (Double(lowest.height) * 100).rounded() / 100,
                          (Double(rect.minX) * 100).rounded() / 100, (Double(rect.width) * 100).rounded() / 100])
        }
        for (group, container) in first.contentView.subviews.enumerated() {
            for (order, child) in container.subviews.enumerated() {
                append(group, order, child.layer, index: loaded[ObjectIdentifier(child)] ?? -1, hidden: child.isHidden)
            }
        }
        // Anything else that can paint over the list: the list's other
        // subviews (group 10, with 13 and 14 below), layers under the content that no view owns
        // (group 11) and under each content group (group 12).
        let viewLayers = Set(first.contentView.subviews.map { ObjectIdentifier($0.layer) })
        for (order, other) in first.subviews.enumerated() where other !== first.contentView {
            append(10, order, other.layer, index: -1, hidden: other.isHidden)
            // Their children (group 13) and grandchildren (group 14, order = child × 100 + grandchild).
            for (inner, child) in other.subviews.enumerated() {
                append(13, inner, child.layer, index: child.tag, hidden: child.isHidden)
                for (leaf, grandchild) in child.subviews.enumerated() {
                    append(14, inner * 100 + leaf, grandchild.layer, index: -1, hidden: grandchild.isHidden)
                }
            }
        }
        for (order, layer) in (first.contentView.layer.sublayers ?? []).enumerated() where !viewLayers.contains(ObjectIdentifier(layer)) {
            append(11, order, layer, index: -1, hidden: false)
        }
        for container in first.contentView.subviews {
            let owned = Set(container.subviews.map { ObjectIdentifier($0.layer) })
            for (order, layer) in (container.layer.sublayers ?? []).enumerated() where !owned.contains(ObjectIdentifier(layer)) {
                append(12, order, layer, index: -1, hidden: false)
            }
        }
        return views
    }

    /// With `-listVideoViews YES`, the content views after each main-thread
    /// commit that changed them, so a state the display link never samples
    /// (one shown between two ticks) still reaches the log.
    private func startCommitLog() {
        guard defaults.bool(forKey: "listVideoViews") else { return }
        // Core Animation commits in a before-waiting observer of order 2,000,000; this runs after it.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_100_000) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, let views = self.contentViews(presented: false) else { return }
                if let last = self.commits.last?["views"] as? [[Double]], last == views { return }
                self.commits.append(["time": CACurrentMediaTime(), "views": views])
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        commitObserver = observer
    }

    private func stopCommitLog() {
        if let commitObserver { CFRunLoopObserverInvalidate(commitObserver) }
        commitObserver = nil
    }

    private func write(to url: URL, summary: MainThreadMonitor.PhaseSummary?, result: VideoFileEncoder.Result?, states: [String]) {
        let screen = window.windowScene?.screen ?? window.screen
        var document: [String: Any] = [
            "clip": clip, "scenario": name, "engine": defaults.string(forKey: "listEngine") ?? "keyframe",
            "listScreen": defaults.string(forKey: "listScreen") ?? "", "recording": recorder != nil,
            "stall": defaults.integer(forKey: "listScenarioStall"), "transition": defaults.string(forKey: "listScenarioTransition") ?? "default",
            "blocker": defaults.integer(forKey: "listScenarioBlocker"),
            "runID": defaults.string(forKey: "listProbeRunID") ?? "",
            "screenPoints": [screen.bounds.width, screen.bounds.height], "nativeScale": screen.nativeScale,
            "maximumFramesPerSecond": screen.maximumFramesPerSecond,
            "startedAt": startedAt, "startedAtWall": startedAtWall, "events": events, "samples": samples, "commits": commits, "keyboardNotifications": keyboardNotifications,
            "keyboardWindows": keyboardWindows, "applicationStates": states, "resignedActive": resignedActive,
            "lists": lists.map { list in
                ["frame": Self.array(list.convert(list.bounds, to: nil)), "engine": list.engineMode.rawValue,
                 "inverted": list.contentView.transform.d < 0] as [String: Any]
            },
        ]
        let gaps = callbackGaps.sorted()
        var main: [String: Any] = [
            "callbackFrames": gaps.count, "callbackMaxMilliseconds": gaps.last ?? 0,
            "callbackP99Milliseconds": gaps.isEmpty ? 0 : gaps[Int(Double(gaps.count - 1) * 0.99)],
            "callbackGapsAbove25": gaps.filter { $0 > 25 }.count,
            "mainThreadLayoutTextDrawOperations": Diagnostics.shared.counts.mainThreadWork - initialMainWork,
        ]
        if let summary {
            main["maxTurnMilliseconds"] = summary.maxTurnMilliseconds; main["p99TurnMilliseconds"] = summary.p99TurnMilliseconds
            main["turnsAbove16_7"] = summary.stalls; main["turns"] = summary.turns
            main["maxFrameMilliseconds"] = summary.maxFrameMilliseconds; main["p99FrameMilliseconds"] = summary.p99FrameMilliseconds
            main["frameHitches"] = summary.hitches; main["hitchMilliseconds"] = summary.hitchMilliseconds
        }
        document["mainThread"] = main
        if let recorder {
            let costs = recorder.frames.map(\.mainMilliseconds).sorted()
            document["recorder"] = [
                "method": recorder.method.rawValue, "pixelsPerPoint": recorder.pixelsPerPoint, "interval": recorder.interval,
                "keyboardOverlay": recorder.overlay != nil, "width": recorder.outputSize.width, "height": recorder.outputSize.height,
                "appended": result?.appended ?? 0, "dropped": result?.dropped ?? 0, "error": result?.error ?? "",
                "captureMainMaxMilliseconds": costs.last ?? 0,
                "captureMainP50Milliseconds": costs.isEmpty ? 0 : costs[costs.count / 2],
                "captureMainP99Milliseconds": costs.isEmpty ? 0 : costs[Int(Double(costs.count - 1) * 0.99)],
                "frames": recorder.frames.map { [$0.time, $0.callback, ($0.mainMilliseconds * 1000).rounded() / 1000] },
            ] as [String: Any]
        }
        if let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]) {
            try? data.write(to: url)
        }
        print("VIDEO-DONE \(clip)")
        // Tells a driving UI test that the log is on disk.
        let done = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        done.isAccessibilityElement = true
        done.accessibilityIdentifier = "listVideoDone"
        window.addSubview(done)
    }
}
#endif
