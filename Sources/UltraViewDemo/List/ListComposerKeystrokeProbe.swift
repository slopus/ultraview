#if canImport(UIKit)
import UIKit
import UltraView

@MainActor
final class ListComposerKeystrokeProbe: NSObject {
    private static var current: ListComposerKeystrokeProbe?
    static func startIfRequested(chat: ListChatController) {
        guard current == nil, UserDefaults.standard.bool(forKey: "listComposerKeystrokeProbe") else { return }
        let probe = ListComposerKeystrokeProbe(chat: chat); current = probe
        Task { await probe.run() }
    }

    private weak var lists: ListsScreenController?
    private weak var chat: ListChatController?
    private weak var text: UITextView?
    private weak var bar: UIView?
    private weak var row: ListRowView?
    private let report = UILabel()
    private var link: CADisplayLink?
    private var active = false, complete = false
    private var began = 0.0
    private var trace: [[String: Any]] = [], records: [[String: Any]] = []
    private var failure: String?

    private init(chat: ListChatController) {
        self.chat = chat; lists = chat.parent as? ListsScreenController
        super.init()
        report.frame = .init(x: 0, y: 0, width: 1, height: 1)
        report.text = " "; report.isAccessibilityElement = true
        report.accessibilityLabel = "Composer keystroke probe"; report.accessibilityIdentifier = "composerKeystroke"
    }

