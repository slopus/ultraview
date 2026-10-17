#if canImport(UIKit)
import UIKit
import UltraView

/// Splits the main-thread cost of composer edits into text assignment, text
/// measurement, layout and the list's inset pass:
///
///     -screen lists -listScreen chat -listComposerTiming YES [-listComposerTimingRuns 8]
///
/// Each step runs the real controller code through public seams: the text
/// view's delegate, the Send button and a keyboard frame notification. The
/// same text edits also run with the keyboard down, which isolates the input
/// system's share. `turn` adds the rest of the run-loop turn, including the
/// Core Animation commit. The report is JSON in the accessibility value of
/// `composerTiming` and in Documents/list-composer-timing.json.
/// Clear alternatives also compare undo, marked text and the next typed text,
/// including busy time over the following 300 ms. Send keeps its text setter.
/// Pass `-listComposerTimingClear NO` to skip those comparisons.
@MainActor
final class ListComposerTimingProbe: NSObject {
    private static var current: ListComposerTimingProbe?

    static func startIfRequested(chat: ListChatController) {
        guard current == nil, UserDefaults.standard.bool(forKey: "listComposerTiming") else { return }
        let probe = ListComposerTimingProbe(chat: chat)
        current = probe
        Task { await probe.run() }
    }

    private weak var chat: ListChatController?
    private let report = UILabel()
    private var samples: [String: [Double]] = [:]
    private var passes: [String: [Double]] = [:]
    private var notes: [String: Any] = [:]
    private var complete = false
    private var textChanges = 0

    private init(chat: ListChatController) {
        self.chat = chat
        super.init()
    }

    private static let oneLine = "A reply during streaming"
    private static let sixLines = (1...6).map { "Composer timing line \($0)" }.joined(separator: "\n")

    private enum Clear: String, CaseIterable {
        case textSetter, replaceRange, storageDelete
        @MainActor func apply(to composer: UITextView) {
            switch self {
            case .textSetter:
                composer.text = ""
            case .replaceRange:
                guard let all = composer.textRange(from: composer.beginningOfDocument, to: composer.endOfDocument) else { return }
                composer.replace(all, withText: "")
            case .storageDelete:
                let typing = composer.typingAttributes, storage = composer.textStorage
                storage.beginEditing()
                storage.deleteCharacters(in: NSRange(location: 0, length: storage.length))
                storage.endEditing()
                composer.typingAttributes = typing
                composer.selectedRange = NSRange(location: 0, length: 0)
            }
        }
    }
    private enum Draft: String, CaseIterable { case plain, typed, marked }

    // MARK: Run

