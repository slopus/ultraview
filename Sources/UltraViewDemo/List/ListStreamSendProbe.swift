#if canImport(UIKit)
import UIKit
import UltraView

/// Samples on-screen row geometry while Chat streams and sends:
///
///     -screen lists -listScreen chat -listStreamSendProbe YES
///     [-listStreamSendEngines uiKit,stepped,keyframe]
///     [-listStreamSendScenarios sendMidGrow,keyboardSendMidGrow,twoSends,streamSendStream,
///                               multilineSendShrink,keyboardMultilineSendShrink]
///
/// Each scenario starts from a fresh chat, rebuilt through the engine control,
/// and presses the real Stream and Send buttons. Every display frame, adjacent
/// loaded rows are measured in the presentation tree and compared with the
/// gap their settled frames declare. Only a pair that contains a newly
/// streamed row may open: that row fades in at its final frame while older
/// rows move. Its gap must stay within the row's height, shrink monotonically
/// and close within a second. Every other visible pair, including every pair
/// with a sent row, must keep its gap within half a point. The per-frame
/// change of an opening is reported against a proxy limit; it is not derived
/// from the transition curve, so it isn't a violation. After the
/// screen rests, the probe compares presentation, model and settled frames,
/// the newest row against the composer, and the collection against the taps.
/// The report is JSON in the accessibility value of `streamSendGeometry` and
/// in Documents/list-stream-send-geometry.json.
///
/// Chat contract the probe relies on: Send inserts `sent-*` and Stream inserts
/// `stream-*` at index 0; a stream ends at revision 40 (override with
/// `-listStreamSendFinalRevision`); rows conforming to `ListProbeDeclaredHeight`
/// also have their resting height checked. Multiline scenarios grow a draft
/// before Send and measure the newest row against the shrinking composer.
@MainActor
final class ListStreamSendProbe: NSObject {
    private static var current: ListStreamSendProbe?

    static func startIfRequested(chat: ListChatController) {
        guard current == nil, UserDefaults.standard.bool(forKey: "listStreamSendProbe") else { return }
        let probe = ListStreamSendProbe(chat: chat)
        current = probe
        Task { await probe.run() }
    }

    private enum Scenario: String, CaseIterable {
        case sendMidGrow, keyboardSendMidGrow, twoSends, streamSendStream, multilineSendShrink, keyboardMultilineSendShrink
        case keyboardSendAtHalfSecond, keyboardSendAtOneAndHalfSeconds
        var manualFlow: Bool { self == .keyboardSendAtHalfSecond || self == .keyboardSendAtOneAndHalfSeconds }
        var raisesKeyboard: Bool { self == .keyboardSendMidGrow || self == .keyboardMultilineSendShrink || manualFlow }
    }

    /// The gap of one adjacent pair that contains a row inserted by a tap.
    private struct Opening {
        var started: Double
        var bound: Double
        var step: Double
        var lastDeviation: Double
        var closedFrames = 0
        var closed = false
        var reportedOpen = false
    }

    /// A change of the settled gap of one pair, such as an attachment reservation.
    private struct GapChange {
        var old: Double
        var new: Double
        var time: Double
    }

    private struct InsertCurve {
        // A row slide, otherwise the viewport track; "assumed" is diagnostic.
        var source: String
        var begin: Double
        var duration: Double
        var from: Double
        var to: Double
        var points: [Double]
        static func fallback(begin: Double) -> InsertCurve {
            .init(source: "assumed", begin: begin, duration: 0.3, from: 0, to: 0, points: [0.42, 0, 0.58, 1])
        }
        var name: String { "\(source) cubic(\(points.map { String(format: "%.3f", $0) }.joined(separator: ","))) \(String(format: "%.3f", duration)) s" }
        func progress(at time: Double) -> Double {
            let x = min(1, max(0, (time - begin) / duration))
            func bezier(_ s: Double, _ a: Double, _ b: Double) -> Double { 3 * a * s * (1 - s) * (1 - s) + 3 * b * s * s * (1 - s) + s * s * s }
            var low = 0.0, high = 1.0
            for _ in 0..<40 {
                let mid = (low + high) / 2
                if bezier(mid, points[0], points[2]) < x { low = mid } else { high = mid }
            }
            return bezier((low + high) / 2, points[1], points[3])
        }
        func value(at time: Double) -> Double { from + (to - from) * progress(at: time) }
    }

    @MainActor private final class ComposerSend {
        static let fields = ["t", "gap", "slide", "slotResidual", "expectedSlide", "insertionResidual",
                             "barMinY", "barHeight", "viewportOffset", "sentIsNewest"]
        weak var bar: UIView?
        let lines: Int, before: Set<String>
        var sendTime = 0.0, firstSent: Double?
        var heights: [String: Double] = [:]
        var baselineGap: Double?
        var grew: Bool?, shrank: Bool?
        var curve: InsertCurve?
        var distance: Double?
        var insertStart: Double?, insertEnd: Double?
        var lastShrinking: Double?, shrinkEnd: Double?
        var postInsertSamples = 0, postInsertWhileShrinking = 0, postInsertMaxGap = 0.0
        var slotMax = 0.0, slotAboveHalf = 0, slotWorst: [String: Any] = [:]
        var insertionMax = 0.0, insertionAboveHalf = 0, insertionWorst: [String: Any] = [:]
        var curveErrorMax: Double?
        var trace: [[Any]] = []
        init(bar: UIView, lines: Int, before: Set<String>) { self.bar = bar; self.lines = lines; self.before = before }
        var dictionary: [String: Any] {
            var value: [String: Any] = [
                "draftLines": lines, "heights": heights.mapValues(ListStreamSendProbe.json), "insertCurve": curve?.name ?? "unavailable",
                "postInsertSamples": postInsertSamples, "postInsertWhileShrinking": postInsertWhileShrinking,
                "postInsertMaxGap": ListStreamSendProbe.json(postInsertMaxGap),
                "slotResidualMax": ListStreamSendProbe.json(slotMax), "slotResidualFramesAboveHalf": slotAboveHalf, "slotResidualWorst": slotWorst,
                "insertionResidualMax": ListStreamSendProbe.json(insertionMax), "insertionResidualFramesAboveHalf": insertionAboveHalf,
                "insertionResidualWorst": insertionWorst,
                "samples": trace.count, "traceFields": Self.fields,
                "traceSparse": stride(from: 0, to: trace.count, by: max(1, (trace.count + 29) / 30)).map { trace[$0] },
            ]
            if let firstSent { value["firstSentFrame"] = ListStreamSendProbe.json(firstSent) }
            if let baselineGap { value["baselineGap"] = ListStreamSendProbe.json(baselineGap) }
            if let grew { value["draftGrew"] = grew }
            if let shrank { value["composerShrank"] = shrank }
            if let distance { value["insertDistance"] = ListStreamSendProbe.json(distance) }
            if let insertStart { value["insertStart"] = ListStreamSendProbe.json(insertStart) }
            if let insertEnd { value["insertEnd"] = ListStreamSendProbe.json(insertEnd) }
            if let shrinkEnd { value["composerShrinkEnd"] = ListStreamSendProbe.json(shrinkEnd) }
            if let insertStart, let shrinkEnd { value["insertStartedDuringShrink"] = insertStart < shrinkEnd }
            if let curveErrorMax { value["slideCurveErrorMax"] = ListStreamSendProbe.json(curveErrorMax) }
            return value
        }
    }

