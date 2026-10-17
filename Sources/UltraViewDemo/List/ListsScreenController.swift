#if canImport(UIKit)
import UIKit
import UltraView

@MainActor
final class ListsScreenController: UIViewController {
    private let tabs = UISegmentedControl(items: ["Chat", "10k feed", "Compare", "Record"])
    private let engines = UISegmentedControl(items: ["UIKit", "Stepped", "Keyframe"])
    private let blocker = UISegmentedControl(items: ["Main off", "50 ms", "100 ms", "250 ms"])
    private var blocking: Task<Void, Never>?
    private var child: UIViewController?
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        tabs.accessibilityIdentifier = "listScreens"; engines.accessibilityIdentifier = "listEngines"
        let screen = UserDefaults.standard.string(forKey: "listScreen") ?? "feed"
        tabs.selectedSegmentIndex = ["chat", "feed", "compare", "record"].firstIndex(of: screen) ?? 1
        let initialEngine = UserDefaults.standard.string(forKey: "listEngine") ?? "keyframe"
        engines.selectedSegmentIndex = ScrollEngineMode.allCases.firstIndex(where: { $0.rawValue == initialEngine }) ?? 2
        tabs.addTarget(self, action: #selector(showScreen), for: .valueChanged)
        engines.addTarget(self, action: #selector(showScreen), for: .valueChanged)
        blocker.accessibilityIdentifier = "listMainBlocker"; blocker.selectedSegmentIndex = 0
        blocker.addTarget(self, action: #selector(updateBlocker), for: .valueChanged)
        for control in [tabs, engines, blocker] { control.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(control) }
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            tabs.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), tabs.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            engines.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 8), engines.leadingAnchor.constraint(equalTo: tabs.leadingAnchor), engines.trailingAnchor.constraint(equalTo: tabs.trailingAnchor),
            blocker.topAnchor.constraint(equalTo: engines.bottomAnchor, constant: 8), blocker.leadingAnchor.constraint(equalTo: tabs.leadingAnchor), blocker.trailingAnchor.constraint(equalTo: tabs.trailingAnchor),
        ])
        showScreen()
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); updateBlocker() }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); blocking?.cancel(); blocking = nil }
    @objc private func updateBlocker() {
        blocking?.cancel(); blocking = nil
        let milliseconds = [0, 50, 100, 250][max(0, blocker.selectedSegmentIndex)]
        guard milliseconds > 0 else { return }
        blocking = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                // Deliberate, user-selected main-thread stall for visual comparison.
                ListFrameMonitor.stallForProbe(milliseconds: milliseconds)
            }
        }
    }
    @objc private func showScreen() {
        child?.willMove(toParent: nil); child?.view.removeFromSuperview(); child?.removeFromParent()
        let mode = ScrollEngineMode.allCases[max(0, engines.selectedSegmentIndex)]
        let next: UIViewController
        switch tabs.selectedSegmentIndex {
        case 0: next = ListChatController(mode: mode)
        case 2: next = ListComparisonController()
        case 3: next = GestureRecorderController()
        default: next = LargeListController(mode: mode)
        }
        addChild(next); next.view.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(next.view)
        NSLayoutConstraint.activate([
            next.view.topAnchor.constraint(equalTo: blocker.bottomAnchor, constant: 8), next.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            next.view.trailingAnchor.constraint(equalTo: view.trailingAnchor), next.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
        next.didMove(toParent: self); child = next
    }
}

@MainActor
struct DemoListRow: ListRow {
    let identity: String
    var revision: UInt64 = 0
    var title: String
    var body: String
    var height: Double
    var tint: UIColor = .systemIndigo
    var inverted = false
    var pinsToBottomEdge = false
    var section: String?
    var extraAttachments: [String: any ListAttachment] = [:]
    private let storage = DemoRowStorage()
    init(identity: String, revision: UInt64 = 0, title: String, body: String, height: Double, tint: UIColor = .systemIndigo, inverted: Bool = false, pinsToBottomEdge: Bool = false, section: String? = nil) {
        self.identity = identity; self.revision = revision; self.title = title; self.body = body; self.height = height
        self.tint = tint; self.inverted = inverted; self.pinsToBottomEdge = pinsToBottomEdge; self.section = section
    }
    var attachments: [String: any ListAttachment] { extraAttachments.merging(section.map { ["section": DemoListHeader(title: $0) as any ListAttachment] } ?? [:]) { first, _ in first } }
    var measuresAsynchronously: Bool { true }
    private var nodeRow: NodeRow {
        if let row = storage.rows[revision] { return row }
        let title = title, body = body, height = height, tint = Color(tint)
        let cardColor = Palette.card, labelColor = Palette.label, secondaryColor = Palette.secondaryLabel
        let row = NodeRow(identity: identity, revision: revision) {
            let text = UltraTextNode(body, textStyle: .init(color: secondaryColor, fontSize: 14))
            text.style.flex = 1
            let heading = UltraNode(style: styled { $0.flexDirection = .row; $0.alignItems = .center; $0.gap = 8 }, children: [
                UltraNode(style: styled { $0.width = 8; $0.height = 8; $0.borderRadius = 4; $0.backgroundColor = tint }),
                UltraTextNode(title, textStyle: .init(color: labelColor, fontSize: 15, fontWeight: .semibold), numberOfLines: 1),
            ])
            let card = UltraNode(style: styled { $0.flex = 1; $0.padding = 14; $0.gap = 6; $0.borderRadius = 16; $0.backgroundColor = cardColor; $0.overflow = .hidden }, children: [heading, text])
            return UltraNode(style: styled { $0.height = .points(height); $0.paddingHorizontal = 12; $0.paddingVertical = 4 }, children: [card])
        }
        storage.rows[revision] = row
        for key in storage.rows.keys.sorted().dropLast(3) { storage.rows.removeValue(forKey: key) }
        return row
    }
    func makeView() -> ListRowView { nodeRow.makeView() }
    func apply(to view: ListRowView, transition: ListTransition) {
        nodeRow.apply(to: view, transition: transition)
        view.transform = inverted ? .init(scaleX: 1, y: -1) : .identity
        view.accessibilityIdentifier = "row-\(identity)"; view.accessibilityLabel = title
    }
    func measure(width: Double, environment: RenderEnvironment) async -> Double? { await nodeRow.measure(width: width, environment: environment) }
}
@MainActor
private final class DemoRowStorage { var rows: [UInt64: NodeRow] = [:] }

@MainActor
struct DemoListHeader: ListAttachment {
    var title: String
    var edge: BoundaryEdge { .top }
    var reservesSpace: Bool { true }
    func makeView() -> ListAttachmentView { DemoHeaderView() }
    func apply(to view: ListAttachmentView, transition: ListTransition) { (view as? DemoHeaderView)?.title = title }
    func combines(with other: any ListAttachment) -> Bool { (other as? DemoListHeader)?.title == title }
}
@MainActor
final class DemoHeaderView: ListAttachmentView {
    var title = "" { didSet { text?.text = title } }
    var inverted = false
    private var text: UltraTextNode?
    private var host: NodeHostView?
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }
    override func update(width: Double, transition: ListTransition) -> Double { 32 }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        if host == nil {
            let text = UltraTextNode(title, textStyle: .init(color: Palette.label, fontSize: 12, fontWeight: .bold, textAlign: .center), numberOfLines: 1)
            text.style = styled { $0.width = 140; $0.height = 24; $0.borderRadius = 12; $0.backgroundColor = Palette.card; $0.paddingTop = 4 }
            let root = UltraNode(style: styled { $0.alignItems = .center; $0.paddingTop = 4 }, children: [text])
            let host = NodeHostView(rootNode: root)
            addSubview(host); self.host = host; self.text = text
        }
        host?.transform = inverted ? .init(scaleX: 1, y: -1) : .identity
        host?.frame = bounds; host?.prepare(size: bounds.size)
    }
}

