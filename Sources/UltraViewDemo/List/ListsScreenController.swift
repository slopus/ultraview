#if canImport(UIKit)
import UIKit
import UltraView

@MainActor
final class ListsScreenController: UIViewController {
    private let tabs = UISegmentedControl(items: ["Chat", "10k feed", "Compare", "Record"])
    private let engines = UISegmentedControl(items: ["UIKit", "Stepped", "Keyframe"])
    private var child: UIViewController?
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        tabs.accessibilityIdentifier = "listScreens"; engines.accessibilityIdentifier = "listEngines"
        let screen = UserDefaults.standard.string(forKey: "listScreen") ?? "feed"
        tabs.selectedSegmentIndex = ["chat", "feed", "compare", "record"].firstIndex(of: screen) ?? 1
        engines.selectedSegmentIndex = 2
        tabs.addTarget(self, action: #selector(showScreen), for: .valueChanged)
        engines.addTarget(self, action: #selector(showScreen), for: .valueChanged)
        for control in [tabs, engines] { control.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(control) }
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            tabs.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), tabs.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            engines.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 8), engines.leadingAnchor.constraint(equalTo: tabs.leadingAnchor), engines.trailingAnchor.constraint(equalTo: tabs.trailingAnchor),
        ])
        showScreen()
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
            next.view.topAnchor.constraint(equalTo: engines.bottomAnchor, constant: 8), next.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
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
    var attachments: [String: any ListAttachment] { section.map { ["section": DemoListHeader(title: $0)] } ?? [:] }
    func makeView() -> ListRowView { DemoListRowView() }
    func apply(to view: ListRowView, transition: ListTransition) { (view as? DemoListRowView)?.configure(self) }
}

@MainActor
final class DemoListRowView: ListRowView {
    private let card = UIView(), title = UILabel(), body = UILabel(), dot = UIView()
    private var rowHeight: Double = 60
    override init(frame: CGRect) {
        super.init(frame: frame)
        card.layer.cornerRadius = 16; card.backgroundColor = .secondarySystemGroupedBackground
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        body.font = .systemFont(ofSize: 14); body.textColor = .secondaryLabel; body.numberOfLines = 0
        dot.layer.cornerRadius = 4
        addSubview(card); for view in [title, body, dot] { card.addSubview(view) }
    }
    func configure(_ row: DemoListRow) {
        title.text = row.title; body.text = row.body; rowHeight = row.height; dot.backgroundColor = row.tint
        transform = row.inverted ? CGAffineTransform(scaleX: 1, y: -1) : .identity
        accessibilityLabel = row.title; accessibilityIdentifier = "row-\(row.identity)"
        setNeedsLayout()
    }
    override func update(width: Double, transition: ListTransition) -> Double { rowHeight }
    override func layoutSubviews() {
        super.layoutSubviews()
        card.frame = bounds.insetBy(dx: 12, dy: 4)
        dot.frame = .init(x: 14, y: 17, width: 8, height: 8)
        title.frame = .init(x: 30, y: 10, width: max(0, card.bounds.width - 44), height: 22)
        let bodyWidth = max(0, card.bounds.width - 28)
        let bodyHeight = min(max(0, card.bounds.height - 44), body.sizeThatFits(.init(width: bodyWidth, height: .greatestFiniteMagnitude)).height)
        body.frame = .init(x: 14, y: 36, width: bodyWidth, height: bodyHeight)
    }
}

@MainActor
struct DemoListHeader: ListAttachment {
    var title: String
    var edge: BoundaryEdge { .top }
    var reservesSpace: Bool { true }
    func makeView() -> ListAttachmentView { DemoHeaderView() }
    func apply(to view: ListAttachmentView, transition: ListTransition) { (view as? DemoHeaderView)?.label.text = title }
    func combines(with other: any ListAttachment) -> Bool { (other as? DemoListHeader)?.title == title }
}
@MainActor
final class DemoHeaderView: ListAttachmentView {
    let label = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame); addSubview(label)
        label.font = .systemFont(ofSize: 12, weight: .bold); label.textAlignment = .center
        label.backgroundColor = .tertiarySystemBackground; label.layer.cornerRadius = 12; label.clipsToBounds = true
        isUserInteractionEnabled = false
    }
    override func update(width: Double, transition: ListTransition) -> Double { 32 }
    override func layoutSubviews() { super.layoutSubviews(); label.frame = .init(x: max(0, bounds.midX - 70), y: 4, width: 140, height: 24) }
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
        for (title, selector) in [("Insert", #selector(insertRows)), ("Delete", #selector(deleteRows)), ("Move", #selector(moveRows)), ("5,000", #selector(jump)), ("Top", #selector(top))] {
            let button = UIButton(type: .system); button.setTitle(title, for: .normal); button.addTarget(self, action: selector, for: .touchUpInside); actions.addArrangedSubview(button)
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
    @objc private func insertRows() { counter += 1; rows.insert(.init(identity: String(counter), title: "Inserted \(counter)", body: "A new row at the start.", height: 112, tint: .systemGreen), at: 0); list.applyChanges(items: rows, transition: .easeInOut(0.4)) }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); monitor.finish() }
    @objc private func deleteRows() { if !rows.isEmpty { rows.removeFirst(); list.applyChanges(items: rows, transition: .easeInOut(0.4)) } }
    @objc private func moveRows() { if rows.count > 5 { rows.insert(rows.remove(at: 1), at: 5); list.applyChanges(items: rows, transition: .easeInOut(0.4)) } }
    @objc private func jump() { list.scrollTo(.init(index: min(5000, rows.count - 1)), transition: .smoothDeceleration()) }
    @objc private func top() { list.scrollTo(.init(index: 0), transition: .smoothDeceleration()) }
}

@MainActor
final class ListComparisonController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let stack = UIStackView(); stack.axis = .horizontal; stack.spacing = 2; stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: view.topAnchor), stack.bottomAnchor.constraint(equalTo: view.bottomAnchor), stack.leadingAnchor.constraint(equalTo: view.leadingAnchor), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
        for mode in ScrollEngineMode.allCases {
            let column = UIStackView(); column.axis = .vertical
            let title = UILabel(); title.text = mode.rawValue; title.textAlignment = .center; title.font = .systemFont(ofSize: 12, weight: .bold)
            let list = UltraListView(engineMode: mode)
            column.addArrangedSubview(title); column.addArrangedSubview(list); stack.addArrangedSubview(column)
            title.heightAnchor.constraint(equalToConstant: 32).isActive = true
            list.applyChanges(items: (0..<1000).map { DemoListRow(identity: String($0), title: "\($0)", body: "Same rows", height: Double(80 + $0 % 4 * 20)) })
        }
    }
}
#endif