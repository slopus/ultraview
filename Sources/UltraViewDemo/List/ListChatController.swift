#if canImport(UIKit)
import UIKit
import UltraView

@MainActor
final class ListChatController: UIViewController {
    let list: UltraListView
    private let composer = UITextField(), send = UIButton(type: .system), stream = UIButton(type: .system)
    private var rows: [DemoListRow] = []
    private var nextID = 100
    private var streaming: Task<Void, Never>?
    private let monitor = ListFrameMonitor(name: "chat")
    init(mode: ScrollEngineMode) { list = UltraListView(engineMode: mode); super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemGroupedBackground
        list.contentView.transform = .init(scaleX: 1, y: -1)
        list.accessibilityIdentifier = "chatList"
        rows = (0..<60).map { index -> DemoListRow in
            let title = index % 2 == 0 ? "You" : "Assistant"
            let body = index == 0 ? "Tap Stream to watch this reply grow while the conversation stays in place." : "Message \(60 - index). The list keeps only the nearby conversation loaded."
            let height: Double = 92 + Double(index % 3) * 24
            let tint: UIColor = index % 2 == 0 ? .systemIndigo : .systemTeal
            return DemoListRow(identity: "message-\(index)", title: title, body: body, height: height, tint: tint, inverted: true)
        }
        composer.placeholder = "Message"; composer.borderStyle = .roundedRect; composer.accessibilityIdentifier = "composer"
        send.setTitle("Send", for: .normal); send.addTarget(self, action: #selector(sendMessage), for: .touchUpInside)
        stream.setTitle("Stream", for: .normal); stream.addTarget(self, action: #selector(beginStreaming), for: .touchUpInside)
        let bar = UIStackView(arrangedSubviews: [composer, stream, send]); bar.spacing = 8
        for v in [list, bar] { v.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(v) }
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: view.topAnchor), list.leadingAnchor.constraint(equalTo: view.leadingAnchor), list.trailingAnchor.constraint(equalTo: view.trailingAnchor), list.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -8),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12), bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12), bar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8), bar.heightAnchor.constraint(equalToConstant: 44),
        ])
        list.applyChanges(items: rows)
        list.willBeginDragging = { [weak self] in self?.composer.resignFirstResponder() }
        monitor.start()
        if UserDefaults.standard.bool(forKey: "listProbe") {
            Task { [weak self] in
                let delay = UserDefaults.standard.double(forKey: "listProbeDelay")
                try? await Task.sleep(for: .seconds(delay > 0 ? delay : 2)); self?.beginStreaming()
                try? await Task.sleep(for: .seconds(1)); self?.list.beginMomentum(velocity: 3500)
                try? await Task.sleep(for: .seconds(7)); self?.monitor.finish()
            }
        }
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); streaming?.cancel(); monitor.finish() }
    @objc private func sendMessage() {
        nextID += 1
        rows.insert(.init(identity: "sent-\(nextID)", title: "You", body: composer.text?.isEmpty == false ? composer.text! : "A new message", height: 100, tint: .systemIndigo, inverted: true), at: 0)
        composer.text = ""
        list.applyChanges(items: rows, scrollTo: .init(index: 0), animatesInsertions: false, transition: .easeInOut(0.3))
        list.animateInsertedBlock(identities: [rows[0].identity], from: .top)
    }
    @objc private func beginStreaming() {
        streaming?.cancel()
        nextID += 1
        let id = "stream-\(nextID)"
        rows.insert(.init(identity: id, title: "Assistant · streaming", body: "A reply", height: 84, tint: .systemTeal, inverted: true), at: 0)
        list.applyChanges(items: rows, scrollTo: .init(index: 0), transition: .easeInOut(0.3))
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
final class ListFrameMonitor: NSObject {
    private var link: CADisplayLink?
    private var previous: Double?
    private var gaps: [Double] = []
    private let name: String
    init(name: String) { self.name = name }
    static func stallForProbe() { Thread.sleep(forTimeInterval: 0.12) }
    func start() {
        link?.invalidate(); gaps.removeAll(); previous = nil
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = .init(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common); self.link = link
    }
    @objc private func tick() {
        let time = CACurrentMediaTime()
        if let previous { gaps.append((time - previous) * 1000) }
        previous = time
    }
    func finish() {
        guard link != nil else { return }
        link?.invalidate(); link = nil
        let document: [String: Any] = ["screen": name, "samples": gaps.count, "maximumMainGapMilliseconds": gaps.max() ?? 0, "gapsAbove16_7": gaps.filter { $0 > 16.7 }.count, "missedFramesAbove25": gaps.filter { $0 > 25 }.count, "injectedStall": UserDefaults.standard.bool(forKey: "listStall")]
        if let data = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]), let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? data.write(to: url.appendingPathComponent("list-\(name)-timing.json"))
            print("LIST-TIMING \(String(data: data, encoding: .utf8) ?? "")")
        }
    }
}
#endif