@MainActor
final class LargeListController: UIViewController {
    let list: UltraListView
    private let actions = UIStackView(), status = UILabel()
    private var rows: [DemoListRow] = []
    private var counter = 10_000
    private let monitor = ListFrameMonitor(name: "feed")
    init(mode: ScrollEngineMode) { list = UltraListView(engineMode: mode); super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemGroupedBackground
        rows = (0..<10_000).map { index -> DemoListRow in
            let body = String(repeating: "Independent rows. Measured windows. Smooth motion. ", count: 1 + index % 4)
            let height: Double = 88 + Double(index % 5) * 24
            return DemoListRow(identity: String(index), title: "Row \(index.formatted())", body: body, height: height, section: "SECTION \(index / 20 + 1)")
        }
        actions.distribution = .fillEqually
        for (title, selector) in [("Insert", #selector(insertRows)), ("Delete", #selector(deleteRows)), ("Move", #selector(moveRows)), ("Resize", #selector(resizeRow)), ("5,000", #selector(jump)), ("Top", #selector(top))] {
            let button = UIButton(type: .system); button.setTitle(title, for: .normal); button.addTarget(self, action: selector, for: .touchUpInside); actions.addArrangedSubview(button)
            button.titleLabel?.font = .systemFont(ofSize: 13)
        }
        status.font = .monospacedSystemFont(ofSize: 11, weight: .medium); status.textColor = .secondaryLabel; status.textAlignment = .center
        for v in [actions, status, list] { v.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(v) }
        list.accessibilityIdentifier = "virtualFeed"
        NSLayoutConstraint.activate([
            actions.topAnchor.constraint(equalTo: view.topAnchor), actions.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12), actions.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12), actions.heightAnchor.constraint(equalToConstant: 36),
            status.topAnchor.constraint(equalTo: actions.bottomAnchor), status.leadingAnchor.constraint(equalTo: view.leadingAnchor), status.trailingAnchor.constraint(equalTo: view.trailingAnchor), status.heightAnchor.constraint(equalToConstant: 24),
            list.topAnchor.constraint(equalTo: status.bottomAnchor), list.leadingAnchor.constraint(equalTo: view.leadingAnchor), list.trailingAnchor.constraint(equalTo: view.trailingAnchor), list.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        list.onVisibleWindowChanged = { [weak self] in
            guard let self else { return }; status.text = "\(rows.count.formatted()) rows · \(list.loadedIndexRange.count) loaded · \(list.engineMode.rawValue)"
        }
        list.applyChanges(items: rows)
        monitor.start()
        if UserDefaults.standard.bool(forKey: "listProbe") {
            Task { [weak self] in
                let delay = UserDefaults.standard.double(forKey: "listProbeDelay")
                try? await Task.sleep(for: .seconds(delay > 0 ? delay : 2)); self?.list.beginMomentum(velocity: 6000)
                if UserDefaults.standard.bool(forKey: "listStall") {
                    try? await Task.sleep(for: .milliseconds(300))
                    // Opt-in probe: demonstrate that momentum survives a delayed sampler.
                    ListFrameMonitor.stallForProbe()
                }
                try? await Task.sleep(for: .seconds(5)); self?.monitor.finish()
            }
        }
    }
    private var visibleIndex: Int {
        list.loadedIndexRange.first(where: { (list.settledFrame(at: $0)?.maxY ?? 0) > 0 }) ?? 0
    }
    @objc private func insertRows() { counter += 1; rows.insert(.init(identity: String(counter), title: "Inserted \(counter)", body: "A new row in the visible window.", height: 112, tint: .systemGreen), at: min(visibleIndex + 1, rows.count)); list.applyChanges(items: rows) }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); monitor.finish() }
    @objc private func deleteRows() { if !rows.isEmpty { rows.remove(at: min(visibleIndex + 1, rows.count - 1)); list.applyChanges(items: rows) } }
    @objc private func moveRows() { if rows.count > 5 { let index = min(visibleIndex + 1, rows.count - 1); rows.insert(rows.remove(at: index), at: min(index + 4, rows.count)); list.applyChanges(items: rows) } }
    @objc private func resizeRow() {
        guard !rows.isEmpty else { return }
        let index = min(visibleIndex, rows.count - 1)
        rows[index].height = rows[index].height < 200 ? 240 : 88; rows[index].revision += 1
        list.applyChanges(items: rows)
    }
    @objc private func jump() { list.scrollTo(.init(index: min(5000, rows.count - 1)), transition: .smoothDeceleration()) }
    @objc private func top() { list.scrollTo(.init(index: 0), transition: .smoothDeceleration()) }
}

