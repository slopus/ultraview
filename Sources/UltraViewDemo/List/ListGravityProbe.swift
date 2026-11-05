#if canImport(UIKit)
import UIKit
import UIKit.UIGestureRecognizerSubclass
import QuartzCore
import UltraView

/// Measures the chat's bottom gravity against real touches, every display
/// frame, on the card rows (`-chatCards YES`):
///
///     -screen lists -listScreen chat -chatCards YES -listGravityProbe YES
///     -listGravityScenario hold|stream [-listInitialRow 25]
///
/// `hold`: while a finger is down, the probe changes the collection every
/// 120 ms around the row under it: rows above it grow, shrink and go,
/// older rows arrive at the top, the row itself and rows below it grow,
/// and the last row grows. Each frame compares the row's top on screen with
/// the finger; the gap must stay what it was at touch-down (strictly while
/// the finger rests, within a frame's travel while it moves).
///
/// `stream`: after Stream is tapped at the newest message, each frame
/// measures how far the message that was newest rose on screen. It must
/// never rise more than the follow budget, and it rests exactly that far up
/// once the reply grew past it, with the list no longer following.
///
/// The report is JSON in the accessibility value of `gravityProbe` and in
/// Documents/list-gravity-probe.json.
@MainActor
final class ListGravityProbe: NSObject, UIGestureRecognizerDelegate {
    private static var current: ListGravityProbe?

    static func startIfRequested(chat: ListChatController) {
        guard current == nil, UserDefaults.standard.bool(forKey: "listGravityProbe") else { return }
        let probe = ListGravityProbe(chat: chat)
        current = probe
        probe.start()
    }

    /// Reports a touch's phases and location without ever recognizing.
    private final class TouchWatcher: UIGestureRecognizer {
        var observe: ((UITouch.Phase, CGPoint) -> Void)?
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { report(touches, .began) }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { report(touches, .moved) }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { report(touches, .ended); state = .failed }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { report(touches, .cancelled); state = .failed }
        private func report(_ touches: Set<UITouch>, _ phase: UITouch.Phase) {
            guard let touch = touches.first, let view else { return }
            observe?(phase, touch.location(in: view))
        }
    }

    private weak var chat: ListChatController?
    private let scenario: String
    private let report = UILabel()
    private var link: CADisplayLink?
    private var document: [String: Any] = [:]
    private var complete = false

    // hold
    private var finger: CGPoint?
    private var lastMove = 0.0
    private var touched: String?
    private var gap0 = 0.0
    private var holdFrames = 0, dragFrames = 0, missingFrames = 0
    private var holdMax = 0.0, dragMax = 0.0
    private var dragStep = 0.0, previousFinger: Double?
    private var worst: [String: Any] = [:]
    private var mutations: [String] = []
    private var mutating: Task<Void, Never>?
    private var serial = 0

    // stream
    private var reference: String?
    private var reference0 = 0.0
    private var riseMax = 0.0
    private var streamID: String?
    private var streamFrames = 0
    private var trace: [[Double]] = []

    private init(chat: ListChatController) {
        self.chat = chat
        scenario = UserDefaults.standard.string(forKey: "listGravityScenario") ?? "hold"
        super.init()
    }

    private func start() {
        guard let chat else { return }
        report.frame = .init(x: 0, y: 0, width: 1, height: 1)
        report.text = " "; report.isAccessibilityElement = true
        report.accessibilityLabel = "Gravity probe"; report.accessibilityIdentifier = "gravityProbe"
        chat.view.addSubview(report)
        let watcher = TouchWatcher(target: nil, action: nil)
        watcher.cancelsTouchesInView = false; watcher.delaysTouchesEnded = false; watcher.delegate = self
        watcher.observe = { [weak self] phase, point in self?.touch(phase, point) }
        chat.view.addGestureRecognizer(watcher)
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common); self.link = link
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.publish(ready: true)
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    // MARK: Hold