    @MainActor private final class ScenarioResult {
        let engine: String, scenario: String
        var frames = 0, strictSamples = 0, offscreenSamples = 0, unpresented = 0, nonFinite = 0
        var maxGapError = 0.0, offscreenMaxError = 0.0
        var worst: [String: Any] = [:]
        var openingPairs = 0, closedOpenings = 0, maxOpening = 0.0
        var openingStepMax = 0.0, openingStepLimit = 0.0, openingStepsAboveLimit = 0
        var violations: [String: Int] = [:]
        var samples: [[String: Any]] = []
        var midGrowHits: [[String: Any]] = []
        var keyboardVisible: Bool?
        var taps: [String] = []
        var inserted: [String] = []
        var settled = false, settleSeconds = 0.0
        var lingering: [String] = []
        var composer: ComposerSend?
        var final: [String: Any] = [:]
        var continuityFrames: [[String: Any]] = []
        var sceneFrames: [[String: Any]] = []
        var unchangedTargetRestarts: [[String: Any]] = []
        init(engine: String, scenario: String) { self.engine = engine; self.scenario = scenario }

        var violationCount: Int { violations.values.reduce(0, +) }
        func violate(_ kind: String, _ sample: [String: Any]) {
            violations[kind, default: 0] += 1
            if samples.count < 20 { var entry = sample; entry["kind"] = kind; samples.append(entry) }
        }
        var dictionary: [String: Any] {
            var value: [String: Any] = [
                "engine": engine, "scenario": scenario, "frames": frames, "strictPairSamples": strictSamples,
                "offscreenPairSamples": offscreenSamples, "unpresented": unpresented, "nonFinite": nonFinite,
                "maxGapError": ListStreamSendProbe.json(maxGapError), "offscreenMaxError": ListStreamSendProbe.json(offscreenMaxError),
                "worstGap": worst, "openingPairs": openingPairs, "closedOpenings": closedOpenings,
                "maxOpening": ListStreamSendProbe.json(maxOpening), "openingStepMax": ListStreamSendProbe.json(openingStepMax),
                "openingStepProxyLimit": ListStreamSendProbe.json(openingStepLimit), "openingStepsAboveProxy": openingStepsAboveLimit,
                "firstViolations": Array(samples.prefix(3)), "violations": violations, "violationCount": violationCount,
                "midGrowHits": midGrowHits, "taps": taps, "inserted": inserted, "settled": settled,
                "settleSeconds": ListStreamSendProbe.json(settleSeconds), "lingeringAnimations": lingering,
            ]
            if let keyboardVisible { value["keyboardVisible"] = keyboardVisible }
            if let composer { value["composerSend"] = composer.dictionary }
            if !continuityFrames.isEmpty {
                value["continuityFrames"] = continuityFrames.count
                value["unchangedTargetRestarts"] = unchangedTargetRestarts
            }
            value.merge(final) { _, new in new }
            return value
        }
    }

