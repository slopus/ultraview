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

    private init(chat: ListChatController) {
        self.chat = chat
        super.init()
    }

    private static let oneLine = "A reply during streaming"
    private static let sixLines = (1...6).map { "Composer timing line \($0)" }.joined(separator: "\n")

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

        // Keyboard up: the first presentation is the cold one.
        for run in 0..<min(runs, 4) {
            await measure(run == 0 ? "becomeFirstResponderCold" : "becomeFirstResponder", list: list) { _ = composer.becomeFirstResponder() }
            try? await Task.sleep(for: .milliseconds(900))
            if run + 1 < min(runs, 4) { composer.resignFirstResponder(); try? await Task.sleep(for: .milliseconds(900)) }
        }
        notes["keyboardVisible"] = chat.view.keyboardLayoutGuide.layoutFrame.height > chat.view.safeAreaInsets.bottom + 40
        for _ in 0..<runs { await edits(composer, suffix: "keyboardUp", width: width, list: list) }
        for _ in 0..<runs { await keyboardHandler(chat, list: list) }

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