    private func touch(_ phase: UITouch.Phase, _ point: CGPoint) {
        guard scenario == "hold", let chat, !complete else { return }
        switch phase {
        case .began:
            finger = point; lastMove = CACurrentMediaTime(); previousFinger = Double(point.y)
            guard let (identity, rect) = row(at: point, in: chat) else { return }
            touched = identity; gap0 = Double(rect.minY - point.y)
            mutating = Task { [weak self] in
                var step = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(120))
                    guard let self, !Task.isCancelled else { return }
                    mutate(step); step += 1
                }
            }
        case .moved:
            finger = point; lastMove = CACurrentMediaTime()
        default:
            mutating?.cancel(); mutating = nil
            finger = nil
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                self?.finish()
            }
        }
    }

    /// One change around the touched row, cycling through the cases.
    private func mutate(_ step: Int) {
        guard let chat, let touched else { return }
        var rows = chat.chaosRows
        guard let at = rows.firstIndex(where: { $0.identity == touched }) else { return }
        let transition: ListTransition = step % 2 == 0 ? .none : .easeInOut(0.2)
        var name: String
        func grow(_ index: Int, _ delta: Double) {
            guard rows.indices.contains(index) else { return }
            rows[index].height = max(40, rows[index].height + delta); rows[index].revision += 1
        }
        switch step % 7 {
        case 0: grow(at - 2, 40); name = "growAbove"
        case 1:
            serial += 1
            let older = (0..<2).map { DemoListRow(identity: "older-\(serial)-\($0)", title: "Older", body: "Older history.", height: 90) }
            rows.insert(contentsOf: older, at: 0); name = "prependOlder"
        case 2: grow(at, 30); name = "growTouched"
        case 3: grow(at + 2, 40); name = "growBelow"
        case 4:
            if at >= 3 { rows.remove(at: at - 3) }
            name = "deleteAbove"
        case 5: grow(at - 1, -20); name = "shrinkAbove"
        default: grow(rows.count - 1, 30); name = "growLast"
        }
        mutations.append(name)
        chat.chaosRows = rows
        chat.list.applyChanges(items: rows, transition: transition)
    }

    private func row(at point: CGPoint, in chat: ListChatController) -> (String, CGRect)? {
        let list = chat.list
        for index in list.loadedIndexRange {
            guard let rect = shown(index, in: chat), rect.minY <= point.y, point.y < rect.maxY else { continue }
            return (list.items[index].identity, rect)
        }
        return nil
    }

    /// A row's frame on screen, in the chat's coordinates.
    private func shown(_ index: Int, in chat: ListChatController) -> CGRect? {
        guard let view = chat.list.loadedItemView(at: index), let layer = view.layer.presentation(),
              let target = chat.view.layer.presentation() else { return nil }
        return layer.convert(layer.bounds, to: target)
    }

    private func sampleHold(_ chat: ListChatController) {
        guard let finger, let touched else { return }
        guard let index = chat.list.items.firstIndex(where: { $0.identity == touched }), let rect = shown(index, in: chat) else {
            missingFrames += 1; return
        }
        let error = abs(Double(rect.minY - finger.y) - gap0)
        let resting = CACurrentMediaTime() - lastMove > 0.05
        if resting {
            holdFrames += 1
            if error > holdMax { holdMax = error; worst = ["error": error, "row": touched, "mutations": mutations.suffix(3).joined(separator: ","), "resting": true] }
        } else {
            dragFrames += 1; dragMax = max(dragMax, error)
            if let previousFinger { dragStep = max(dragStep, abs(Double(finger.y) - previousFinger)) }
        }
        previousFinger = Double(finger.y)
    }

    // MARK: Stream

    private func sampleStream(_ chat: ListChatController) {
        let list = chat.list
        if streamID == nil, let id = list.items.last?.identity, id.hasPrefix("stream-") {
            streamID = id
            guard list.items.count >= 2 else { return }
            reference = list.items[list.items.count - 2].identity
        }
        guard let reference, let index = list.items.firstIndex(where: { $0.identity == reference }), let rect = shown(index, in: chat) else { return }
        if streamFrames == 0 { reference0 = Double(rect.minY) }
        streamFrames += 1
        let rise = reference0 - Double(rect.minY)
        riseMax = max(riseMax, rise)
        if trace.count < 400 { trace.append([CACurrentMediaTime(), rise]) }
        if let streamID, let item = list.items.last(where: { $0.identity == streamID }), item.revision >= 40, !complete, finishing == nil {
            finishing = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                self?.finish()
            }
        }
    }
    private var finishing: Task<Void, Never>?

    // MARK: Report

    @objc private func tick() {
        guard let chat, !complete else { return }
        if scenario == "hold" { sampleHold(chat) } else { sampleStream(chat) }
    }

    private func finish() {
        guard let chat, !complete else { return }
        let list = chat.list
        document["engine"] = list.engineMode.rawValue
        document["budget"] = list.bottomGravity?.followBudget ?? -1
        document["following"] = list.isFollowingBottom
        document["distanceFromBottom"] = list.distanceFromBottom ?? -1
        if scenario == "hold" {
            document["touched"] = touched ?? ""
            document["holdFrames"] = holdFrames; document["dragFrames"] = dragFrames; document["missingFrames"] = missingFrames
            document["holdMaxError"] = holdMax; document["dragMaxError"] = dragMax; document["dragMaxStep"] = dragStep
            document["worst"] = worst; document["mutations"] = mutations
        } else {
            var settledRise = -1.0
            if let reference, let index = list.items.firstIndex(where: { $0.identity == reference }), let rect = shown(index, in: chat) {
                settledRise = reference0 - Double(rect.minY)
            }
            document["streamFrames"] = streamFrames; document["riseMax"] = riseMax; document["finalRise"] = settledRise
            document["trace"] = stride(from: 0, to: trace.count, by: max(1, trace.count / 40)).map { trace[$0] }
        }
        complete = true
        link?.invalidate(); link = nil
        publish(ready: true)
    }

    private func publish(ready: Bool) {
        var value = document
        value["scenario"] = scenario; value["ready"] = ready; value["complete"] = complete
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        report.accessibilityValue = String(decoding: data, as: UTF8.self)
        if let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? data.write(to: directory.appendingPathComponent("list-gravity-probe.json"), options: .atomic)
        }
        if complete { print("LIST-GRAVITY \(report.accessibilityValue ?? "")") }
    }
}
#endif