    private func run() async {
        try? await Task.sleep(for: .seconds(1.5))
        guard let chat, let composer = find(UITextView.self, in: chat.view, { $0.accessibilityIdentifier == "composer" }),
              let send = find(UIButton.self, in: chat.view, { $0.currentTitle == "Send" }) else {
            notes["failure"] = "composer or Send not found"; publish(); return
        }
        report.frame = .init(x: 0, y: 0, width: 1, height: 1)
        report.text = " "; report.accessibilityLabel = "Composer timing probe"
        report.accessibilityIdentifier = "composerTiming"; report.isAccessibilityElement = true
        chat.view.addSubview(report)
        publish()
        let runs = max(1, UserDefaults.standard.object(forKey: "listComposerTimingRuns") == nil ? 8 : UserDefaults.standard.integer(forKey: "listComposerTimingRuns"))
        let list = chat.list
        let width = composer.bounds.width

        // Keyboard down: text edits without the input system.
        for _ in 0..<runs { await edits(composer, suffix: "keyboardDown", width: width, list: list) }
        await measure("layoutBaseline", list: list) { chat.view.setNeedsLayout(); chat.view.layoutIfNeeded() }
        for _ in 0..<runs {
            let insets = list.viewportInsets
            var raised = insets; raised.top += 40
            await measure("insetPass", list: list) { list.applyChanges(newInsets: raised, transition: .easeInOut(0.18)) }
            try? await Task.sleep(for: .milliseconds(250))
            await measure("insetPass", list: list) { list.applyChanges(newInsets: insets, transition: .easeInOut(0.18)) }
            try? await Task.sleep(for: .milliseconds(250))
        }

        let clears = UserDefaults.standard.object(forKey: "listComposerTimingClear") == nil || UserDefaults.standard.bool(forKey: "listComposerTimingClear")
        if clears { for run in 0..<runs { await clearTimings(composer, suffix: "keyboardDown", run: run, list: list) } }

        // Keyboard up: the first presentation is the cold one.
        for run in 0..<min(runs, 4) {
            await measure(run == 0 ? "becomeFirstResponderCold" : "becomeFirstResponder", list: list) { _ = composer.becomeFirstResponder() }
            try? await Task.sleep(for: .milliseconds(900))
            if run + 1 < min(runs, 4) { composer.resignFirstResponder(); try? await Task.sleep(for: .milliseconds(900)) }
        }
        notes["keyboardVisible"] = chat.view.keyboardLayoutGuide.layoutFrame.height > chat.view.safeAreaInsets.bottom + 40
        for _ in 0..<runs { await edits(composer, suffix: "keyboardUp", width: width, list: list) }
        for _ in 0..<runs { await keyboardHandler(chat, list: list) }
        if clears {
            for run in 0..<runs { await clearTimings(composer, suffix: "keyboardUp", run: run, list: list) }
            for run in 0..<runs { await clearTimings(composer, suffix: "keyboardUpTyped", run: run, list: list) }
            await clearEquivalence(composer)
            summarizeClears()
        }

        // The real Send with a six-line draft, after the composer has grown.
        for _ in 0..<runs {
            composer.text = Self.sixLines; composer.delegate?.textViewDidChange?(composer)
            try? await Task.sleep(for: .milliseconds(500))
            await measure("sendSixLines", list: list) { send.sendActions(for: .touchUpInside) }
            try? await Task.sleep(for: .milliseconds(700))
        }
        composer.resignFirstResponder()
        complete = true
        publish()
    }