    private func run() async {
        try? await Task.sleep(for: .seconds(1))
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common); self.link = link
        for mode in ScrollEngineMode.allCases {
            guard let lists,
                  let engines = Self.find(UISegmentedControl.self, in: lists.view, { $0.accessibilityIdentifier == "listEngines" }),
                  let index = ScrollEngineMode.allCases.firstIndex(of: mode) else { failure = "missing engine control"; break }
            engines.selectedSegmentIndex = index; engines.sendActions(for: .valueChanged)
            let initialRow = UserDefaults.standard.integer(forKey: "listInitialRow")
            for _ in 0..<300 {
                if let next = lists.children.first as? ListChatController,
                   next.list.engineMode == mode, next.list.loadedItemView(at: initialRow)?.isDisplayReady == true { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard let next = lists.children.first as? ListChatController,
                  let text = Self.find(UITextView.self, in: next.view, { $0.accessibilityIdentifier == "composer" }),
                  let bar = Self.find(UIView.self, in: next.view, { $0.accessibilityIdentifier == "composerBar" }) else {
                failure = "missing composer"; break
            }
            chat = next; self.text = text; self.bar = bar; next.view.addSubview(report)
            _ = text.becomeFirstResponder()
            try? await Task.sleep(for: .milliseconds(800))
            text.text = "First line\nSecond line"; text.delegate?.textViewDidChange?(text)
            text.selectedRange = NSRange(location: text.text.utf16.count, length: 0)
            try? await Task.sleep(for: .milliseconds(400))
            row = next.list.loadedItemViews.min {
                abs($0.convert($0.bounds, to: next.view).maxY - bar.frame.minY)
                    < abs($1.convert($1.bounds, to: next.view).maxY - bar.frame.minY)
            }
            await measure("addLine", mode: mode) { text.insertText("\n") }
            await measure("removeLine", mode: mode) { text.deleteBackward() }
            await measure("addLetter", mode: mode) { text.insertText("a") }
            await measure("removeLetter", mode: mode) { text.deleteBackward() }
            let beforePaste = text.text.utf16.count
            await measure("addMultiline", mode: mode) { text.insertText("\nThird line\nFourth line") }
            await measure("removeMultiline", mode: mode) {
                text.selectedRange = NSRange(location: beforePaste, length: text.text.utf16.count - beforePaste)
                text.insertText("")
            }
            _ = text.resignFirstResponder()
            try? await Task.sleep(for: .milliseconds(500))
        }
        link.invalidate(); self.link = nil; complete = true; publish()
    }

    private func measure(_ phase: String, mode: ScrollEngineMode, change: () -> Void) async {
        trace.removeAll(keepingCapacity: true); began = CACurrentMediaTime(); active = true
        sample("before")
        change()
        sample("changed")
        try? await Task.sleep(for: .milliseconds(500))
        sample("end"); active = false
        records.append(["engine": mode.rawValue, "phase": phase,
                        "firstIndex": chat?.list.loadedIndexRange.lowerBound ?? -1, "trace": trace])
        publish()
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard active else { return }
        sample("display", displayTime: link.timestamp, targetTime: link.targetTimestamp)
    }

    private func sample(_ event: String, displayTime: Double = 0, targetTime: Double = 0) {
        guard let chat, let text, let bar, let row, row.superview != nil else { return }
        let owner = chat.view.layer.presentation() ?? chat.view.layer
        func rect(_ view: UIView) -> CGRect {
            let layer = view.layer.presentation() ?? view.layer
            return layer.convert(layer.bounds, to: owner)
        }
        let b = rect(bar), t = rect(text), r = rect(row)
        let textLayer = text.layer.presentation() ?? text.layer
        let nativeCaret = Self.find(UIView.self, in: chat.view.window ?? chat.view, {
            let name = String(describing: type(of: $0)).lowercased()
            return (name.contains("caret") || name.contains("cursor")) && $0.bounds.height > 5
        })
        let nativeRect = nativeCaret.map(rect)
        var glyphs: [CGRect] = []
        func inspectGlyphs(_ view: UIView) {
            if String(describing: type(of: view)).contains("LayoutFragment"), !view.isHidden,
               view.layer.presentation() != nil { glyphs.append(rect(view)) }
            for child in view.subviews { inspectGlyphs(child) }
        }
        inspectGlyphs(text)
        let caret = text.caretRect(for: text.selectedTextRange?.end ?? text.endOfDocument)
        let c = textLayer.convert(caret, to: owner)
        var entry: [String: Any] = ["event": event, "time": CACurrentMediaTime() - began,
            "displayTime": displayTime, "targetTime": targetTime,
            "row": r.maxY, "barTop": b.minY, "barBottom": b.maxY, "barHeight": b.height,
            "textTop": t.minY, "textBottom": t.maxY, "textHeight": t.height,
            "caretTop": c.minY, "caretBottom": c.maxY, "caretLeft": c.minX, "caretLocal": caret.minY,
            "textBoundsY": textLayer.bounds.minY, "contentOffset": text.contentOffset.y,
            "modelHeight": bar.bounds.height, "inset": chat.list.viewportInsets.top,
            "text": text.text ?? ""]
        if let nativeCaret, let nativeRect {
            entry["nativeCaretTop"] = nativeRect.minY; entry["nativeCaretBottom"] = nativeRect.maxY
            entry["nativeCaretClass"] = String(describing: type(of: nativeCaret))
            entry["nativeCaretAlpha"] = nativeCaret.alpha
        }
        if let first = glyphs.map(\.minY).min(), let last = glyphs.map(\.maxY).max() {
            entry["glyphTop"] = first; entry["glyphBottom"] = last
        }
        if event == "before" || event == "changed" {
            var tracks: [String: Any] = [:]
            for (name, layer) in [("bar", bar.layer), ("text", text.layer), ("viewport", chat.list.contentView.layer)] {
                for key in layer.animationKeys() ?? [] {
                    guard let raw = layer.animation(forKey: key) else { continue }
                    guard let animation = raw as? CAPropertyAnimation, animation.probeIsSupported else {
                        failure = "Unsupported animation \(type(of: raw)) at \(name)/\(key)"; continue
                    }
                    tracks[name + "/" + key] = ["begin": animation.beginTime, "duration": animation.duration,
                        "from": String(describing: animation.probeFromValue), "to": String(describing: animation.probeToValue),
                        "path": animation.keyPath ?? "", "samples": (animation as? CAKeyframeAnimation)?.values?.count ?? 0]
                }
            }
            entry["tracks"] = tracks
        }
        trace.append(entry)
    }

    private func publish() {
        var document: [String: Any] = ["complete": complete, "phases": records]
        if let failure { document["failure"] = failure }
        if let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]) {
            report.accessibilityValue = String(decoding: data, as: UTF8.self)
        }
        if let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let data = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("list-composer-keystroke.json"), options: .atomic)
        }
    }

    private static func find<T: UIView>(_ type: T.Type, in root: UIView, _ matches: (T) -> Bool) -> T? {
        if let value = root as? T, matches(value) { return value }
        for child in root.subviews { if let value = find(type, in: child, matches) { return value } }
        return nil
    }
}
#endif