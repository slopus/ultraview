#if canImport(UIKit)
import UIKit
import UltraView

/// Measures one surviving row against the composer through programmatic input
/// changes while the conversation starts away from its newest edge.
@MainActor
final class ListComposerMotionProbe: NSObject {
    private static var current: ListComposerMotionProbe?
    static func startIfRequested(chat: ListChatController) {
        guard current == nil, UserDefaults.standard.bool(forKey: "listComposerMotionProbe") else { return }
        let probe = ListComposerMotionProbe(chat: chat); current = probe
        Task { await probe.run() }
    }

    private weak var lists: ListsScreenController?
    private weak var chat: ListChatController?
    private weak var row: ListRowView?
    private weak var bar: UIView?
    private let report = UILabel()
    private var link: CADisplayLink?
    private var records: [[String: Any]] = []
    private var nextDrafts: [[String: Any]] = []
    private var active: Motion?
    private var complete = false
    private var failure: String?

    private final class Motion {
        let engine: String, phase: String
        let start: Double, row: Double, bar: Double, inset: Double
        var samples = 0, nonFinite = 0
        var maximum = 0.0, rowDelta = 0.0, barDelta = 0.0
        var trace: [[Double]] = []
        init(engine: String, phase: String, row: Double, bar: Double, inset: Double) {
            self.engine = engine; self.phase = phase; self.row = row; self.bar = bar; self.inset = inset
            start = CACurrentMediaTime()
        }
    }

    private init(chat: ListChatController) {
        self.chat = chat; lists = chat.parent as? ListsScreenController
        super.init()
        report.frame = .init(x: 0, y: 0, width: 1, height: 1)
        report.text = " "; report.isAccessibilityElement = true
        report.accessibilityLabel = "Composer motion probe"; report.accessibilityIdentifier = "composerMotion"
    }

