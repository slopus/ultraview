#if canImport(UIKit)
import UIKit
import UltraView

/// A card for horizontal lists: a node tree drawn off the main thread.
@MainActor
func demoCardRow(identity: String, revision: UInt64 = 0, title: String, subtitle: String, tint: UIColor, selectable: Bool = false) -> NodeRow {
    let tint = Color(tint)
    // A resize stretches the rounded box with the row and crossfades the text.
    return NodeRow(identity: identity, revision: revision, animatesContent: true) {
        let heading = UltraTextNode(title, textStyle: .init(color: .white, fontSize: 17, fontWeight: .bold), numberOfLines: 1)
        heading.transitionKey = "title"
        let detail = UltraTextNode(subtitle, textStyle: .init(color: .white, fontSize: 13), numberOfLines: 3)
        detail.transitionKey = "detail"
        let card = UltraNode(style: styled { $0.flex = 1; $0.padding = 12; $0.borderRadius = 16; $0.backgroundColor = tint; $0.justifyContent = .spaceBetween; $0.overflow = .hidden }, children: [heading, detail])
        card.transitionKey = "card"
        if selectable { card.onPress = { DemoSelections.events.append(identity) } }
        return UltraNode(style: styled { $0.paddingHorizontal = 4 }, children: [card])
    }
}

/// Where a carousel was, kept while its row view is away.
@MainActor
final class CarouselState {
    var cards: [HorizontalRow]
    var anchor: (index: Int, position: Double)?
    init(cards: [HorizontalRow]) { self.cards = cards }
}

/// A feed row holding a horizontal list of cards.
@MainActor
struct DemoCarouselRow: ListRow {
    let identity: String
    let mode: ScrollEngineMode
    let state: CarouselState
    static let height = 176.0
    init(identity: String, mode: ScrollEngineMode, count: Int) {
        self.identity = identity; self.mode = mode
        let tints: [UIColor] = [.systemIndigo, .systemTeal, .systemPink, .systemOrange, .systemGreen, .systemPurple]
        state = CarouselState(cards: (0..<count).map { index in
            HorizontalRow(demoCardRow(identity: "\(identity)-card-\(index)", title: "Card \(index + 1)", subtitle: "Swipe sideways. The feed stays put.", tint: tints[index % tints.count], selectable: true), width: 148)
        })
    }
    func makeView() -> ListRowView { DemoCarouselView(identity: identity, mode: mode, state: state) }
}