@MainActor
final class ListComparisonController: UIViewController {
    private var lists: [UltraListView] = []
    private let coast = UILabel()
    override func viewDidLoad() {
        super.viewDidLoad()
        let stack = UIStackView(); stack.axis = .horizontal; stack.spacing = 2; stack.distribution = .fillEqually
        coast.text = "Native coast: 0 pt"; coast.accessibilityIdentifier = "nativeCoast"; coast.accessibilityValue = "0"
        coast.font = .monospacedSystemFont(ofSize: 11, weight: .regular); coast.textAlignment = .center
        for child in [stack, coast] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: view.topAnchor), stack.bottomAnchor.constraint(equalTo: coast.topAnchor), stack.leadingAnchor.constraint(equalTo: view.leadingAnchor), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor), coast.heightAnchor.constraint(equalToConstant: 24), coast.bottomAnchor.constraint(equalTo: view.bottomAnchor), coast.leadingAnchor.constraint(equalTo: view.leadingAnchor), coast.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
        for mode in ScrollEngineMode.allCases {
            let column = UIStackView(); column.axis = .vertical
            let title = UILabel(); title.text = mode.rawValue; title.textAlignment = .center; title.font = .systemFont(ofSize: 12, weight: .bold)
            title.accessibilityIdentifier = "compare-\(mode.rawValue)"; title.accessibilityValue = "0"
            let list = UltraListView(engineMode: mode)
            lists.append(list)
            var starts: [Double] = [0]
            for index in 0..<1000 {
                let height: Double = 80 + Double(index % 4) * 20
                starts.append(starts[index] + height)
            }
            let rowStarts = starts
            list.onScroll = { [weak list, weak title] _ in
                guard let list, let index = list.loadedIndexRange.first, let frame = list.settledFrame(at: index) else { return }
                title?.accessibilityValue = String(rowStarts[index] - Double(frame.minY))
            }
            column.addArrangedSubview(title); column.addArrangedSubview(list); stack.addArrangedSubview(column)
            title.heightAnchor.constraint(equalToConstant: 32).isActive = true
            list.applyChanges(items: (0..<1000).map { DemoListRow(identity: String($0), title: "\($0)", body: "Same rows", height: Double(80 + $0 % 4 * 20)) })
        }
        if let reference = lists.first, let scroll = reference.contentView as? UIScrollView {
            // A common ancestor receives touches from every pane. UIKit remains
            // the native reference; the two custom engines consume its input.
            reference.attachScrollInput(to: view)
            for list in lists.dropFirst() {
                for pan in list.contentView.gestureRecognizers?.compactMap({ $0 as? UIPanGestureRecognizer }) ?? [] { pan.isEnabled = false }
            }
            reference.onScrollInput = { [weak self, weak scroll] event in
                guard let self else { return }
                for target in lists.dropFirst() { target.receiveScrollInput(event) }
                if event.phase == .ended, let scroll {
                    let release = scroll.contentOffset.y
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak scroll] in
                        guard let self, let scroll else { return }
                        let distance = abs(scroll.contentOffset.y - release)
                        coast.text = "Native coast: \(Int(distance)) pt"; coast.accessibilityValue = String(Double(distance))
                    }
                }
            }
        }
    }
}
#endif