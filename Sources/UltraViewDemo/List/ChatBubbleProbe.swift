#if canImport(UIKit)
import UIKit
import UltraView

/// Samples the chat's bubbles in the presentation tree every display frame
/// while the chat streams, sends and edits:
///
///     -screen lists -listScreen chat -chatBubbleProbe YES
///     [-chatBubbleVariants keyframe/light/default,uiKit/dark/ax3,stepped/light/default/cards,...]
///     [-chatBubbleScenarios stream,send,multilineSend,edit,keyboardStreamSend,keyboardTimedSends,streamPerf]
///
/// Each variant is an engine, an appearance, a text size and optionally
/// `cards`, the chat's card rows instead of bubbles; each scenario starts
/// from a fresh chat and presses the real buttons. `keyboardTimedSends`
/// raises the keyboard, starts a stream and sends 0.5 s and 1.5 s later.
///
/// For every row on screen, every frame records where its content (the
/// bubble, or the card) is against the row's presented bounds, which clip
/// it: its top and bottom padding, how deep the clip cuts into it, the
/// largest padding change between frames, and how many hosts the row
/// shows. These are reported, with a trace for new rows, and checked only
/// for bubbles. For each bubble on screen:
/// - the bubble's bottom keeps its padding to its row's bottom edge, or moves
///   between the old and new padding when a neighbor changes it;
/// - the time keeps its insets to the bubble's bottom-right corner, and the
///   text its padding to the bubble's top-left corner;
/// - the bubble and its text have contents, so no frame shows a blank row,
///   and nothing the transition adds (an old bitmap fading out) covers the
///   text or the time. A frame counts as blank when neither the shown nor
///   the model layers have contents: the shown tree is the last committed
///   one, and a bitmap moved between layers in this turn (a fade-in ending)
///   is in only one of them until the turn commits.
/// While a reply appears, its bubble's scale keeps its tail corner on the
/// corner of its own (animating) frame and never exceeds 1. The scale's
/// shift is set for the bubble's size when it starts appearing, so a reply
/// that grows meanwhile drifts by the unscaled share of half its growth;
/// the check allows that much more. A sent bubble's
/// first sampled frame is compared with the draft's field, allowing the
/// distance its own motion covers in the frames its animation had run.
/// Steps between frames are
/// compared only across consecutive display frames: a longer gap (a main
/// thread busy elsewhere, such as answering a UI test's query) is counted
/// as a frame gap instead. At rest,
/// presentation equals model and no node animation is left. `streamPerf`
/// streams without sampling and reports main-thread turn times.
/// The report is JSON in the accessibility value of `chatBubbleGeometry` and
/// in Documents/chat-bubble-geometry.json.
@MainActor
final class ChatBubbleProbe: NSObject {
    private static var current: ChatBubbleProbe?

    static func startIfRequested(chat: ListChatController) {
        guard current == nil, UserDefaults.standard.bool(forKey: "chatBubbleProbe") else { return }
        let probe = ChatBubbleProbe(chat: chat)
        current = probe
        Task { await probe.run() }
    }

    private enum Scenario: String, CaseIterable {
        case stream, send, multilineSend, edit, keyboardStreamSend, keyboardTimedSends, streamPerf
        var samples: Bool { self != .streamPerf }
    }

    private struct Variant {
        var engine: ScrollEngineMode
        var dark: Bool
        var large: Bool
        var cards: Bool
        var name: String { "\(engine.rawValue)/\(dark ? "dark" : "light")/\(large ? "ax3" : "default")\(cards ? "/cards" : "")" }
        init?(_ text: String) {
            let parts = text.split(separator: "/").map(String.init)
            guard let engine = ScrollEngineMode(rawValue: parts.first ?? "") else { return nil }
            self.engine = engine
            dark = parts.count > 1 && parts[1] == "dark"
            large = parts.count > 2 && parts[2] == "ax3"
            cards = parts.count > 3 && parts[3] == "cards"
        }
    }

    private final class Result {
        let variant: String, scenario: String
        var frames = 0, bubbleSamples = 0, appearSamples = 0, unpresented = 0, blank = 0, halfDrawn = 0
        var insetMax = 0.0, timeMax = 0.0, textMax = 0.0, appearAnchorMax = 0.0, appearDriftMax = 0.0
        var sentFirstFrame: [String: Any]?
        var sentFirstDeviationMax = 0.0
        /// How much farther from the field a sent bubble's first sampled
        /// frame was than its own motion explains (see `sampleSent`).
        var sentFirstExcessMax = 0.0
        /// Sent bubbles whose first frame the probe didn't sample (the main
        /// thread was busy with the send).
        var sentFirstMissed = 0
        /// Each sent bubble's first sample: its deviation from the field, how
        /// long its bubble's and its row's animations had run, the gap since
        /// the tick before, and whether that tick was the previous frame.
        var sentFirsts: [[String: Any]] = []
        var sentMaxStepFraction = 0.0
        var sentHiddenFrames = 0
        var sentTrace: [[Any]] = []
        var settled = false, staleMax = 0.0, lingering: [String] = [], restingRows = 0
        var turns: [Double] = []
        var slowTurns: [(milliseconds: Double, notes: [String])] = []
        var mainThreadWork = 0
        var finalRevision: UInt64?
        var sendTimes: [Double] = []
        var edgeSamples = 0, clipFrames = 0, clipDepthMax = 0.0, padStepMax = 0.0, padStepsAbove4 = 0
        var padStepWorst: [String: Any] = [:]
        var hostOverlapFrames = 0, rowSubviewsMax = 0
        var edgeTrace: [[Any]] = []
        var frameGaps = 0, frameGapMax = 0.0
        var violations: [String: Int] = [:]
        var samples: [[String: Any]] = []
        init(variant: String, scenario: String) { self.variant = variant; self.scenario = scenario }