    private weak var initialChat: ListChatController?
    private weak var lists: ListsScreenController?
    private weak var chat: ListChatController?
    private let report = UILabel()
    private var link: CADisplayLink?
    private var result: ScenarioResult?
    private var results: [ScenarioResult] = []
    private var scenarioStart = 0.0
    private var known: Set<String> = []
    private var streamed: Set<String> = []
    private var firstSeen: [String: Double] = [:]
    private var openings: [String: Opening] = [:]
    private var settledGaps: [String: Double] = [:]
    private var gapChanges: [String: GapChange] = [:]
    private var complete = false
    private var notReadyAtStart = false
    private var failure: String?
    private var previousTracks: [String: (target: Double, generation: UInt64, begin: Double, end: Double)] = [:]
    private var displayTime = 0.0
    private var rowIdentities: [ObjectIdentifier: String] = [:]
    private var capturesContinuity: Bool { UserDefaults.standard.bool(forKey: "listStreamSendContinuity") }

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
        report.text = " "; report.accessibilityLabel = "Stream and send geometry probe"
        report.accessibilityIdentifier = "streamSendGeometry"; report.isAccessibilityElement = true
        lists.view.addSubview(report)
        publish()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common); self.link = link

        let defaults = UserDefaults.standard
        let engines = (defaults.string(forKey: "listStreamSendEngines")?.split(separator: ",").map(String.init))
            ?? ScrollEngineMode.allCases.map(\.rawValue)
        let scenarios = (defaults.string(forKey: "listStreamSendScenarios")?.split(separator: ",").compactMap { Scenario(rawValue: String($0)) })
            ?? Scenario.allCases.filter { !$0.manualFlow }
        for engine in engines {
            guard let mode = ScrollEngineMode(rawValue: engine) else { failure = "unknown engine \(engine)"; continue }
            for scenario in scenarios {
                guard let chat = await freshChat(mode) else {
                    failure = "\(engine)/\(scenario.rawValue): chat did not load"; continue
                }
                await perform(scenario, engine: engine, chat: chat)
                publish()
            }
        }
        link.invalidate(); self.link = nil
        complete = true
        publish()
    }

    private func freshChat(_ mode: ScrollEngineMode) async -> ListChatController? {
        if let composer = chat.flatMap({ composer(in: $0) }), composer.isFirstResponder {
            composer.resignFirstResponder()
            try? await Task.sleep(for: .milliseconds(700))
        }
        guard let lists, let engines = Self.find(in: lists.view, UISegmentedControl.self, { $0.accessibilityIdentifier == "listEngines" }),
              let index = ScrollEngineMode.allCases.firstIndex(of: mode) else { return nil }
        let previous = lists.children.first
        // Re-sending the action rebuilds the child, even for the same engine.
        engines.selectedSegmentIndex = index
        engines.sendActions(for: .valueChanged)
        let loaded = await wait(8) {
            guard let next = lists.children.first as? ListChatController, next !== previous, next.view.window != nil else { return false }
            return !next.list.loadedIndexRange.isEmpty && next.list.engineMode == mode
        }
        guard loaded, let next = lists.children.first as? ListChatController else { return nil }
        let list = next.list
        notReadyAtStart = !(await wait(4) { list.loadedIndexRange.allSatisfy { list.loadedItemView(at: $0)?.isDisplayReady ?? false } })
        lists.view.bringSubviewToFront(report)
        chat = next
        _ = await rest(next, timeout: 5)
        return next
    }

    private func perform(_ scenario: Scenario, engine: String, chat: ListChatController) async {
        let result = ScenarioResult(engine: engine, scenario: scenario.rawValue)
        results.append(result)
        known = Set(chat.list.items.map(\.identity)); streamed.removeAll(); firstSeen.removeAll()
        openings.removeAll(); settledGaps.removeAll(); gapChanges.removeAll()
        previousTracks.removeAll()
        let initialCount = chat.list.items.count
        if notReadyAtStart { result.violate("rowsNotReadyAtStart", ["loaded": "\(chat.list.loadedIndexRange)"]) }
        if scenario.raisesKeyboard, let composer = composer(in: chat) {
            composer.becomeFirstResponder()
            result.keyboardVisible = await wait(3) {
                chat.view.keyboardLayoutGuide.layoutFrame.height > chat.view.safeAreaInsets.bottom + 40
            }
            _ = await rest(chat, timeout: 3)
        }
        scenarioStart = CACurrentMediaTime()
        self.result = result

        var lastStream: String?
        switch scenario {
        case .sendMidGrow, .keyboardSendMidGrow:
            lastStream = await tap("Stream", chat, result)
            await waitForRevision(lastStream, 4, chat)
            await send(chat, result, stream: lastStream, duringGrow: true)
        case .twoSends:
            lastStream = await tap("Stream", chat, result)
            await waitForRevision(lastStream, 2, chat)
            await send(chat, result, stream: lastStream, duringGrow: false)
            await waitForRevision(lastStream, 8, chat)
            await send(chat, result, stream: lastStream, duringGrow: true)
        case .streamSendStream:
            let first = await tap("Stream", chat, result)
            await waitForRevision(first, 4, chat)
            await send(chat, result, stream: first, duringGrow: true)
            try? await Task.sleep(for: .milliseconds(300))
            lastStream = await tap("Stream", chat, result)
        case .multilineSendShrink:
            await sendDraft(chat, result, lines: 4)
        case .keyboardMultilineSendShrink:
            await sendDraft(chat, result, lines: 7)
        case .keyboardSendAtHalfSecond, .keyboardSendAtOneAndHalfSeconds:
            lastStream = await tap("Stream", chat, result)
            try? await Task.sleep(for: .milliseconds(scenario == .keyboardSendAtHalfSecond ? 500 : 1500))
            await tap("Send", chat, result)
        }
        if let lastStream { await waitForRevision(lastStream, finalRevision, chat, timeout: 10) }
        let begin = CACurrentMediaTime()
        let rested = await rest(chat, timeout: 12)
        result.settled = rested.settled; result.lingering = rested.lingering
        result.settleSeconds = CACurrentMediaTime() - begin
        if let send = result.composer { finishDraft(send, result) }
        self.result = nil
        result.final = finalChecks(chat, result, initialCount: initialCount, lastStream: lastStream)
        if let composer = composer(in: chat), composer.isFirstResponder { composer.resignFirstResponder() }
    }

    /// Presses a button and returns the identity it inserted, once the list shows it.
    @discardableResult
    private func tap(_ title: String, _ chat: ListChatController, _ result: ScenarioResult) async -> String? {
        guard let button = Self.find(in: chat.view, UIButton.self, { $0.currentTitle == title }) else {
            result.violate("missingControl", ["title": title]); return nil
        }
        let prefix = title == "Send" ? "sent-" : "stream-"
        let before = Set(chat.list.items.map(\.identity))
        button.sendActions(for: .touchUpInside)
        result.taps.append(title)
        var identity: String?
        _ = await wait(3) {
            identity = chat.list.items.first { $0.identity.hasPrefix(prefix) && !before.contains($0.identity) }?.identity
            return identity != nil
        }
        if identity == nil { result.violate("insertionNotShown", ["title": title, "t": elapsed]) }
        return identity
    }

    /// A send meant to land mid-grow waits for the stream row's next height
    /// animation, then 60 ms into it, and fails the scenario if it missed.
    /// Measured rows grow only when their text wraps, so the wait is long.
    private func send(_ chat: ListChatController, _ result: ScenarioResult, stream: String?, duringGrow: Bool) async {
        func growing() -> Bool {
            guard let stream, let index = chat.list.items.firstIndex(where: { $0.identity == stream }),
                  let view = chat.list.loadedItemView(at: index) else { return false }
            return view.layer.animation(forKey: "ultraview.list.height") != nil
        }
        if duringGrow, await wait(2, growing) { try? await Task.sleep(for: .milliseconds(60)) }
        let hit = growing()
        let revision = stream.flatMap { id in chat.list.items.first { $0.identity == id }?.revision } ?? 0
        result.midGrowHits.append(["required": duringGrow, "hit": hit, "revision": revision, "t": elapsed])
        if duringGrow && !hit { result.violate("midGrowMissed", ["stream": stream ?? "", "revision": revision, "t": elapsed]) }
        await tap("Send", chat, result)
    }

    private func sendDraft(_ chat: ListChatController, _ result: ScenarioResult, lines: Int) async {
        guard let composer = composer(in: chat), let bar = composerBar(in: chat) else {
            result.violate("missingControl", ["title": "composer"]); return
        }
        let single = Double(bar.bounds.height), line = Double(composer.font?.lineHeight ?? 20)
        composer.text = (1...lines).map { "Draft line \($0)" }.joined(separator: "\n")
        composer.delegate?.textViewDidChange?(composer)
        _ = await wait(2) { [bar.layer, composer.layer].allSatisfy { ($0.animationKeys() ?? []).isEmpty } }
        _ = await rest(chat, timeout: 3)
        let send = ComposerSend(bar: bar, lines: lines, before: Set(chat.list.items.map(\.identity)))
        let drafted = Double(bar.bounds.height)
        send.heights = ["single": single, "draft": drafted, "line": line]
        send.grew = drafted - single >= 2 * line - 0.5
        if send.grew == false { result.violate("draftNotMultiline", ["single": single, "draft": drafted, "t": elapsed]) }
        send.baselineGap = measureNewest(chat.list, bar: bar)?.gap
        send.sendTime = CACurrentMediaTime()
        result.composer = send
        await tap("Send", chat, result)
    }
    private func finishDraft(_ send: ComposerSend, _ result: ScenarioResult) {
        guard let bar = send.bar, let single = send.heights["single"], let draft = send.heights["draft"] else { return }
        let final = Double(bar.bounds.height)
        send.heights["final"] = final
        send.shrank = abs(final - single) <= 0.5 && draft - final > 0.5
        if send.shrank == false { result.violate("composerDidNotShrink", ["heights": send.heights.mapValues(Self.json)]) }
        if send.insertStart == nil { result.violate("insertNotSampled", ["samples": send.trace.count]) }
        else if send.postInsertSamples == 0 { result.violate("noFrameAfterInsert", ["insertEnd": Self.json(send.insertEnd ?? .nan), "samples": send.trace.count]) }
    }

    private func waitForRevision(_ identity: String?, _ revision: UInt64, _ chat: ListChatController, timeout: Double = 5) async {
        guard let identity else { return }
        let reached = await wait(timeout) {
            (chat.list.items.first { $0.identity == identity }?.revision ?? 0) >= revision
        }
        if !reached { result?.violate("revisionTimeout", ["identity": identity, "revision": revision, "t": elapsed]) }
    }

    private func wait(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = CACurrentMediaTime() + timeout
        while CACurrentMediaTime() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// No motion, no list animation keys, and no pass for half a second.
    private func rest(_ chat: ListChatController, timeout: Double) async -> (settled: Bool, lingering: [String]) {
        let list = chat.list, deadline = CACurrentMediaTime() + timeout
        var passes = list.appliedPassCount, since = CACurrentMediaTime(), lingering: [String] = []
        while CACurrentMediaTime() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            lingering = animationKeys(list)
            let native = (list.contentView as? UIScrollView).map { $0.isDecelerating || $0.isTracking } ?? false
            let moving = list.isScrollFlightActive || list.isTracking || native || !lingering.isEmpty
            if list.appliedPassCount != passes || moving { passes = list.appliedPassCount; since = CACurrentMediaTime(); continue }
            if CACurrentMediaTime() - since >= 0.5 { return (true, []) }
        }
        return (false, lingering)
    }

    private func animationKeys(_ list: UltraListView) -> [String] {
        var keys = (list.contentView.layer.animationKeys() ?? []).filter { $0.hasPrefix("ultraview.") }.map { "content:\($0)" }
        for index in list.loadedIndexRange {
            guard let layer = list.loadedItemView(at: index)?.layer else { continue }
            keys += (layer.animationKeys() ?? []).filter { $0.hasPrefix("ultraview.") }.map { "\(list.items[index].identity):\($0)" }
        }
        return keys
    }

    private var elapsed: Double { CACurrentMediaTime() - scenarioStart }
    private var finalRevision: UInt64 {
        UserDefaults.standard.object(forKey: "listStreamSendFinalRevision") == nil ? 40 : UInt64(max(0, UserDefaults.standard.integer(forKey: "listStreamSendFinalRevision")))
    }

    // MARK: Sampling

    private struct Row {
        var identity: String
        var rect: CGRect
        var settled: CGRect
        var visible: Bool
    }

    @objc private func tick(_ link: CADisplayLink) {
        displayTime = link.timestamp
        guard let result, let chat, chat.view.window != nil, let listLayer = chat.list.layer.presentation() else { return }
        let list = chat.list, time = elapsed
        result.frames += 1
        let inverted = list.contentView.transform.d < 0, insets = list.viewportInsets, height = Double(list.bounds.height)
        let band = inverted ? (insets.bottom, height - insets.top) : (insets.top, height - insets.bottom)
        for item in list.items where !known.contains(item.identity) {
            known.insert(item.identity); result.inserted.append(item.identity); firstSeen[item.identity] = time
            if item.identity.hasPrefix("stream-") { streamed.insert(item.identity) }
        }
        if capturesContinuity { sampleScene(list, time: time, result: result, listLayer: listLayer) }
        var previous: Row?
        for index in list.loadedIndexRange {
            guard let view = list.loadedItemView(at: index), let settled = list.settledFrame(at: index) else { previous = nil; continue }
            guard let layer = view.layer.presentation() else { result.unpresented += 1; previous = nil; continue }
            let rect = layer.convert(layer.bounds, to: listLayer)
            let values = [rect.minX, rect.minY, rect.width, rect.height, settled.minY, settled.height]
            guard values.allSatisfy(\.isFinite) else {
                result.nonFinite += 1; result.violate("nonFinite", ["t": time, "index": index, "rect": "\(rect)", "settled": "\(settled)"])
                previous = nil; continue
            }
            let visible = Double(rect.maxY) > band.0 && Double(rect.minY) < band.1
            let row = Row(identity: list.items[index].identity, rect: rect, settled: settled, visible: visible)
            if capturesContinuity { sampleContinuity(view, row, index: index, time: time, result: result, list: list, listLayer: listLayer) }
            if let previous { check(previous, row, inverted: inverted, time: time, result: result) }
            previous = row
        }
        if let send = result.composer { sampleComposer(send, list, result: result) }
    }

    private func sampleContinuity(_ view: ListRowView, _ row: Row, index: Int, time: Double, result: ScenarioResult, list: UltraListView, listLayer: CALayer) {
        guard let layer = view.layer.presentation() else { return }
        func rectangle(_ layer: CALayer) -> [Double] {
            let value = (layer.presentation() ?? layer).convert((layer.presentation() ?? layer).bounds, to: listLayer)
            return [value.minX, value.minY, value.width, value.height]
        }
        var tracks: [String: Any] = [:]
        for (name, owner, target) in [("height", view.layer, view.layer.bounds.height),
                                      ("positionY", view.layer, view.layer.position.y),
                                      ("viewportOffset", list.contentView.layer, list.contentView.layer.bounds.minY)] {
            let key = name == "viewportOffset" ? name : row.identity + "/" + name
            guard let animation = owner.animation(forKey: "ultraview.list.\(name)") as? CABasicAnimation else {
                previousTracks.removeValue(forKey: key); continue
            }
            let generation = (animation.value(forKey: "ultraviewGeneration") as? NSNumber)?.uint64Value ?? 0
            let start = animation.beginTime == 0
                ? (animation.value(forKey: "ultraviewStartTime") as? NSNumber)?.doubleValue ?? owner.convertTime(CACurrentMediaTime(), from: nil)
                : animation.beginTime
            let end = owner.convertTime(start + animation.duration / max(0.000001, Double(animation.speed)), to: nil)
            if let previous = previousTracks[key], abs(previous.target - target) < 0.000001,
               previous.generation != generation, CACurrentMediaTime() < previous.end,
               result.unchangedTargetRestarts.count < 200 {
                result.unchangedTargetRestarts.append(["t": time, "row": row.identity, "property": name,
                    "target": target, "oldGeneration": previous.generation, "generation": generation,
                    "oldBegin": previous.begin, "begin": animation.beginTime])
            }
            previousTracks[key] = (target, generation, animation.beginTime, end)
            var first: [Float] = [0, 0], last: [Float] = [1, 1]
            animation.timingFunction?.getControlPoint(at: 1, values: &first)
            animation.timingFunction?.getControlPoint(at: 2, values: &last)
            tracks[name] = ["generation": generation, "begin": animation.beginTime,
                "modelStart": (animation.value(forKey: "ultraviewStartTime") as? NSNumber)?.doubleValue ?? 0,
                "duration": animation.duration, "speed": animation.speed,
                "from": (animation.fromValue as? NSNumber)?.doubleValue ?? 0,
                "to": (animation.toValue as? NSNumber)?.doubleValue ?? 0,
                "curve": first + last]
        }
        var hosts: [[String: Any]] = []
        for child in view.subviews {
            var value: [String: Any] = ["class": String(describing: type(of: child)),
                "identity": String(describing: ObjectIdentifier(child)), "hidden": child.isHidden,
                "presented": child.layer.presentation() != nil, "modelHeight": child.bounds.height,
                "z": child.layer.zPosition, "order": view.subviews.firstIndex(of: child) ?? -1]
            if child.layer.presentation() != nil { value["rect"] = rectangle(child.layer) }
            if let host = child as? NodeHostView {
                value["hasContent"] = host.hasContent
                if let card = Self.find(in: host, UIView.self, { $0.layer.cornerRadius >= 12 }), card.layer.presentation() != nil {
                    value["card"] = rectangle(card.layer)
                    value["cardModelHeight"] = card.bounds.height
                }
                value["commitCount"] = host.statistics.current.commits
            }
            hosts.append(value)
        }
        guard result.continuityFrames.count < 8000 else { return }
        result.continuityFrames.append(["t": time, "clock": CACurrentMediaTime(), "displayTime": displayTime, "row": row.identity,
            "revision": list.items[index].revision, "index": index, "visible": row.visible,
            "rect": [row.rect.minX, row.rect.minY, row.rect.width, row.rect.height],
            "settled": [row.settled.minY, row.settled.height], "positionY": layer.position.y,
            "height": layer.bounds.height, "modelPositionY": view.layer.position.y,
            "modelHeight": view.layer.bounds.height, "z": view.layer.zPosition,
            "order": view.superview?.subviews.firstIndex(of: view) ?? -1,
            "viewport": list.contentView.layer.presentation()?.bounds.minY ?? list.contentView.layer.bounds.minY,
            "tracks": tracks, "children": hosts])
    }

    private func sampleScene(_ list: UltraListView, time: Double, result: ScenarioResult, listLayer: CALayer) {
        var loaded: [ObjectIdentifier: Int] = [:]
        for index in list.loadedIndexRange {
            guard let view = list.loadedItemView(at: index) else { continue }
            let identity = ObjectIdentifier(view)
            loaded[identity] = index; rowIdentities[identity] = list.items[index].identity
        }
        var entries: [[String: Any]] = []
        func inspect(_ view: UIView, parent: String, order: Int) {
            let identity = ObjectIdentifier(view), name = String(describing: identity)
            var entry: [String: Any] = ["identity": name, "parent": parent, "order": order,
                "class": String(describing: type(of: view)), "z": view.layer.zPosition,
                "hidden": view.isHidden, "alpha": view.alpha, "clips": view.clipsToBounds,
                "modelPosition": [view.layer.position.x, view.layer.position.y],
                "modelBounds": [view.bounds.minX, view.bounds.minY, view.bounds.width, view.bounds.height],
                "animations": view.layer.animationKeys() ?? []]
            var tracks: [String: Any] = [:]
            for key in view.layer.animationKeys() ?? [] {
                guard let animation = view.layer.animation(forKey: key) as? CABasicAnimation else { continue }
                tracks[key] = ["begin": animation.beginTime, "duration": animation.duration,
                    "speed": animation.speed, "from": (animation.fromValue as? NSNumber)?.doubleValue ?? 0,
                    "to": (animation.toValue as? NSNumber)?.doubleValue ?? 0,
                    "generation": (animation.value(forKey: "ultraviewGeneration") as? NSNumber)?.uint64Value ?? 0]
            }
            if !tracks.isEmpty { entry["tracks"] = tracks }
            if let label = view.accessibilityIdentifier { entry["accessibilityIdentifier"] = label }
            if let layer = view.layer.presentation() {
                let rect = layer.convert(layer.bounds, to: listLayer)
                entry["rect"] = [rect.minX, rect.minY, rect.width, rect.height]
                entry["opacity"] = layer.opacity
            }
            if view is ListRowView {
                let rowIdentity = rowIdentities[identity] ?? view.accessibilityIdentifier.flatMap {
                    $0.hasPrefix("row-") ? String($0.dropFirst(4)) : nil
                }
                entry["row"] = rowIdentity ?? "unknown"
                entry["loadedIndex"] = loaded[identity] ?? -1
                if let row = rowIdentity { entry["itemIndex"] = list.items.firstIndex { $0.identity == row } ?? -1 }
            }
            if let host = view as? NodeHostView { entry["hasContent"] = host.hasContent }
            if let label = view as? UILabel { entry["text"] = label.text ?? "" }
            entries.append(entry)
            for (index, child) in view.subviews.enumerated() { inspect(child, parent: name, order: index) }
        }
        inspect(list, parent: "", order: 0)
        let inverted = list.contentView.transform.d < 0, insets = list.viewportInsets
        result.sceneFrames.append(["t": time, "clock": CACurrentMediaTime(), "displayTime": displayTime,
            "loaded": [list.loadedIndexRange.lowerBound, list.loadedIndexRange.upperBound],
            "band": inverted ? [insets.bottom, list.bounds.height - insets.top] : [insets.top, list.bounds.height - insets.bottom],
            "views": entries])
    }

    private struct NewestSample {
        var identity: String
        var gap: Double
        var slide: Double
        var scale: Double
        var bar: CGRect
        var viewport: Double
    }
    private func measureNewest(_ list: UltraListView, bar: UIView) -> NewestSample? {
        guard let listLayer = list.layer.presentation(), let barLayer = bar.layer.presentation(), list.loadedIndexRange.contains(0),
              let view = list.loadedItemView(at: 0), let layer = view.layer.presentation(),
              let parent = view.layer.superlayer?.presentation() else { return nil }
        let barRect = barLayer.convert(barLayer.bounds, to: listLayer), rect = layer.convert(layer.bounds, to: listLayer)
        let scale = Double(parent.convert(CGPoint(x: 0, y: 1), to: listLayer).y - parent.convert(CGPoint.zero, to: listLayer).y)
        let content = list.contentView.layer
        let sample = NewestSample(identity: list.items[0].identity, gap: Double(barRect.minY - rect.maxY),
                                  slide: scale * Double(layer.position.y - view.layer.position.y), scale: scale, bar: barRect,
                                  viewport: Double((content.presentation() ?? content).bounds.minY - content.bounds.minY))
        let values = [sample.gap, sample.slide, sample.scale, Double(barRect.minY), Double(barRect.height), sample.viewport]
        return values.allSatisfy(\.isFinite) ? sample : nil
    }
    private func sampleComposer(_ send: ComposerSend, _ list: UltraListView, result: ScenarioResult) {
        // Residuals diagnose curve differences. The strict composer gap starts
        // after insertion ends and at least 0.3 s after the sent row appears.
        let t = CACurrentMediaTime() - send.sendTime
        guard t >= 0, t <= 1.2, let bar = send.bar, let sample = measureNewest(list, bar: bar) else { return }
        let sent = sample.identity.hasPrefix("sent-") && !send.before.contains(sample.identity)
        let shrinking = abs(sample.bar.height - bar.bounds.height) > 0.5
        if shrinking { send.lastShrinking = t; send.shrinkEnd = nil }
        else if send.lastShrinking != nil, send.shrinkEnd == nil { send.shrinkEnd = t }
        if sent, send.firstSent == nil { send.firstSent = t }
        if sent, send.curve == nil, let first = send.firstSent, let view = list.loadedItemView(at: 0) {
            if let slide = insertCurve("rowSlide", view.layer, "ultraview.list.positionY", sendTime: send.sendTime) {
                send.curve = slide; send.distance = abs(slide.to - slide.from)
            } else if let track = insertCurve("viewport", list.contentView.layer, "ultraview.list.viewportOffset", sendTime: send.sendTime) {
                send.curve = track
            } else if t - first > 0.1 { send.curve = .fallback(begin: first) }
            if let curve = send.curve {
                if send.distance == nil { send.distance = list.settledFrame(at: 0).map { Double($0.height) } }
                send.insertStart = curve.begin
                send.insertEnd = max(curve.begin + curve.duration, first + 0.3)
            }
        }
        let slot = sample.gap + sample.slide
        var expectedSlide: Double?, insertion: Double?
        if sent, let curve = send.curve {
            if curve.source == "rowSlide" {
                expectedSlide = sample.scale * curve.value(at: t)
                send.curveErrorMax = max(send.curveErrorMax ?? 0, abs(sample.slide - (expectedSlide ?? 0)))
            }
            if let distance = send.distance { insertion = sample.gap + distance * (1 - curve.progress(at: t)) }
        }
        var entry: [String: Any] = ["t": t, "gap": sample.gap, "slide": sample.slide, "slotResidual": slot,
                                    "newest": sample.identity, "barHeight": Double(sample.bar.height), "shrinking": shrinking]
        if let insertion { entry["insertionResidual"] = insertion }
        if abs(slot) > 0.5 { send.slotAboveHalf += 1 }
        if abs(slot) > send.slotMax { send.slotMax = abs(slot); send.slotWorst = entry }
        if let insertion {
            if abs(insertion) > 0.5 { send.insertionAboveHalf += 1 }
            if abs(insertion) > send.insertionMax { send.insertionMax = abs(insertion); send.insertionWorst = entry }
        }
        if sent, let end = send.insertEnd, t >= end + 0.002 {
            send.postInsertSamples += 1
            if shrinking { send.postInsertWhileShrinking += 1 }
            send.postInsertMaxGap = max(send.postInsertMaxGap, abs(sample.gap))
            if abs(sample.gap) > 0.5 { result.violate("composerGapAfterInsert", entry) }
        }
        guard send.trace.count < 160 else { return }
        func trim(_ value: Double?, _ scale: Double = 100) -> Any { value.map { ($0 * scale).rounded() / scale } ?? NSNull() }
        send.trace.append([trim(t, 1000), trim(sample.gap), trim(sample.slide), trim(slot), trim(expectedSlide), trim(insertion),
                           trim(Double(sample.bar.minY)), trim(Double(sample.bar.height)), trim(sample.viewport), sent ? 1 : 0])
    }
    private func insertCurve(_ source: String, _ layer: CALayer, _ key: String, sendTime: Double) -> InsertCurve? {
        guard let animation = layer.animation(forKey: key) as? CABasicAnimation, !(animation is CASpringAnimation),
              let from = (animation.fromValue as? NSNumber)?.doubleValue, let to = (animation.toValue as? NSNumber)?.doubleValue,
              animation.duration > 0, animation.speed > 0 else { return nil }
        let begin = animation.beginTime == 0 ? CACurrentMediaTime() : layer.convertTime(animation.beginTime, to: nil)
        guard begin >= sendTime - 0.002 else { return nil }
        var start: [Float] = [0, 0], end: [Float] = [1, 1]
        animation.timingFunction?.getControlPoint(at: 1, values: &start)
        animation.timingFunction?.getControlPoint(at: 2, values: &end)
        return InsertCurve(source: source, begin: begin - sendTime, duration: animation.duration / Double(animation.speed),
                           from: from, to: to, points: (start + end).map(Double.init))
    }

    private func check(_ low: Row, _ high: Row, inverted: Bool, time: Double, result: ScenarioResult) {
        // `low` has the smaller index. Inverted, it sits below `high` on screen.
        let actual = Double(inverted ? low.rect.minY - high.rect.maxY : high.rect.minY - low.rect.maxY)
        let expected = Double(high.settled.minY - low.settled.maxY)
        let deviation = actual - expected
        let key = "\(low.identity)|\(high.identity)"
        var sample: [String: Any] = ["t": time, "pair": key, "actual": actual, "expected": expected,
                                     "low": "\(low.rect)", "high": "\(high.rect)", "visible": low.visible && high.visible]
        if let old = settledGaps[key], abs(old - expected) > 0.01 { gapChanges[key] = GapChange(old: old, new: expected, time: time) }
        settledGaps[key] = expected

        // Only a pair formed as a streamed row first appears may open: that row fades in at
        // its final frame. A sent row slides welded to its neighbour, so its pairs stay strict,
        // and so do pairs an older streamed row forms later.
        if openings[key] == nil {
            let sent = [low, high].contains { result.inserted.contains($0.identity) && !streamed.contains($0.identity) }
            let fresh = [low, high].filter { streamed.contains($0.identity) && time - (firstSeen[$0.identity] ?? -1) <= 0.1 }
            if !sent, let height = fresh.map({ Double($0.settled.height) }).max() {
                result.openingPairs += 1
                openings[key] = Opening(started: time, bound: height + abs(expected) + 0.5, step: max(2, 0.35 * height), lastDeviation: deviation)
            }
        }
        if var opening = openings[key], !opening.closed {
            result.maxOpening = max(result.maxOpening, abs(deviation))
            sample["bound"] = opening.bound
            if abs(deviation) > opening.bound { result.violate("openingBound", sample) }
            if abs(deviation) > abs(opening.lastDeviation) + 0.5 { result.violate("openingWidened", sample) }
            let step = abs(deviation - opening.lastDeviation)
            result.openingStepMax = max(result.openingStepMax, step); result.openingStepLimit = max(result.openingStepLimit, opening.step)
            if step > opening.step { result.openingStepsAboveLimit += 1 }
            opening.lastDeviation = deviation
            opening.closedFrames = abs(deviation) <= 0.5 ? opening.closedFrames + 1 : 0
            if opening.closedFrames >= 3 { opening.closed = true; result.closedOpenings += 1 }
            else if time - opening.started > 1, !opening.reportedOpen { opening.reportedOpen = true; result.violate("openingNeverClosed", sample) }
            openings[key] = opening
            return
        }
        if let change = gapChanges[key], time - change.time <= 0.6 {
            let low = min(change.old, change.new) - 0.5, high = max(change.old, change.new) + 0.5
            if actual < low || actual > high { result.violate("gapChangeOutOfRange", sample) }
            return
        }
        guard low.visible && high.visible else {
            result.offscreenSamples += 1
            result.offscreenMaxError = max(result.offscreenMaxError, abs(deviation))
            return
        }
        result.strictSamples += 1
        if abs(deviation) > result.maxGapError { result.maxGapError = abs(deviation); result.worst = sample }
        if abs(deviation) > 0.5 { result.violate(actual < expected - 0.5 ? "overlap" : "gap", sample) }
    }

    // MARK: End state

    private func finalChecks(_ chat: ListChatController, _ result: ScenarioResult, initialCount: Int, lastStream: String?) -> [String: Any] {
        let list = chat.list, content = list.contentView
        var staleMax = 0.0, settledMax = 0.0, heightMismatch = 0, heightChecked = 0, nonFinite = 0
        for index in list.loadedIndexRange {
            guard let view = list.loadedItemView(at: index), let settled = list.settledFrame(at: index) else { continue }
            let model = view.convert(view.bounds, to: list)
            let presented = view.layer.presentation().flatMap { layer in list.layer.presentation().map { layer.convert(layer.bounds, to: $0) } } ?? model
            // Settled frames are relative to the scroll offset, which is the content view's bounds origin at rest.
            let expected = content.convert(settled.offsetBy(dx: content.bounds.minX, dy: content.bounds.minY), to: list)
            let rects = [model, presented, expected]
            if !rects.allSatisfy({ [$0.minX, $0.minY, $0.width, $0.height].allSatisfy(\.isFinite) }) { nonFinite += 1; continue }
            staleMax = max(staleMax, Self.distance(presented, model))
            settledMax = max(settledMax, Self.distance(model, expected))
            if let row = list.items[index] as? any ListProbeDeclaredHeight {
                heightChecked += 1
                if abs(Double(settled.height) - row.declaredHeight) > 0.5 { heightMismatch += 1 }
            }
        }
        var value: [String: Any] = ["staleMax": Self.json(staleMax), "settledMax": Self.json(settledMax),
                                    "heightMismatch": heightMismatch, "heightChecked": heightChecked, "finalNonFinite": nonFinite,
                                    "loaded": "\(list.loadedIndexRange)", "insets": "\(list.viewportInsets.top)/\(list.viewportInsets.bottom)",
                                    "bounds": "\(list.bounds.size)", "offset": Self.json(list.currentScrollOffset)]
        let inverted = content.transform.d < 0
        if list.loadedIndexRange.contains(0), let view = list.loadedItemView(at: 0) {
            let rect = view.layer.presentation().flatMap { layer in list.layer.presentation().map { layer.convert(layer.bounds, to: $0) } } ?? view.convert(view.bounds, to: list)
            let edge = Double(inverted ? rect.maxY : rect.minY)
            let line = inverted ? Double(list.bounds.height) - list.viewportInsets.top : list.viewportInsets.top
            value["newestGapToInset"] = Self.json(inverted ? line - edge : edge - line)
            if let bar = composerBar(in: chat) {
                value["newestGapToComposer"] = Self.json(Double(bar.convert(bar.bounds, to: list).minY) - Double(rect.maxY))
            }
        } else { value["newestLoaded"] = false }

        // The taps alone predict the collection: each insertion lands at index 0.
        var problems: [String] = []
        let items = list.items
        if items.count != initialCount + result.taps.count { problems.append("count \(items.count) expected \(initialCount + result.taps.count)") }
        let expectedPrefixes = result.taps.reversed().map { $0 == "Send" ? "sent-" : "stream-" }
        for (offset, prefix) in expectedPrefixes.enumerated() where !(items.indices.contains(offset) && items[offset].identity.hasPrefix(prefix)) {
            problems.append("index \(offset) is \(items.indices.contains(offset) ? items[offset].identity : "missing"), expected \(prefix)")
        }
        if let lastStream {
            let revision = items.first { $0.identity == lastStream }?.revision
            if revision != finalRevision { problems.append("\(lastStream) revision \(revision.map(String.init) ?? "missing"), expected \(finalRevision)") }
        }
        if result.inserted.count != result.taps.count { problems.append("inserted \(result.inserted) for taps \(result.taps)") }
        value["modelOK"] = problems.isEmpty
        if !problems.isEmpty { value["modelProblems"] = problems }
        return value
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> Double {
        Double(max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.width - b.width), abs(a.height - b.height)))
    }

    // MARK: Report

    private func publish() {
        var document: [String: Any] = ["complete": complete, "scenarios": results.map(\.dictionary)]
        if let failure { document["failure"] = failure }
        if let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]) {
            report.accessibilityValue = String(decoding: data, as: UTF8.self)
        }
        document["violationSamples"] = results.map { ["engine": $0.engine, "scenario": $0.scenario, "samples": $0.samples] }
        document["composerTraces"] = results.compactMap { result in
            result.composer.map { ["engine": result.engine, "scenario": result.scenario, "fields": ComposerSend.fields, "trace": $0.trace] }
        }
        if let data = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]),
           let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? data.write(to: directory.appendingPathComponent("list-stream-send-geometry.json"), options: .atomic)
            if capturesContinuity {
                let continuity: [String: Any] = ["complete": complete, "scenarios": results.map {
                    ["engine": $0.engine, "scenario": $0.scenario, "frames": $0.continuityFrames,
                     "sceneFrames": $0.sceneFrames,
                     "unchangedTargetRestarts": $0.unchangedTargetRestarts] as [String: Any]
                }]
                if let data = try? JSONSerialization.data(withJSONObject: continuity, options: [.sortedKeys]) {
                    try? data.write(to: directory.appendingPathComponent("list-stream-send-continuity.json"), options: .atomic)
                }
            }
        }
        if complete { print("LIST-STREAM-SEND \(report.accessibilityValue ?? "")") }
    }

    nonisolated fileprivate static func json(_ value: Double) -> Any { value.isFinite ? value : String(value) }

    private func composer(in chat: ListChatController) -> UITextView? {
        Self.find(in: chat.view, UITextView.self) { $0.accessibilityIdentifier == "composer" }
    }

    private func composerBar(in chat: ListChatController) -> UIView? {
        Self.find(in: chat.view, UIView.self) { $0.accessibilityIdentifier == "composerBar" }
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
/// Rows whose resting height is fixed by their data rather than measured from content.
@MainActor
protocol ListProbeDeclaredHeight {
    var declaredHeight: Double { get }
}
extension DemoListRow: ListProbeDeclaredHeight {
    var declaredHeight: Double { height }
}
#endif
