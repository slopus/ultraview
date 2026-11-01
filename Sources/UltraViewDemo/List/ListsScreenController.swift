#if canImport(UIKit)
import UIKit
import UltraView

@MainActor
final class ListsScreenController: UIViewController {
    private let tabs = UISegmentedControl(items: ["Chat", "10k feed", "Compare", "Record", "Across", "Width"])
    private let engines = UISegmentedControl(items: ["UIKit", "Stepped", "Keyframe"])
    private let blocker = UISegmentedControl(items: ["Main off", "50 ms", "100 ms", "250 ms"])
    private let controls = UIStackView()
    private var blocking: Task<Void, Never>?
    private var child: UIViewController?
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        tabs.accessibilityIdentifier = "listScreens"; engines.accessibilityIdentifier = "listEngines"
        let screen = UserDefaults.standard.string(forKey: "listScreen") ?? "feed"
        tabs.selectedSegmentIndex = ["chat", "feed", "compare", "record", "horizontal", "resize"].firstIndex(of: screen) ?? 1
        let initialEngine = UserDefaults.standard.string(forKey: "listEngine") ?? "keyframe"
        engines.selectedSegmentIndex = ScrollEngineMode.allCases.firstIndex(where: { $0.rawValue == initialEngine }) ?? 2
        tabs.addTarget(self, action: #selector(showScreen), for: .valueChanged)
        engines.addTarget(self, action: #selector(showScreen), for: .valueChanged)
        blocker.accessibilityIdentifier = "listMainBlocker"; blocker.selectedSegmentIndex = 0
        blocker.addTarget(self, action: #selector(updateBlocker), for: .valueChanged)
        controls.translatesAutoresizingMaskIntoConstraints = false; controls.distribution = .fillEqually
        for control in [tabs, engines, blocker] { controls.addArrangedSubview(control) }
        view.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            controls.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
        ])
        updateControlLayout()
        registerForTraitChanges([UITraitVerticalSizeClass.self]) { (controller: ListsScreenController, _: UITraitCollection) in controller.updateControlLayout() }
        showScreen()
        ListChaosDriver.startIfRequested(lists: self)
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); updateBlocker() }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); blocking?.cancel(); blocking = nil }
    private func updateControlLayout() {
        let compact = traitCollection.verticalSizeClass == .compact
        controls.axis = compact ? .horizontal : .vertical
        controls.spacing = compact ? 6 : 8
        for control in [tabs, engines, blocker] {
            control.setTitleTextAttributes(compact ? [.font: UIFont.systemFont(ofSize: 12)] : [:], for: .normal)
        }
    }
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
        case 4: next = HorizontalListController(mode: mode)
        case 5: next = ListResizeController(mode: mode)
        default: next = LargeListController(mode: mode)
        }
        addChild(next); next.view.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(next.view)
        NSLayoutConstraint.activate([
            next.view.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 8), next.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
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
    var leadingSwipeActions: [ListSwipeAction] = []
    var trailingSwipeActions: [ListSwipeAction] = []
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
        // A resize stretches the rounded card with the row and crossfades the text.
        let row = NodeRow(identity: identity, revision: revision, animatesContent: true) {
            let text = UltraTextNode(body, textStyle: .init(color: secondaryColor, fontSize: 14))
            text.style.flex = 1
            text.transitionKey = "body"
            let label = UltraTextNode(title, textStyle: .init(color: labelColor, fontSize: 15, fontWeight: .semibold), numberOfLines: 1)
            label.transitionKey = "title"
            let heading = UltraNode(style: styled { $0.flexDirection = .row; $0.alignItems = .center; $0.gap = 8 }, children: [
                UltraNode(style: styled { $0.width = 8; $0.height = 8; $0.borderRadius = 4; $0.backgroundColor = tint }),
                label,
            ])
            let card = UltraNode(style: styled { $0.flex = 1; $0.padding = 14; $0.gap = 6; $0.borderRadius = 16; $0.backgroundColor = cardColor; $0.overflow = .hidden }, children: [heading, text])
            card.transitionKey = "card"
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
        // A row with swipe actions is one element, so VoiceOver offers its actions.
        let swipes = !leadingSwipeActions.isEmpty || !trailingSwipeActions.isEmpty
        view.isAccessibilityElement = swipes; view.accessibilityValue = swipes ? body : nil
    }
    func measure(width: Double, environment: RenderEnvironment) async -> Double? { await nodeRow.measure(width: width, environment: environment) }
    func prepare(width: Double, environment: RenderEnvironment) async -> ListPreparation? { await nodeRow.prepare(width: width, environment: environment) }
    func prepareInPlace(width: Double, environment: RenderEnvironment) -> ListInPlacePreparation? { nodeRow.prepareInPlace(width: width, environment: environment) }
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
final class LargeListController: UIViewController, ListChaosRowHost {
    let list: UltraListView
    private let actions = UIStackView(), status = UILabel()
    private var rows: [DemoListRow] = []
    private var counter = 10_000
    private let monitor = ListFrameMonitor(name: "feed")
    private var carousels: [String: DemoCarouselRow] = [:]
    private var swipeProbe: ListSwipeProbe?
    /// Opt-in: "fling" applies a swipe delete with momentum in flight, "resize" during a neighbour's resize.
    private let swipeStress = UserDefaults.standard.string(forKey: "listSwipeStress")
    private var stressTimer: Timer?
    private var stressTall = false
    var chaosRows: [DemoListRow] { get { rows } set { rows = newValue } }
    init(mode: ScrollEngineMode) { list = UltraListView(engineMode: mode); super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemGroupedBackground
        rows = (0..<10_000).map { index -> DemoListRow in
            let body = String(repeating: "Independent rows. Measured windows. Smooth motion. ", count: 1 + index % 4)
            let height: Double = 88 + Double(index % 5) * 24
            return DemoListRow(identity: String(index), title: "Row \(index.formatted())", body: body, height: height, section: "SECTION \(index / 20 + 1)")
        }
        rows = rows.map(withSwipeActions)
        // Carousels follow these rows; chaos runs keep the plain collection it checks.
        if UserDefaults.standard.string(forKey: "listChaos") == nil {
            for anchor in ["2", "45", "130"] { carousels[anchor] = DemoCarouselRow(identity: "carousel-\(anchor)", mode: list.engineMode, count: 40 + anchor.count * 20) }
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
            guard let self else { return }
            let text = "\(rows.count.formatted()) rows · \(list.loadedIndexRange.count) loaded · \(list.engineMode.rawValue)"
            if status.text != text { status.text = text }
        }
        list.applyChanges(items: displayed)
        if UserDefaults.standard.bool(forKey: "listSwipeProbe") { swipeProbe = ListSwipeProbe(owner: view, list: list) }
        if swipeStress == "resize" { startResizeStress() }
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
    /// The rows with each carousel after its anchor row.
    private var displayed: [any ListRow] {
        guard !carousels.isEmpty else { return rows }
        var items: [any ListRow] = []
        items.reserveCapacity(rows.count + carousels.count)
        for row in rows {
            items.append(row)
            if let carousel = carousels[row.identity] { items.append(carousel) }
        }
        return items
    }
    /// The first visible row of `rows`.
    private var visibleIndex: Int {
        let index = list.loadedIndexRange.first(where: { (list.settledFrame(at: $0)?.maxY ?? 0) > 0 }) ?? 0
        let items = list.items
        for candidate in index..<max(index, items.count) {
            if let row = rows.firstIndex(where: { $0.identity == items[candidate].identity }) { return row }
        }
        return 0
    }
    private func withSwipeActions(_ row: DemoListRow) -> DemoListRow {
        var row = row
        let identity = row.identity
        row.trailingSwipeActions = [
            ListSwipeAction(title: "Delete", image: UIImage(systemName: "trash"), isDestructive: true) { [weak self] in self?.remove(identity, action: "delete") },
            ListSwipeAction(title: "Archive", image: UIImage(systemName: "archivebox"), color: .systemIndigo) { [weak self] in self?.remove(identity, action: "archive") },
        ]
        row.leadingSwipeActions = [
            ListSwipeAction(title: row.title.hasPrefix("Pinned") ? "Unpin" : "Pin", image: UIImage(systemName: "pin"), color: .systemOrange) { [weak self] in self?.togglePin(identity) },
        ]
        return row
    }
    private func remove(_ identity: String, action: String) {
        guard let index = rows.firstIndex(where: { $0.identity == identity }) else { return }
        swipeProbe?.willRemove(identity, action: action)
        rows.remove(at: index)
        if swipeStress == "fling" {
            // The removal applies on the next turn, with momentum toward the end in flight.
            list.beginMomentum(velocity: 1500)
            DispatchQueue.main.async { [weak self] in self?.applyRemoval() }
        } else { applyRemoval() }
        if stressTimer != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.stressTimer?.invalidate(); self?.stressTimer = nil }
        }
    }
    private func applyRemoval() {
        let items = swipeProbe?.measure("buildItems") { displayed } ?? displayed
        if let swipeProbe { swipeProbe.measure("applyChanges") { list.applyChanges(items: items) } } else { list.applyChanges(items: items) }
    }
    /// Keeps a resize of row 2 in flight, so a swipe deletes its neighbour mid-resize.
    private func startResizeStress() {
        stressTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let index = self.rows.firstIndex(where: { $0.identity == "2" }) else { return }
                self.stressTall.toggle()
                self.rows[index].height = self.stressTall ? 220 : 136; self.rows[index].revision += 1
                self.list.applyChanges(items: self.displayed)
            }
        }
    }
    private func togglePin(_ identity: String) {
        guard let index = rows.firstIndex(where: { $0.identity == identity }) else { return }
        swipeProbe?.record("pin:\(identity)")
        var row = rows[index]
        let pinned = row.title.hasPrefix("Pinned · ")
        row.title = pinned ? String(row.title.dropFirst("Pinned · ".count)) : "Pinned · " + row.title
        row.tint = pinned ? .systemIndigo : .systemOrange
        row.revision += 1
        rows[index] = withSwipeActions(row)
        list.applyChanges(items: displayed)
    }
    @objc private func insertRows() { counter += 1; rows.insert(withSwipeActions(.init(identity: String(counter), title: "Inserted \(counter)", body: "A new row in the visible window.", height: 112, tint: .systemGreen)), at: min(visibleIndex + 1, rows.count)); list.applyChanges(items: displayed) }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); monitor.finish(); stressTimer?.invalidate(); stressTimer = nil }
    @objc private func deleteRows() { if !rows.isEmpty { rows.remove(at: min(visibleIndex + 1, rows.count - 1)); list.applyChanges(items: displayed) } }
    @objc private func moveRows() { if rows.count > 5 { let index = min(visibleIndex + 1, rows.count - 1); rows.insert(rows.remove(at: index), at: min(index + 4, rows.count)); list.applyChanges(items: displayed) } }
    @objc private func resizeRow() {
        guard !rows.isEmpty else { return }
        let index = min(visibleIndex, rows.count - 1)
        rows[index].height = rows[index].height < 200 ? 240 : 88; rows[index].revision += 1
        list.applyChanges(items: displayed)
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