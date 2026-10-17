#if canImport(UIKit)
import UIKit
import UltraView

/// Samples on-screen row geometry while Chat streams and sends:
///
///     -screen lists -listScreen chat -listStreamSendProbe YES
///     [-listStreamSendEngines uiKit,stepped,keyframe]
///     [-listStreamSendScenarios sendMidGrow,keyboardSendMidGrow,twoSends,streamSendStream]
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
/// also have their resting height checked.
@MainActor
final class ListStreamSendProbe: NSObject {
    private static var current: ListStreamSendProbe?

    static func startIfRequested(chat: ListChatController) {
        guard current == nil, UserDefaults.standard.bool(forKey: "listStreamSendProbe") else { return }
        let probe = ListStreamSendProbe(chat: chat)
        current = probe
        Task { await probe.run() }
    }

    private enum Scenario: String, CaseIterable { case sendMidGrow, keyboardSendMidGrow, twoSends, streamSendStream }

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
        var final: [String: Any] = [:]
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
            ?? Scenario.allCases
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
        let initialCount = chat.list.items.count
        if notReadyAtStart { result.violate("rowsNotReadyAtStart", ["loaded": "\(chat.list.loadedIndexRange)"]) }
        if scenario == .keyboardSendMidGrow, let composer = composer(in: chat) {
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
        }
        if let lastStream { await waitForRevision(lastStream, finalRevision, chat, timeout: 10) }
        let begin = CACurrentMediaTime()
        let rested = await rest(chat, timeout: 12)
        result.settled = rested.settled; result.lingering = rested.lingering
        result.settleSeconds = CACurrentMediaTime() - begin
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

    @objc private func tick() {
        guard let result, let chat, chat.view.window != nil, let listLayer = chat.list.layer.presentation() else { return }
        let list = chat.list, time = elapsed
        result.frames += 1
        let inverted = list.contentView.transform.d < 0, insets = list.viewportInsets, height = Double(list.bounds.height)
        let band = inverted ? (insets.bottom, height - insets.top) : (insets.top, height - insets.bottom)
        for item in list.items where !known.contains(item.identity) {
            known.insert(item.identity); result.inserted.append(item.identity); firstSeen[item.identity] = time
            if item.identity.hasPrefix("stream-") { streamed.insert(item.identity) }
        }
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
            if let previous { check(previous, row, inverted: inverted, time: time, result: result) }
            previous = row
        }
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
            if let bar = Self.find(in: chat.view, UIView.self, { $0.accessibilityIdentifier == "composerBar" }) {
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
        if let data = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]),
           let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? data.write(to: directory.appendingPathComponent("list-stream-send-geometry.json"), options: .atomic)
        }
        if complete { print("LIST-STREAM-SEND \(report.accessibilityValue ?? "")") }
    }

    nonisolated fileprivate static func json(_ value: Double) -> Any { value.isFinite ? value : String(value) }

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
/// Rows whose resting height is fixed by their data rather than measured from content.
@MainActor
protocol ListProbeDeclaredHeight {
    var declaredHeight: Double { get }
}
extension DemoListRow: ListProbeDeclaredHeight {
    var declaredHeight: Double { height }
}
#endif