    /// One fill, grow and clear, each split into assignment, measurement and the delegate path.
    private func edits(_ composer: UITextView, suffix: String, width: CGFloat, list: UltraListView) async {
        let fit = CGSize(width: width, height: .greatestFiniteMagnitude)
        for (name, text) in [("fill", Self.oneLine), ("grow", Self.sixLines), ("clear", "")] {
            await measure("\(name)TextSet.\(suffix)", list: list) { composer.text = text }
            await measure("\(name)SizeThatFits.\(suffix)", list: list) { _ = composer.sizeThatFits(fit) }
            // updateComposerHeight(animated: true): measures again, then lays out the view
            // inside an animation, which runs viewDidLayoutSubviews and the inset pass.
            await measure("\(name)Delegate.\(suffix)", list: list) { composer.delegate?.textViewDidChange?(composer) }
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    private func clearTimings(_ composer: UITextView, suffix: String, run: Int, list: UltraListView) async {
        let variants = Clear.allCases, count = variants.count
        for offset in 0..<count {
            let variant = variants[(offset + run) % count]
            composer.text = Self.sixLines; composer.delegate?.textViewDidChange?(composer)
            if suffix.hasSuffix("Typed") {
                composer.selectedRange = NSRange(location: (composer.text as NSString).length, length: 0)
                composer.insertText(" and typed")
            }
            try? await Task.sleep(for: .milliseconds(450))
            let name = "clear.\(variant.rawValue).\(suffix)", before = list.appliedPassCount
            let start = CACurrentMediaTime()
            variant.apply(to: composer)
            let cleared = CACurrentMediaTime()
            composer.delegate?.textViewDidChange?(composer)
            let end = CACurrentMediaTime()
            let turnEnd = await Self.nextBeforeWaiting()
            let busy = await Self.busy(for: 0.3)
            samples[name, default: []].append((cleared - start) * 1000)
            samples["clearThenDelegate.\(variant.rawValue).\(suffix)", default: []].append((end - start) * 1000)
            samples["clearThenDelegate.\(variant.rawValue).\(suffix)+turn", default: []].append((turnEnd - start) * 1000)
            samples["clearFollowingBusy.\(variant.rawValue).\(suffix)", default: []].append(busy.total * 1000)
            samples["clearFollowingMaxTurn.\(variant.rawValue).\(suffix)", default: []].append(busy.maximum * 1000)
            passes[name, default: []].append(Double(list.appliedPassCount &- before))
            composer.undoManager?.removeAllActions()
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    private func clearEquivalence(_ composer: UITextView) async {
        var report: [String: Any] = [:]
        for draft in Draft.allCases {
            var states: [String: [String: Any]] = [:]
            for variant in Clear.allCases { states[variant.rawValue] = await clearState(composer, draft: draft, variant: variant) }
            var entry: [String: Any] = states
            let baseline = states[Clear.textSetter.rawValue] ?? [:]
            var differences: [String: [String]] = [:]
            for variant in Clear.allCases where variant != .textSetter {
                differences[variant.rawValue] = Self.differences(baseline, states[variant.rawValue] ?? [:])
            }
            entry["differences"] = differences
            report[draft.rawValue] = entry
        }
        notes["clearEquivalence"] = report
        notes["clearUnproven"] = [
            "autocorrection and prediction state inside the keyboard process",
            "notifications to the keyboard's input delegate (it belongs to the system)",
            "a live input-method composition: marked text here is set through UITextInput, not by a CJK keyboard",
            "an active dictation session",
            "hardware keyboard and VoiceOver focus",
        ]
    }

    private func clearState(_ composer: UITextView, draft: Draft, variant: Clear) async -> [String: Any] {
        composer.text = ""; composer.delegate?.textViewDidChange?(composer)
        composer.undoManager?.removeAllActions()
        try? await Task.sleep(for: .milliseconds(300))
        var state: [String: Any] = ["firstResponder": composer.isFirstResponder]
        composer.text = Self.sixLines; composer.delegate?.textViewDidChange?(composer)
        let end = (composer.text as NSString).length
        composer.selectedRange = NSRange(location: end, length: 0)
        switch draft {
        case .plain: break
        case .typed: composer.insertText(" and typed")
        case .marked: composer.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))
        }
        try? await Task.sleep(for: .milliseconds(450))
        state["before"] = snapshot(composer)
        textChanges = 0
        NotificationCenter.default.addObserver(self, selector: #selector(textDidChange), name: UITextView.textDidChangeNotification, object: composer)
        defer { NotificationCenter.default.removeObserver(self, name: UITextView.textDidChangeNotification, object: composer) }
        variant.apply(to: composer)
        state["changeNotificationsFromClear"] = textChanges
        composer.delegate?.textViewDidChange?(composer)
        state["cleared"] = snapshot(composer)
        try? await Task.sleep(for: .milliseconds(400))
        state["rested"] = snapshot(composer)
        composer.insertText("Next")
        try? await Task.sleep(for: .milliseconds(150))
        state["typed"] = snapshot(composer)
        state["changeNotificationsThroughTyping"] = textChanges
        var undone: [String] = []
        for _ in 0..<3 {
            guard let undo = composer.undoManager, undo.canUndo else { break }
            undo.undo()
            undone.append(String((composer.text ?? "").prefix(32)))
        }
        state["undoTexts"] = undone
        composer.text = ""; composer.delegate?.textViewDidChange?(composer)
        composer.undoManager?.removeAllActions()
        try? await Task.sleep(for: .milliseconds(300))
        return state
    }

    @objc private func textDidChange() { textChanges += 1 }

    private func snapshot(_ composer: UITextView) -> [String: Any] {
        let traits = composer.traitCollection
        func font(_ value: Any?) -> String { (value as? UIFont).map { "\($0.fontName) \($0.pointSize)" } ?? "none" }
        func color(_ value: Any?) -> String {
            guard let color = (value as? UIColor)?.resolvedColor(with: traits) else { return "none" }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return String(format: "%.3f %.3f %.3f %.3f", r, g, b, a)
        }
        let text = composer.attributedText ?? NSAttributedString()
        let placeholder = composer.subviews.compactMap { $0 as? UILabel }.first { $0.text == "Message" }
        var value: [String: Any] = [
            "text": String((composer.text ?? "").prefix(32)), "length": text.length,
            "selected": NSStringFromRange(composer.selectedRange), "marked": composer.markedTextRange != nil,
            "font": font(composer.font), "textColor": color(composer.textColor),
            "typingFont": font(composer.typingAttributes[.font]), "typingColor": color(composer.typingAttributes[.foregroundColor]),
            "canUndo": composer.undoManager?.canUndo ?? false, "canRedo": composer.undoManager?.canRedo ?? false,
            "height": Double(composer.bounds.height), "scrolls": composer.isScrollEnabled, "offsetY": Double(composer.contentOffset.y),
            "placeholderVisible": placeholder.map { !$0.isHidden } ?? "missing",
        ]
        if text.length > 0 {
            value["fontAt0"] = font(text.attribute(.font, at: 0, effectiveRange: nil))
            value["colorAt0"] = color(text.attribute(.foregroundColor, at: 0, effectiveRange: nil))
        }
        return value
    }

    private static func differences(_ baseline: [String: Any], _ other: [String: Any]) -> [String] {
        var result: [String] = []
        for key in ["changeNotificationsFromClear", "changeNotificationsThroughTyping", "undoTexts"] {
            let a = "\(baseline[key] ?? "nil")", b = "\(other[key] ?? "nil")"
            if a != b { result.append("\(key): \(b) vs \(a)") }
        }
        for step in ["cleared", "rested", "typed"] {
            let a = baseline[step] as? [String: Any] ?? [:], b = other[step] as? [String: Any] ?? [:]
            for key in Set(a.keys).union(b.keys).sorted() {
                let x = "\(a[key] ?? "nil")", y = "\(b[key] ?? "nil")"
                if x != y { result.append("\(step).\(key): \(y) vs \(x)") }
            }
        }
        return result
    }

    private func summarizeClears() {
        func median(_ name: String) -> Double? {
            guard let values = samples[name], !values.isEmpty else { return nil }
            return values.sorted()[values.count / 2]
        }
        let equivalence = notes["clearEquivalence"] as? [String: Any] ?? [:]
        var summary: [String: Any] = [:]
        for variant in Clear.allCases where variant != .textSetter {
            var entry: [String: Any] = [:]
            for suffix in ["keyboardDown", "keyboardUp", "keyboardUpTyped"] {
                for (metric, turn) in [("clear", ""), ("clearThenDelegate", ""), ("clearThenDelegate", "+turn"), ("clearFollowingBusy", "")] {
                    let base = median("\(metric).\(Clear.textSetter.rawValue).\(suffix)\(turn)"), other = median("\(metric).\(variant.rawValue).\(suffix)\(turn)")
                    if let base, let other { entry["\(metric)\(turn).\(suffix)"] = base - other }
                }
            }
            let differences = Draft.allCases.reduce(0) { count, draft in
                count + (((equivalence[draft.rawValue] as? [String: Any])?["differences"] as? [String: [String]])?[variant.rawValue]?.count ?? 0)
            }
            entry["observedDifferences"] = differences
            let saved = ["keyboardUp", "keyboardUpTyped"].map { suffix -> Double in
                let turn = entry["clearThenDelegate+turn.\(suffix)"] as? Double ?? 0
                return min(turn, turn + (entry["clearFollowingBusy.\(suffix)"] as? Double ?? 0))
            }.min() ?? 0
            entry["savedMillisecondsKeyboardUp"] = saved
            entry["meetsMeasuredBar"] = saved > 3 && differences == 0
            summary[variant.rawValue] = entry
        }
        notes["clearSavingsVsSetter"] = summary
    }

    /// The controller's keyboard handler for an unchanged frame and for a frame 60 pt higher.
    private func keyboardHandler(_ chat: ListChatController, list: UltraListView) async {
        let frame = chat.view.convert(chat.view.keyboardLayoutGuide.layoutFrame, to: nil)
        func post(_ end: CGRect) {
            NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil, userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: end),
                UIResponder.keyboardAnimationDurationUserInfoKey: 0.25,
                UIResponder.keyboardAnimationCurveUserInfoKey: UInt(7),
            ])
        }
        await measure("keyboardHandlerSameFrame", list: list) { post(frame) }
        try? await Task.sleep(for: .milliseconds(400))
        await measure("keyboardHandlerShift", list: list) { post(frame.offsetBy(dx: 0, dy: -60)) }
        try? await Task.sleep(for: .milliseconds(400))
        await measure("keyboardHandlerRestore", list: list) { post(frame) }
        try? await Task.sleep(for: .milliseconds(400))
    }