    private func run() async {
        try? await Task.sleep(for: .seconds(1))
        let link = CADisplayLink(target: self, selector: #selector(sample))
        link.add(to: .main, forMode: .common); self.link = link
        for mode in ScrollEngineMode.allCases {
            guard let lists,
                  let engines = Self.find(UISegmentedControl.self, in: lists.view, { $0.accessibilityIdentifier == "listEngines" }),
                  let index = ScrollEngineMode.allCases.firstIndex(of: mode) else { failure = "missing engine control"; break }
            engines.selectedSegmentIndex = index; engines.sendActions(for: .valueChanged)
            let loaded = await wait(6) { [weak lists] in
                guard let next = lists?.children.first as? ListChatController else { return false }
                return next.list.engineMode == mode && next.list.loadedIndexRange.contains(25)
                    && next.list.loadedItemViews.allSatisfy(\.isDisplayReady)
            }
            guard loaded, let next = lists.children.first as? ListChatController,
                  let composer = Self.find(UITextView.self, in: next.view, { $0.accessibilityIdentifier == "composer" }),
                  let bar = Self.find(UIView.self, in: next.view, { $0.accessibilityIdentifier == "composerBar" }) else {
                failure = "\(mode): conversation not ready at row 25"; break
            }
            chat = next; self.bar = bar; next.view.addSubview(report)
            try? await Task.sleep(for: .milliseconds(400))
            row = next.list.loadedItemViews.filter { $0.frame.height > 0 }.min { a, b in
                abs(a.convert(a.bounds, to: next.view).maxY - bar.frame.minY)
                    < abs(b.convert(b.bounds, to: next.view).maxY - bar.frame.minY)
            }
            publish()
            await measure("keyboardShow", mode: mode, seconds: 1) { _ = composer.becomeFirstResponder() }
            for lines in 2...5 {
                await measure("grow\(lines)", mode: mode, seconds: 0.45) {
                    composer.text = (1...lines).map { "Draft line \($0)" }.joined(separator: "\n")
                    composer.delegate?.textViewDidChange?(composer)
                }
            }
            await measure("shrink", mode: mode, seconds: 0.45) {
                composer.text = ""; composer.delegate?.textViewDidChange?(composer)
            }
            await measure("keyboardHide", mode: mode, seconds: 1) { _ = composer.resignFirstResponder() }
            await typeDuringSend(composer, bar: bar, chat: next, mode: mode)
        }
        link.invalidate(); self.link = nil; complete = true; publish()
    }

    private func typeDuringSend(_ composer: UITextView, bar: UIView, chat: ListChatController, mode: ScrollEngineMode) async {
        guard let send = Self.find(UIButton.self, in: chat.view, { $0.currentTitle == "Send" }) else { failure = "missing Send"; return }
        _ = composer.becomeFirstResponder()
        try? await Task.sleep(for: .milliseconds(700))
        composer.text = "Sent line one\nSent line two"; composer.delegate?.textViewDidChange?(composer)
        try? await Task.sleep(for: .milliseconds(300))
        let oldHeight = bar.bounds.height, count = chat.list.items.count
        send.sendActions(for: .touchUpInside)
        let pending = chat.list.items.count == count
        composer.text = (1...5).map { "Next draft line \($0)" }.joined(separator: "\n")
        composer.delegate?.textViewDidChange?(composer)
        let immediate = bar.bounds.height
        try? await Task.sleep(for: .milliseconds(700))
        nextDrafts.append(["engine": mode.rawValue, "sendStillPreparing": pending,
                           "oldHeight": oldHeight, "immediateHeight": immediate, "finalHeight": bar.bounds.height,
                           "newDraftRetained": composer.text.hasPrefix("Next draft line 1")])
        _ = composer.resignFirstResponder()
        try? await Task.sleep(for: .milliseconds(400))
        publish()
    }

    private func measure(_ phase: String, mode: ScrollEngineMode, seconds: Double, action: () -> Void) async {
        guard let chat, let value = positions() else { failure = "\(mode)/\(phase): missing witness"; return }
        let motion = Motion(engine: mode.rawValue, phase: phase, row: value.row, bar: value.bar, inset: chat.list.viewportInsets.top)
        active = motion; action()
        try? await Task.sleep(for: .seconds(seconds))
        sample(); active = nil
        records.append(["engine": motion.engine, "phase": motion.phase, "samples": motion.samples,
                        "nonFinite": motion.nonFinite, "maxRelativeGap": motion.maximum,
                        "rowDelta": motion.rowDelta, "composerDelta": motion.barDelta,
                        "insetDelta": chat.list.viewportInsets.top - motion.inset,
                        "firstIndex": chat.list.loadedIndexRange.lowerBound, "trace": motion.trace])
        publish()
    }

    private func positions() -> (row: Double, bar: Double)? {
        guard let owner = chat?.view, let row, let bar, row.superview != nil,
              let rowLayer = row.layer.presentation(), let barLayer = bar.layer.presentation() else { return nil }
        let destination = owner.layer.presentation() ?? owner.layer
        return (Double(rowLayer.convert(rowLayer.bounds, to: destination).maxY),
                Double(barLayer.convert(barLayer.bounds, to: destination).minY))
    }

    @objc private func sample() {
        guard let motion = active else { return }
        guard let value = positions(), value.row.isFinite, value.bar.isFinite else { motion.nonFinite += 1; return }
        motion.samples += 1
        motion.rowDelta = value.row - motion.row; motion.barDelta = value.bar - motion.bar
        let gap = motion.rowDelta - motion.barDelta
        motion.maximum = max(motion.maximum, abs(gap))
        if motion.trace.count < 160 { motion.trace.append([CACurrentMediaTime() - motion.start, motion.rowDelta, motion.barDelta, gap]) }
    }

    private func publish() {
        var document: [String: Any] = ["complete": complete, "phases": records, "nextDrafts": nextDrafts]
        if let failure { document["failure"] = failure }
        if let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]) {
            report.accessibilityValue = String(decoding: data, as: UTF8.self)
        }
        if let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let data = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("list-composer-motion.json"), options: .atomic)
        }
    }

    private func wait(_ seconds: Double, condition: () -> Bool) async -> Bool {
        let deadline = CACurrentMediaTime() + seconds
        while CACurrentMediaTime() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private static func find<T: UIView>(_ type: T.Type, in root: UIView, _ matches: (T) -> Bool) -> T? {
        if let value = root as? T, matches(value) { return value }
        for child in root.subviews { if let value = find(type, in: child, matches) { return value } }
        return nil
    }
}
#endif