@MainActor
final class DemoCarouselView: ListRowView {
    let horizontal: HorizontalListView
    private let state: CarouselState
    private var restored = false
    private var lastTouch = 0.0
    /// Whether the cards were last reported ready.
    private var cardsReady = false
    /// Past this time the row counts as ready even with cards still drawing,
    /// so a list waiting for it never waits long; 0 until the list first
    /// sizes it.
    private var readyDeadline = 0.0
    init(identity: String, mode: ScrollEngineMode, state: CarouselState) {
        horizontal = HorizontalListView(engineMode: mode); self.state = state
        super.init(frame: .zero)
        horizontal.accessibilityIdentifier = identity
        horizontal.list.accessibilityIdentifier = "\(identity)-list"
        addSubview(horizontal)
        horizontal.list.applyChanges(items: state.cards, newInsets: .init(top: 12, left: 8, bottom: 12, right: 8), transition: .none)
        horizontal.list.onScroll = { [weak self] _ in self?.record() }
        horizontal.list.onVisibleWindowChanged = { [weak self] in self?.watchCards() }
    }
    /// Ready once the cards it shows are drawn: a list that waits for its
    /// rows before showing them, as a jump does, then shows the carousel
    /// with its cards.
    override var isDisplayReady: Bool {
        // The list's items stay empty until its first cards are measured, so
        // the cards to show come from the state.
        let list = horizontal.list
        if state.cards.isEmpty || readyDeadline > 0 && CACurrentMediaTime() >= readyDeadline { return true }
        let rows = list.settledWindow.rows, views = list.loadedItemViews
        guard list.bounds.height > 0, let first = rows.first, let last = rows.last,
              views.count == rows.count,
              let firstFrame = list.settledFrame(at: first.index),
              let lastFrame = list.settledFrame(at: last.index) else { return false }
        // A ready first card can arrive before the next card's measurement.
        // Both open edges must cover the viewport before the row reports ready.
        let coversLeading = first.index == 0 || Double(firstFrame.minY) - first.reservedTop <= 0.5
        let coversTrailing = last.index + 1 == list.items.count
            || Double(lastFrame.maxY) + last.reservedBottom >= Double(list.bounds.height) - 0.5
        if let anchor = state.anchor, !list.loadedIndexRange.contains(anchor.index) { return false }
        return coversLeading && coversTrailing && views.allSatisfy(\.isDisplayReady)
    }
    override func update(width: Double, transition: ListTransition) -> Double {
        // The wait starts before the layout below, whose first pass of the
        // cards already asks whether they're ready.
        if readyDeadline == 0 {
            readyDeadline = CACurrentMediaTime() + 0.3
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.cardsChanged() }
        }
        // Sized here, before the list places it and outside any window, so
        // its cards are laid out and drawn ahead.
        if bounds.size != CGSize(width: width, height: DemoCarouselRow.height) {
            bounds.size = CGSize(width: width, height: DemoCarouselRow.height)
            layoutIfNeeded()
        }
        return DemoCarouselRow.height
    }
    private func watchCards() {
        for view in horizontal.list.loadedItemViews where view.onDisplayReady == nil {
            view.onDisplayReady = { [weak self] in self?.cardsChanged() }
        }
        cardsChanged()
    }
    private func cardsChanged() {
        let ready = isDisplayReady
        guard ready != cardsReady else { return }
        cardsReady = ready
        if ready { reportDisplayReady() }
    }
    /// The scrolled distance along the cards, for probes.
    var position: Double {
        let list = horizontal.list
        guard let first = list.loadedIndexRange.first, let frame = list.settledFrame(at: first) else { return 0 }
        return Double(first) * 148 + list.viewportInsets.top - frame.minY
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let event, event.type == .touches, let identity = horizontal.accessibilityIdentifier, self.point(inside: point, with: event), event.timestamp != lastTouch {
            lastTouch = event.timestamp
            DemoSelections.carouselTouches.append(DemoSelections.movingCarousels.contains(identity))
        }
        return super.hitTest(point, with: event)
    }
    private func record() {
        let list = horizontal.list
        guard let first = list.loadedIndexRange.first(where: { (list.settledFrame(at: $0)?.maxY ?? 0) > 0 }), let frame = list.settledFrame(at: first) else { return }
        state.anchor = (first, frame.minY)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        horizontal.frame = bounds
        guard !restored, bounds.width > 0 else { return }
        restored = true
        horizontal.layoutIfNeeded()
        if let anchor = state.anchor { horizontal.list.scrollTo(.init(index: anchor.index, pointOffset: anchor.position - 12), transition: .none) }
    }
}