    // MARK: Measurement

    /// Records the synchronous cost and, as `<name>+turn`, the cost through the end of the run-loop turn.
    private func measure(_ name: String, list: UltraListView, _ action: () -> Void) async {
        let before = list.appliedPassCount
        let start = CACurrentMediaTime()
        action()
        let end = CACurrentMediaTime()
        let turnEnd = await Self.nextBeforeWaiting()
        samples[name, default: []].append((end - start) * 1000)
        samples[name + "+turn", default: []].append((turnEnd - start) * 1000)
        passes[name, default: []].append(Double(list.appliedPassCount &- before))
    }

    /// Fires after Core Animation's own before-waiting commit observer.
    private static func nextBeforeWaiting() async -> Double {
        await withCheckedContinuation { (continuation: CheckedContinuation<Double, Never>) in
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max) { _, _ in
                continuation.resume(returning: CACurrentMediaTime())
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
    }

    private static func busy(for seconds: Double) async -> (total: Double, maximum: Double) {
        final class Turns { var began: Double?; var total = 0.0; var maximum = 0.0 }
        let turns = Turns()
        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { _, _ in
            turns.began = CACurrentMediaTime()
        }
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in
            guard let began = turns.began else { return }
            let length = CACurrentMediaTime() - began
            turns.total += length; turns.maximum = max(turns.maximum, length); turns.began = nil
        }
        let loop = CFRunLoopGetMain()
        CFRunLoopAddObserver(loop, wake, .commonModes); CFRunLoopAddObserver(loop, sleep, .commonModes)
        try? await Task.sleep(for: .seconds(seconds))
        for observer in [wake, sleep] { CFRunLoopRemoveObserver(loop, observer, .commonModes); CFRunLoopObserverInvalidate(observer) }
        return (turns.total, turns.maximum)
    }

    // MARK: Report

    private func publish() {
        func statistics(_ values: [Double]) -> [String: Any] {
            let sorted = values.sorted()
            return ["count": values.count, "first": values.first ?? 0, "median": sorted.isEmpty ? 0 : sorted[sorted.count / 2],
                    "max": sorted.last ?? 0, "warmMedian": values.count > 1 ? Array(values.dropFirst()).sorted()[(values.count - 1) / 2] : (values.first ?? 0)]
        }
        var document: [String: Any] = ["complete": complete, "milliseconds": samples.mapValues(statistics),
                                       "listPasses": passes.mapValues { $0.reduce(0, +) / Double(max(1, $0.count)) }]
        document.merge(notes) { _, new in new }
        if let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]) {
            let text = String(decoding: data, as: UTF8.self)
            report.accessibilityValue = text
            if let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                try? data.write(to: directory.appendingPathComponent("list-composer-timing.json"), options: .atomic)
            }
            if complete { print("LIST-COMPOSER-TIMING \(text)") }
        }
    }

    private func find<T: UIView>(_ type: T.Type, in root: UIView, _ matches: (T) -> Bool) -> T? {
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