        func violate(_ kind: String, _ sample: [String: Any]) {
            violations[kind, default: 0] += 1
            if samples.count < 12 { var entry = sample; entry["kind"] = kind; samples.append(entry) }
        }

        /// Everything, with the traces.
        var dictionary: [String: Any] { dictionary(traces: true) }

        func dictionary(traces: Bool) -> [String: Any] {
            let sorted = turns.sorted()
            func percentile(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p / 100))] }
            var value: [String: Any] = [
                "variant": variant, "scenario": scenario, "frames": frames, "bubbleSamples": bubbleSamples,
                "appearSamples": appearSamples, "unpresented": unpresented, "blankFrames": blank, "halfDrawnFrames": halfDrawn,
                "bubbleInsetErrorMax": insetMax, "timeInsetErrorMax": timeMax, "textOffsetErrorMax": textMax,
                "appearAnchorErrorMax": appearAnchorMax, "appearDriftMax": appearDriftMax, "sentMaxStepFraction": sentMaxStepFraction, "sentHiddenFrames": sentHiddenFrames,
                "settled": settled, "staleMax": staleMax, "lingering": lingering, "restingRows": restingRows,
                "turns": turns.count, "turnP50Milliseconds": percentile(50), "turnP99Milliseconds": percentile(99),
                "turnMaxMilliseconds": sorted.last ?? 0, "mainThreadWork": mainThreadWork,
                "slowTurns": slowTurns.map { ["milliseconds": $0.milliseconds, "notes": $0.notes] as [String: Any] },
                "violations": violations, "violationCount": violations.values.reduce(0, +), "firstViolations": samples,
            ]
            if let sentFirstFrame { value["sentFirstFrame"] = sentFirstFrame; value["sentFirstDeviationMax"] = sentFirstDeviationMax
                value["sentFirstExcessMax"] = sentFirstExcessMax; value["sentFirstMissed"] = sentFirstMissed }
            if !sentFirsts.isEmpty { value["sentFirsts"] = sentFirsts }
            value["edges"] = [
                "samples": edgeSamples, "clipFrames": clipFrames, "clipDepthMax": clipDepthMax,
                "padStepMax": padStepMax, "padStepsAbove4": padStepsAbove4, "padStepWorst": padStepWorst,
                "hostOverlapFrames": hostOverlapFrames, "rowSubviewsMax": rowSubviewsMax,
            ] as [String: Any]
            if traces {
                value["edgeTraceFields"] = ["t", "row", "rowMinY", "rowHeight", "topPad", "bottomPad", "modelTopPad", "modelBottomPad", "clipDepth", "shownSubviews"]
                value["edgeTrace"] = edgeTrace
            }
            if !sendTimes.isEmpty { value["sendTimes"] = sendTimes }
            value["frameGaps"] = frameGaps; value["frameGapMaxMilliseconds"] = frameGapMax
            if traces, !sentTrace.isEmpty { value["sentTrace"] = sentTrace }
            if let finalRevision { value["finalRevision"] = finalRevision }
            return value
        }
    }

    /// What the probe remembers about one bubble between frames.
    private struct Track {
        var firstSeen: Double
        var modelInset: Double
        var fromInset: Double
        var lastInset: Double
        var lastCenter: CGPoint?
        /// A sent bubble's first sample: its frame, its distance from the
        /// field, and how many display frames its animation had run.
        var firstSent: (bubble: CGRect, deviation: Double, frames: Double)?
        /// The bubble's size in its first frame, while it starts appearing.
        var appearSize: CGSize?
    }

    private weak var initialChat: ListChatController?
    private weak var lists: ListsScreenController?
    private weak var chat: ListChatController?
    private let report = UILabel()
    private var link: CADisplayLink?
    private var result: Result?
    private var results: [Result] = []
    private var tracks: [String: Track] = [:]
    private var known: Set<String> = []
    /// The draft's field, in the list's coordinates, and the rows before it
    /// was sent, until a new sent row takes it.
    private var draft: (before: Set<String>, frame: CGRect)?
    private var drafts: [String: CGRect] = [:]
    /// When the probe last pressed Send.
    private var draftSentAt: Double?
    private var edgeTracks: [String: (top: Double, bottom: Double)] = [:]
    private var cardsSeen: [String: Double] = [:]
    private var scenarioStart = 0.0
    private var lastTick: Double?
    /// Whether this frame directly follows the last sampled one.
    private var continuous = false
    /// Since the tick before this one, in seconds.
    private var tickGap: Double?
    private var complete = false
    private var failure: String?

    private init(chat: ListChatController) {
        initialChat = chat
        super.init()
    }

    // MARK: Run

    private func run() async {
        try? await Task.sleep(for: .milliseconds(300))
        guard let lists = initialChat?.parent as? ListsScreenController else {
            failure = "Chat is not inside the Lists screen"; publish(); return
        }
        self.lists = lists
        report.frame = .init(x: 0, y: 0, width: 1, height: 1)
        report.text = " "; report.accessibilityLabel = "Chat bubble geometry probe"
        report.accessibilityIdentifier = "chatBubbleGeometry"; report.isAccessibilityElement = true
        lists.view.addSubview(report)
        publish()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common); self.link = link
        let monitor = MainThreadMonitor.shared
        let previousTurn = monitor.onTurn
        monitor.onTurn = { [weak self] turn in
            previousTurn?(turn)
            MainActor.assumeIsolated {
                guard let result = self?.result else { return }
                result.turns.append(turn.milliseconds)
                if result.slowTurns.count < 8 || turn.milliseconds > result.slowTurns[result.slowTurns.count - 1].milliseconds {
                    result.slowTurns.append((turn.milliseconds, Array(turn.notes.prefix(12))))
                    result.slowTurns.sort { $0.milliseconds > $1.milliseconds }
                    if result.slowTurns.count > 8 { result.slowTurns.removeLast() }
                }
            }
        }

        let defaults = UserDefaults.standard
        let variants = (defaults.string(forKey: "chatBubbleVariants") ?? "uiKit,stepped,keyframe")
            .split(separator: ",").compactMap { Variant(String($0)) }
        let scenarios = (defaults.string(forKey: "chatBubbleScenarios")?.split(separator: ",").compactMap { Scenario(rawValue: String($0)) })
            ?? Scenario.allCases
        for variant in variants {
            for scenario in scenarios {
                guard let chat = await freshChat(variant) else {
                    failure = "\(variant.name)/\(scenario.rawValue): chat did not load"; continue
                }
                await perform(scenario, variant: variant, chat: chat)
                publish()
            }
        }
        monitor.onTurn = previousTurn
        link.invalidate(); self.link = nil
        complete = true
        publish()
    }

    private func freshChat(_ variant: Variant) async -> ListChatController? {
        if let composer = chat.flatMap({ composer(in: $0) }), composer.isFirstResponder {
            composer.resignFirstResponder()
            try? await Task.sleep(for: .milliseconds(700))
        }
        guard let lists, let engines = Self.find(in: lists.view, UISegmentedControl.self, { $0.accessibilityIdentifier == "listEngines" }),
              let index = ScrollEngineMode.allCases.firstIndex(of: variant.engine) else { return nil }
        lists.traitOverrides.userInterfaceStyle = variant.dark ? .dark : .light
        lists.traitOverrides.preferredContentSizeCategory = variant.large ? .accessibilityExtraExtraExtraLarge : .large
        // Read as the chat loads; the registration domain isn't saved.
        UserDefaults.standard.register(defaults: ["chatCards": variant.cards])
        let previous = lists.children.first
        engines.selectedSegmentIndex = index
        engines.sendActions(for: .valueChanged)
        let loaded = await wait(8) {
            guard let next = lists.children.first as? ListChatController, next !== previous, next.view.window != nil else { return false }
            return !next.list.loadedIndexRange.isEmpty && next.list.engineMode == variant.engine
        }
        guard loaded, let next = lists.children.first as? ListChatController else { return nil }
        let list = next.list
        _ = await wait(4) { list.loadedIndexRange.allSatisfy { list.loadedItemView(at: $0)?.isDisplayReady ?? false } }
        lists.view.bringSubviewToFront(report)
        chat = next
        _ = await rest(next, timeout: 5)
        return next
    }

    private func perform(_ scenario: Scenario, variant: Variant, chat: ListChatController) async {
        let result = Result(variant: variant.name, scenario: scenario.rawValue)
        results.append(result)
        tracks.removeAll(); draft = nil; drafts.removeAll(); edgeTracks.removeAll(); cardsSeen.removeAll()
        known = Set(chat.list.items.map(\.identity))
        if scenario == .keyboardStreamSend || scenario == .keyboardTimedSends, let composer = composer(in: chat) {
            composer.becomeFirstResponder()
            _ = await wait(3) { chat.view.keyboardLayoutGuide.layoutFrame.height > chat.view.safeAreaInsets.bottom + 40 }
            _ = await rest(chat, timeout: 3)
        }
        // A replaced chat's frame monitor may have stopped the shared one.
        if !MainThreadMonitor.shared.isRunning { MainThreadMonitor.shared.start(phase: "chat-bubbles") }
        let work = Diagnostics.shared.counts.mainThreadWork
        scenarioStart = CACurrentMediaTime()
        self.result = result
        sampling = scenario.samples
        defer { sampling = true }

        switch scenario {
        case .stream, .streamPerf:
            let id = await tap("Stream", chat, result)
            await waitForRevision(id, UInt64(ChatStreamScript.tokenCount), chat, result)
        case .send:
            await sendDraft("Looks great. Does the time slide too?", chat, result)
        case .multilineSend:
            await sendDraft("First line of a longer draft\nSecond line\nThird line, then send", chat, result)
        case .edit:
            let list = chat.list
            guard let id = list.loadedIndexRange.lazy.map({ list.items[$0].identity }).first(where: { $0.hasPrefix("message-") && $0 != "message-0" }) else {
                result.violate("noEditableBubble", [:]); break
            }
            chat.edit(id)
            _ = await rest(chat, timeout: 4)
            chat.edit(id)
        case .keyboardStreamSend:
            let id = await tap("Stream", chat, result)
            await waitForRevision(id, 6, chat, result)
            _ = await wait(2) { [weak self] in self?.isGrowing(id, chat) ?? false }
            await sendDraft("A reply while it streams", chat, result)
            await waitForRevision(id, UInt64(ChatStreamScript.tokenCount), chat, result)
        case .keyboardTimedSends:
            let start = CACurrentMediaTime()
            let id = await tap("Stream", chat, result)
            for at in [0.5, 1.5] {
                let wait = start + at - CACurrentMediaTime()
                if wait > 0 { try? await Task.sleep(for: .milliseconds(Int(wait * 1000))) }
                await sendNow("Sent \(at) s into the stream", chat, result, since: start)
            }
            await waitForRevision(id, UInt64(ChatStreamScript.tokenCount), chat, result)
        }
        let rested = await rest(chat, timeout: 10)
        result.settled = rested
        result.mainThreadWork = Diagnostics.shared.counts.mainThreadWork - work
        self.result = nil
        finalChecks(chat, result)
        if let composer = composer(in: chat), composer.isFirstResponder { composer.resignFirstResponder() }
    }

    private var sampling = true

    @discardableResult
    private func tap(_ title: String, _ chat: ListChatController, _ result: Result) async -> String? {
        guard let button = Self.find(in: chat.view, UIButton.self, { $0.currentTitle == title }) else {
            result.violate("missingControl", ["title": title]); return nil
        }
        let prefix = title == "Send" ? "sent-" : "stream-"
        let before = Set(chat.list.items.map(\.identity))
        button.sendActions(for: .touchUpInside)
        var identity: String?
        _ = await wait(3) {
            identity = chat.list.items.first { $0.identity.hasPrefix(prefix) && !before.contains($0.identity) }?.identity
            return identity != nil
        }
        if identity == nil { result.violate("insertionNotShown", ["title": title]) }
        return identity
    }

    private func sendDraft(_ text: String, _ chat: ListChatController, _ result: Result) async {
        guard let composer = composer(in: chat) else { result.violate("missingControl", ["title": "composer"]); return }
        composer.text = text
        composer.delegate?.textViewDidChange?(composer)
        _ = await wait(2) { (composer.layer.animationKeys() ?? []).isEmpty }
        _ = await rest(chat, timeout: 3)
        let field = chat.list.layer.convert(composer.convert(composer.bounds, to: nil), from: composer.window?.layer)
        let before = Set(chat.list.items.map(\.identity))
        draft = (before, field)
        draftSentAt = CACurrentMediaTime()
        await tap("Send", chat, result)
    }

    /// Types `text` and sends it in the same turn, as a fast typist would.
    private func sendNow(_ text: String, _ chat: ListChatController, _ result: Result, since start: Double) async {
        guard let composer = composer(in: chat) else { result.violate("missingControl", ["title": "composer"]); return }
        composer.text = text
        composer.delegate?.textViewDidChange?(composer)
        let field = chat.list.layer.convert(composer.convert(composer.bounds, to: nil), from: composer.window?.layer)
        draft = (Set(chat.list.items.map(\.identity)), field)
        result.sendTimes.append(CACurrentMediaTime() - start)
        draftSentAt = CACurrentMediaTime()
        await tap("Send", chat, result)
    }

    private func isGrowing(_ identity: String?, _ chat: ListChatController) -> Bool {
        guard let identity, let index = chat.list.items.firstIndex(where: { $0.identity == identity }),
              let view = chat.list.loadedItemView(at: index) else { return false }
        return view.layer.animation(forKey: "ultraview.list.height") != nil
    }

    private func waitForRevision(_ identity: String?, _ revision: UInt64, _ chat: ListChatController, _ result: Result) async {
        guard let identity else { return }
        let reached = await wait(12) { (chat.list.items.first { $0.identity == identity }?.revision ?? 0) >= revision }
        if !reached { result.violate("revisionTimeout", ["identity": identity, "revision": revision]) }
        result.finalRevision = chat.list.items.first { $0.identity == identity }?.revision
    }

    private func wait(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = CACurrentMediaTime() + timeout
        while CACurrentMediaTime() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// No list motion, no animation keys and no pass for half a second.
    private func rest(_ chat: ListChatController, timeout: Double) async -> Bool {
        let list = chat.list, deadline = CACurrentMediaTime() + timeout
        var passes = list.appliedPassCount, since = CACurrentMediaTime()
        while CACurrentMediaTime() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            let moving = list.isScrollFlightActive || list.isTracking || !animationKeys(list).isEmpty
            if list.appliedPassCount != passes || moving { passes = list.appliedPassCount; since = CACurrentMediaTime(); continue }
            if CACurrentMediaTime() - since >= 0.5 { return true }
        }
        return false
    }

    private func animationKeys(_ list: UltraListView) -> [String] {
        var keys = (list.contentView.layer.animationKeys() ?? []).filter { $0.hasPrefix("ultraview.") }.map { "content:\($0)" }
        for index in list.loadedIndexRange {
            guard let layer = list.loadedItemView(at: index)?.layer else { continue }
            var stack = [layer]
            while let current = stack.popLast() {
                keys += (current.animationKeys() ?? []).filter { $0.hasPrefix("ultraview.") }.map { "\(list.items[index].identity):\($0)" }
                stack += current.sublayers ?? []
            }
        }
        return keys
    }

    // MARK: Sampling

    private struct Bubble {
        var row: CGRect, bubble: CGRect, text: CGRect, time: CGRect
        var bubbleLayer: CALayer, textLayer: CALayer, timeLayer: CALayer
        var opacity: Float
    }

    private func bubble(at index: Int, in list: UltraListView, presented: Bool) -> Bubble? {
        guard let view = list.loadedItemView(at: index),
              let host = view.subviews.last(where: { $0 is NodeHostView }) as? NodeHostView,
              let bubble = host.view(forTransitionKey: "bubble"), let text = host.view(forTransitionKey: "text"),
              let time = host.view(forTransitionKey: "time") else { return nil }
        func layer(_ view: UIView) -> CALayer? { presented ? view.layer.presentation() : view.layer }
        guard let target = presented ? list.layer.presentation() : list.layer,
              let row = layer(view), let bubbleLayer = layer(bubble), let textLayer = layer(text), let timeLayer = layer(time),
              let hostLayer = layer(host) else { return nil }
        func rect(_ layer: CALayer) -> CGRect { layer.convert(layer.bounds, to: target) }
        return Bubble(row: rect(row), bubble: rect(bubbleLayer), text: rect(textLayer), time: rect(timeLayer),
                      bubbleLayer: bubbleLayer, textLayer: textLayer, timeLayer: timeLayer, opacity: row.opacity * hostLayer.opacity * bubbleLayer.opacity)
    }

    /// The card of a card row: the largest view in its host smaller than the host.
    private func card(in view: UIView) -> (host: UIView, card: UIView)? {
        guard let host = view.subviews.last(where: { $0 is NodeHostView && !$0.isHidden }) else { return nil }
        var best: UIView?, stack = host.subviews
        while let current = stack.popLast() {
            stack += current.subviews
            let size = current.bounds.size
            guard size.width < host.bounds.width - 0.5 || size.height < host.bounds.height - 0.5 else { continue }
            if size.width * size.height > (best.map { $0.bounds.width * $0.bounds.height } ?? 0) { best = current }
        }
        return best.map { (host, $0) }
    }

    @objc private func tick() {
        guard sampling, let result, let chat, chat.view.window != nil, let listLayer = chat.list.layer.presentation() else { lastTick = nil; return }
        let list = chat.list, now = CACurrentMediaTime()
        result.frames += 1
        let period = link.map { $0.targetTimestamp - $0.timestamp } ?? 1.0 / 60
        if let lastTick {
            let gap = now - lastTick
            continuous = gap <= 1.5 * max(period, 1.0 / 120)
            tickGap = gap
            if !continuous { result.frameGaps += 1; result.frameGapMax = max(result.frameGapMax, gap * 1000) }
        } else { continuous = false; tickGap = nil }
        lastTick = now
        let screen = list.bounds
        for index in list.loadedIndexRange {
            let identity = list.items[index].identity
            guard let view = list.loadedItemView(at: index) else { continue }
            if list.items[index] is ChatBubbleRow {
                sampleBubble(identity, at: index, list: list, now: now, result: result)
            } else if let (_, card) = card(in: view), let row = view.layer.presentation(), let box = card.layer.presentation() {
                let shownRow = row.convert(row.bounds, to: listLayer), shownBox = box.convert(box.bounds, to: listLayer)
                guard shownRow.intersects(screen) else { continue }
                let modelRow = view.layer.convert(view.layer.bounds, to: list.layer), modelBox = card.layer.convert(card.layer.bounds, to: list.layer)
                let first = cardsSeen[identity, default: now]
                cardsSeen[identity] = first
                sampleEdges(identity, view: view, row: shownRow, box: shownBox, modelRow: modelRow, modelBox: modelBox,
                            entering: !known.contains(identity) && now - first < 0.4 * list.animationDurationScale, result: result)
            }
        }
    }

    /// Where a row's content is against the row's presented bounds, which clip it.
    private func sampleEdges(_ identity: String, view: UIView, row: CGRect, box: CGRect, modelRow: CGRect, modelBox: CGRect, entering: Bool, result: Result) {
        let top = Double(box.minY - row.minY), bottom = Double(row.maxY - box.maxY)
        let clip = max(0, Double(row.minY - box.minY), Double(box.maxY - row.maxY))
        let shown = view.subviews.filter { !$0.isHidden && ($0.layer.presentation()?.opacity ?? $0.layer.opacity) > 0.01 }.count
        result.rowSubviewsMax = max(result.rowSubviewsMax, view.subviews.count)
        if shown > 1 { result.hostOverlapFrames += 1 }
        let modelTop = Double(modelBox.minY - modelRow.minY), modelBottom = Double(modelRow.maxY - modelBox.maxY)
        let t = CACurrentMediaTime() - scenarioStart
        if !entering {
            result.edgeSamples += 1
            if clip > 0.5 { result.clipFrames += 1 }
            result.clipDepthMax = max(result.clipDepthMax, clip)
            if let last = edgeTracks[identity], continuous {
                let step = max(abs(top - last.top), abs(bottom - last.bottom))
                if step > 4 { result.padStepsAbove4 += 1 }
                if step > result.padStepMax {
                    result.padStepMax = step
                    result.padStepWorst = ["t": t, "row": identity, "top": [last.top, top], "bottom": [last.bottom, bottom], "rowRect": "\(row)", "box": "\(box)"]
                }
            }
        }
        edgeTracks[identity] = (top, bottom)
        if identity.hasPrefix("stream-") || identity.hasPrefix("sent-"), result.edgeTrace.count < 600 {
            func r(_ value: Double) -> Double { (value * 100).rounded() / 100 }
            result.edgeTrace.append([r(t * 1000), identity, r(Double(row.minY)), r(Double(row.height)), r(top), r(bottom), r(modelTop), r(modelBottom), r(clip), shown])
        }
    }

    private func sampleBubble(_ identity: String, at index: Int, list: UltraListView, now: Double, result: Result) {
        let screen = list.bounds
        guard let shown = bubble(at: index, in: list, presented: true), let model = bubble(at: index, in: list, presented: false) else {
            result.unpresented += 1; return
        }
        let values = [shown.row, shown.bubble, shown.text, shown.time].flatMap { [$0.minX, $0.minY, $0.width, $0.height] }
        guard values.allSatisfy(\.isFinite), shown.row.intersects(screen), shown.row.height > 1 else { return }
        let fresh = !known.contains(identity)
        let modelInset = Double(model.row.maxY - model.bubble.maxY), inset = Double(shown.row.maxY - shown.bubble.maxY)
        var track = tracks[identity] ?? Track(firstSeen: now, modelInset: modelInset, fromInset: modelInset, lastInset: inset)
        if abs(track.modelInset - modelInset) > 0.01 { track.fromInset = track.lastInset; track.modelInset = modelInset }
        let age = now - track.firstSeen
        let sample: [String: Any] = ["row": identity, "age": age, "t": now - scenarioStart, "rowRect": "\(shown.row)", "bubble": "\(shown.bubble)",
                                     "text": "\(shown.text)", "time": "\(shown.time)", "modelBubble": "\(model.bubble)"]
        let entering = fresh && age < 0.6 * list.animationDurationScale + 0.1
        if entering, identity.hasPrefix("sent-"), drafts[identity] == nil, let draft, !draft.before.contains(identity) {
            drafts[identity] = draft.frame; self.draft = nil
        }
        if let view = list.loadedItemView(at: index) {
            sampleEdges(identity, view: view, row: shown.row, box: shown.bubble, modelRow: model.row, modelBox: model.bubble,
                        entering: entering, result: result)
        }
        if entering, identity.hasPrefix("sent-") {
            if let field = drafts[identity] { sampleSent(shown: shown, model: model, row: list.loadedItemView(at: index), track: &track, field: field, result: result) }
        } else if entering {
            // Appearing: the scale keeps the tail corner on the corner of
            // the bubble's own frame, which may itself be moving as the
            // reply grows, and never enlarges it.
            result.appearSamples += 1
            let layer = shown.bubbleLayer, size = layer.bounds.size
            let frame = CGRect(x: layer.position.x - layer.anchorPoint.x * size.width, y: layer.position.y - layer.anchorPoint.y * size.height,
                               width: size.width, height: size.height)
            let scaled = layer.frame
            let start = track.appearSize ?? size
            track.appearSize = start
            let error = Double(max(abs(scaled.minX - frame.minX), abs(scaled.maxY - frame.maxY)))
            let scale = size.width > 0 ? Double(scaled.width / size.width) : 1
            let drift = max(0, 1 - scale) / 2 * Double(max(abs(size.width - start.width), abs(size.height - start.height)))
            result.appearAnchorMax = max(result.appearAnchorMax, error)
            result.appearDriftMax = max(result.appearDriftMax, drift)
            if error > 0.5 + drift { result.violate("appearAnchor", sample.merging(["drift": drift, "error": error]) { $1 }) }
            if scaled.width > frame.width + 0.5 || scaled.height > frame.height + 0.5 { result.violate("appearOvershoot", sample) }
        } else {
            result.bubbleSamples += 1
            let low = min(track.fromInset, modelInset) - 0.5, high = max(track.fromInset, modelInset) + 0.5
            let insetError = inset < low ? low - inset : inset > high ? inset - high : 0
            result.insetMax = max(result.insetMax, insetError)
            if insetError > 0 { result.violate("bubbleInset", sample) }
            let timeError = Double(max(abs((shown.bubble.maxX - shown.time.maxX) - (model.bubble.maxX - model.time.maxX)),
                                       abs((shown.bubble.maxY - shown.time.maxY) - (model.bubble.maxY - model.time.maxY))))
            result.timeMax = max(result.timeMax, timeError)
            if timeError > 0.5 { result.violate("timeInset", sample) }
            let textError = Double(max(abs((shown.text.minX - shown.bubble.minX) - (model.text.minX - model.bubble.minX)),
                                       abs((shown.text.minY - shown.bubble.minY) - (model.text.minY - model.bubble.minY))))
            result.textMax = max(result.textMax, textError)
            if textError > 0.5 { result.violate("textOffset", sample) }
            if shown.opacity < 0.99 { result.violate("translucent", sample) }
        }
        // While its text fades in, a text's bitmap is on a sublayer.
        func drawn(_ layer: CALayer) -> Bool {
            layer.contents != nil || (layer.sublayers ?? []).contains { $0.name == "ultraview.node.revealed" && $0.contents != nil }
        }
        if age > 0.05, !drawn(shown.bubbleLayer) && !drawn(model.bubbleLayer) || !drawn(shown.textLayer) && !drawn(model.textLayer) {
            result.blank += 1; result.violate("blank", sample)
        } else if age > 0.05, !drawn(shown.bubbleLayer) || !drawn(shown.textLayer) || !drawn(model.bubbleLayer) || !drawn(model.textLayer) {
            result.halfDrawn += 1
        }
        // A transition layer above the text or the time hides them.
        let children = model.bubbleLayer.sublayers ?? []
        if let first = [model.textLayer, model.timeLayer].compactMap({ child in children.firstIndex { $0 === child } }).min() {
            let covering = children[(first + 1)...].contains { layer in
                layer.name?.hasPrefix("ultraview.node.") == true && (layer.presentation()?.opacity ?? layer.opacity) > 0.01
            }
            if covering { result.blank += 1; result.violate("covered", sample) }
        }
        track.lastInset = inset
        tracks[identity] = track
    }

    /// A sent bubble grows out of the draft's field: its first frame is
    /// near the field, and no frame jumps a large part of the way.
    private func sampleSent(shown: Bubble, model: Bubble, row: UIView?, track: inout Track, field: CGRect, result: Result) {
        // A frame where the bubble is hidden still shows the draft in the field.
        guard shown.opacity > 0.01 else { result.sentHiddenFrames += 1; return }
        let center = CGPoint(x: shown.bubble.midX, y: shown.bubble.midY)
        let travel = hypot(model.bubble.midX - field.midX, model.bubble.midY - field.midY)
        func distance(_ a: CGRect, _ b: CGRect) -> Double {
            Double(max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.maxX - b.maxX), abs(a.maxY - b.maxY)))
        }
        let period = link.map { $0.targetTimestamp - $0.timestamp } ?? 1.0 / 60
        if track.lastCenter == nil {
            let deviation = distance(shown.bubble, field)
            result.sentFirstDeviationMax = max(result.sentFirstDeviationMax, deviation)
            // How far its animations were along when this frame was sampled.
            let now = CACurrentMediaTime()
            func running(_ layer: CALayer?, _ key: String) -> Double {
                guard let layer, let animation = layer.animation(forKey: key), animation.beginTime != 0 else { return -1 }
                return (now - layer.convertTime(animation.beginTime, to: nil)) * 1000
            }
            let bubbleMs = running(model.bubbleLayer, "ultraview.node.position.y")
            let frames = bubbleMs < 0 ? 1 : max(1, (bubbleMs / 1000 / period).rounded())
            if frames > 1 { result.sentFirstMissed += 1 }
            track.firstSent = (shown.bubble, deviation, frames)
            result.sentFirsts.append(["deviation": deviation, "bubbleMs": bubbleMs, "frames": frames,
                                      "rowMs": running(row?.layer, "ultraview.list.positionY"), "tickGapMs": tickGap.map { $0 * 1000 } ?? -1,
                                      "continuous": continuous, "sinceSendMs": (now - (draftSentAt ?? now)) * 1000])
            if result.sentFirstFrame == nil {
                result.sentFirstFrame = ["deviation": deviation, "travel": Double(travel), "bubble": "\(shown.bubble)", "field": "\(field)"]
            }
        } else if let first = track.firstSent {
            // The first frame starts at the field: it is no farther from it
            // than the frames its animation had run, at the speed the next
            // frame shows. A curve that leaves the field at speed (one joining
            // a running spring) and a first frame the probe missed both pass;
            // a bubble that starts away from the field doesn't.
            track.firstSent = nil
            let step = distance(shown.bubble, first.bubble) / max(1, ((tickGap ?? period) / period).rounded())
            let excess = max(0, first.deviation - 2 - first.frames * step)
            result.sentFirstExcessMax = max(result.sentFirstExcessMax, excess)
            if var last = result.sentFirsts.popLast() { last["nextStep"] = step; last["excess"] = excess; result.sentFirsts.append(last) }
        }
        if result.sentTrace.count < 40 {
            func r(_ rect: CGRect) -> [Double] { [rect.minX, rect.minY, rect.width, rect.height].map { (Double($0) * 10).rounded() / 10 } }
            let keys = (shown.bubbleLayer.model().animationKeys() ?? []).joined(separator: " ")
            result.sentTrace.append([((CACurrentMediaTime() - track.firstSeen) * 1000).rounded(), r(shown.bubble), r(model.bubble), r(shown.row), r(shown.text), keys])
        }
        if let last = track.lastCenter, travel > 1, continuous {
            result.sentMaxStepFraction = max(result.sentMaxStepFraction, Double(hypot(center.x - last.x, center.y - last.y) / travel))
        }
        track.lastCenter = center
    }

    // MARK: End state

    private func finalChecks(_ chat: ListChatController, _ result: Result) {
        let list = chat.list
        result.lingering = animationKeys(list)
        for index in list.loadedIndexRange where list.items[index] is ChatBubbleRow {
            guard let shown = bubble(at: index, in: list, presented: true), let model = bubble(at: index, in: list, presented: false) else { continue }
            result.restingRows += 1
            for (a, b) in [(shown.bubble, model.bubble), (shown.text, model.text), (shown.time, model.time), (shown.row, model.row)] {
                result.staleMax = max(result.staleMax, Double(max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.width - b.width), abs(a.height - b.height))))
            }
            var stack = [model.bubbleLayer]
            while let layer = stack.popLast() {
                if layer.name?.hasPrefix("ultraview.node.") == true { result.violate("leftoverLayer", ["row": list.items[index].identity, "name": layer.name ?? ""]) }
                if layer.mask != nil { result.violate("leftoverMask", ["row": list.items[index].identity]) }
                stack += layer.sublayers ?? []
            }
        }
        if result.staleMax > 0.5 { result.violate("stale", ["staleMax": result.staleMax]) }
        if !result.lingering.isEmpty { result.violate("lingering", ["keys": Array(result.lingering.prefix(6))]) }
    }

    // MARK: Report

    /// The accessibility value has no traces: a UI test reads the whole
    /// tree's values on each query, on the app's main thread, and the traces
    /// of a long run make that take seconds. The file has everything.
    private func publish() {
        func document(traces: Bool) -> [String: Any] {
            var document: [String: Any] = ["complete": complete, "scenarios": results.map { $0.dictionary(traces: traces) }]
            if let failure { document["failure"] = failure }
            return document
        }
        if let data = try? JSONSerialization.data(withJSONObject: document(traces: false), options: [.sortedKeys]) {
            report.accessibilityValue = String(decoding: data, as: UTF8.self)
        }
        if let data = try? JSONSerialization.data(withJSONObject: document(traces: true), options: [.prettyPrinted, .sortedKeys]),
           let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? data.write(to: directory.appendingPathComponent("chat-bubble-geometry.json"), options: .atomic)
        }
        if complete { print("CHAT-BUBBLES \(report.accessibilityValue ?? "")") }
    }

    private func composer(in chat: ListChatController) -> UITextView? {
        Self.find(in: chat.view, UITextView.self) { $0.accessibilityIdentifier == "composer" }
    }

    private static func find<T: UIView>(in root: UIView, _ type: T.Type, _ matches: (T) -> Bool) -> T? {
        var stack = [root]
        while let view = stack.popLast() {
            if let match = view as? T, matches(match) { return match }
            if view is UltraListView { continue }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }
}
#endif