/// A standalone horizontal list with the feed's mutations.
@MainActor
final class HorizontalListController: UIViewController {
    let horizontal: HorizontalListView
    let reversed: HorizontalListView
    private let actions = UIStackView(), status = UILabel()
    private var cards: [(identity: String, width: Double, revision: UInt64, tint: UIColor)] = []
    private var counter = 0
    private let probe = UILabel()
    private var link: CADisplayLink?
    init(mode: ScrollEngineMode) {
        horizontal = HorizontalListView(engineMode: mode); reversed = HorizontalListView(engineMode: mode)
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemGroupedBackground
        let tints: [UIColor] = [.systemIndigo, .systemTeal, .systemPink, .systemOrange, .systemGreen, .systemPurple]
        cards = (0..<200).map { ("h-\($0)", 120 + Double($0 % 3) * 50, 0, tints[$0 % tints.count]) }
        counter = cards.count
        actions.distribution = .fillEqually
        for (title, selector) in [("Insert", #selector(insertCard)), ("Delete", #selector(deleteCard)), ("Move", #selector(moveCard)), ("Resize", #selector(resizeCard)), ("End", #selector(end)), ("Start", #selector(start))] {
            let button = UIButton(type: .system); button.setTitle(title, for: .normal); button.addTarget(self, action: selector, for: .touchUpInside)
            button.titleLabel?.font = .systemFont(ofSize: 13); button.accessibilityIdentifier = "horizontal\(title)"; actions.addArrangedSubview(button)
        }
        status.font = .monospacedSystemFont(ofSize: 11, weight: .medium); status.textColor = .secondaryLabel; status.textAlignment = .center
        let caption = UILabel(); caption.text = "Right to left"; caption.font = .systemFont(ofSize: 12, weight: .semibold); caption.textColor = .secondaryLabel
        reversed.semanticContentAttribute = .forceRightToLeft
        horizontal.accessibilityIdentifier = "horizontalList"; reversed.accessibilityIdentifier = "horizontalListRTL"
        probe.accessibilityIdentifier = "horizontalProbe"; probe.isAccessibilityElement = true; probe.text = " "
        for v in [actions, status, horizontal, caption, reversed, probe] { v.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(v) }
        NSLayoutConstraint.activate([
            actions.topAnchor.constraint(equalTo: view.topAnchor), actions.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12), actions.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12), actions.heightAnchor.constraint(equalToConstant: 36),
            status.topAnchor.constraint(equalTo: actions.bottomAnchor), status.leadingAnchor.constraint(equalTo: view.leadingAnchor), status.trailingAnchor.constraint(equalTo: view.trailingAnchor), status.heightAnchor.constraint(equalToConstant: 24),
            horizontal.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 8), horizontal.leadingAnchor.constraint(equalTo: view.leadingAnchor), horizontal.trailingAnchor.constraint(equalTo: view.trailingAnchor), horizontal.heightAnchor.constraint(equalToConstant: 220),
            caption.topAnchor.constraint(equalTo: horizontal.bottomAnchor, constant: 16), caption.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            reversed.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 8), reversed.leadingAnchor.constraint(equalTo: view.leadingAnchor), reversed.trailingAnchor.constraint(equalTo: view.trailingAnchor), reversed.heightAnchor.constraint(equalToConstant: 150),
            probe.bottomAnchor.constraint(equalTo: view.bottomAnchor), probe.leadingAnchor.constraint(equalTo: view.leadingAnchor), probe.widthAnchor.constraint(equalToConstant: 1), probe.heightAnchor.constraint(equalToConstant: 1),
        ])
        horizontal.list.onVisibleWindowChanged = { [weak self] in
            guard let self else { return }; status.text = "\(cards.count) cards · \(horizontal.list.loadedIndexRange.count) loaded · \(horizontal.list.engineMode.rawValue)"
        }
        let insets = ListInsets(top: 12, left: 12, bottom: 12, right: 12)
        horizontal.list.applyChanges(items: rows, newInsets: insets, transition: .none)
        reversed.list.applyChanges(items: rows.prefix(30).map { HorizontalRow($0.base, width: 110) }, newInsets: insets, transition: .none)
        if UserDefaults.standard.bool(forKey: "listSwipeProbe") {
            let link = CADisplayLink(target: self, selector: #selector(sample)); link.add(to: .main, forMode: .common); self.link = link
        }
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); link?.invalidate(); link = nil }
    private var rows: [HorizontalRow] {
        cards.map { card in
            HorizontalRow(demoCardRow(identity: card.identity, revision: card.revision, title: card.identity.replacingOccurrences(of: "h-", with: "Item "), subtitle: "\(Int(card.width)) points wide", tint: card.tint), width: card.width)
        }
    }
    /// The first card fully or partly on screen.
    private var visibleIndex: Int {
        horizontal.list.loadedIndexRange.first(where: { (horizontal.list.settledFrame(at: $0)?.maxY ?? 0) > 0 }) ?? 0
    }
    private func apply() { horizontal.list.applyChanges(items: rows) }
    @objc private func insertCard() { counter += 1; cards.insert(("h-\(counter)", 140, 0, .systemGreen), at: min(visibleIndex + 1, cards.count)); apply() }
    @objc private func deleteCard() { if !cards.isEmpty { cards.remove(at: min(visibleIndex + 1, cards.count - 1)); apply() } }
    @objc private func moveCard() { if cards.count > 5 { let index = min(visibleIndex + 1, cards.count - 1); cards.insert(cards.remove(at: index), at: min(index + 3, cards.count)); apply() } }
    @objc private func resizeCard() {
        guard !cards.isEmpty else { return }
        let index = min(visibleIndex + 1, cards.count - 1)
        cards[index].width = cards[index].width < 200 ? 260 : 120; cards[index].revision += 1
        apply()
    }
    @objc private func end() { horizontal.list.scrollTo(.init(index: max(0, cards.count - 1)), transition: .smoothDeceleration()) }
    @objc private func start() { horizontal.list.scrollTo(.init(index: 0), transition: .smoothDeceleration()) }
    @objc private func sample() {
        let list = horizontal.list
        let frames = list.loadedIndexRange.compactMap { index -> [String: Any]? in
            guard let frame = list.settledFrame(at: index), let view = list.loadedItemView(at: index) else { return nil }
            let screen = view.convert(view.bounds, to: horizontal)
            return ["index": index, "x": screen.minX, "y": screen.minY, "width": screen.width, "height": screen.height, "listY": frame.minY]
        }
        let document: [String: Any] = ["cards": cards.count, "frames": frames, "position": list.loadedIndexRange.first.map { index in
            Double(cards.prefix(index).reduce(0) { $0 + $1.width }) + list.viewportInsets.top - Double(list.settledFrame(at: index)?.minY ?? 0)
        } ?? 0]
        if let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]) { probe.accessibilityValue = String(decoding: data, as: UTF8.self) }
    }
}
#endif
