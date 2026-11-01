#if canImport(UIKit)
import UIKit
import UltraView

/// Lists whose width changes: a feed of fixed-height cards and a flipped
/// chat of bubbles, side by side beside a sidebar column that slides in and
/// out like a split view's. Rotate the device, toggle the sidebar, or drag
/// the width a little every frame as a resized window does; each list
/// relays its rows out at the new width in the frame of the change.
///
/// `-listScreen resize` opens it. `-resizeScenario YES` plays the sidebar,
/// a drag, and a rotation there and back, for recordings;
/// `-resizeSlow <n>` plays the window's animations `n` times slower.
@MainActor
final class ListResizeController: UIViewController {
    private let feed: UltraListView
    private let chat: UltraListView
    private let thread = ChatThread(seeded: 60)
    private let stage = UIView(), sidebar = UIView(), content = UIView(), divider = UIView()
    private let actions = UIStackView(), status = UILabel()
    private var showsSidebar = false
    /// The content's width, as a fraction of the stage, while a drag plays.
    private var dragFraction: CGFloat?
    private var dragLink: CADisplayLink?
    private var dragStart: CFTimeInterval = 0
    /// How long each width change's layout held the main thread, in ms.
    private var layoutTimes: [Double] = []

    init(mode: ScrollEngineMode) {
        feed = UltraListView(engineMode: mode); chat = UltraListView(engineMode: mode)
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemGroupedBackground
        actions.distribution = .fillEqually
        for (title, selector) in [("Sidebar", #selector(slideSidebar)), ("Rotate", #selector(rotate)), ("Drag", #selector(drag))] {
            let button = UIButton(type: .system); button.setTitle(title, for: .normal); button.titleLabel?.font = .systemFont(ofSize: 13)
            button.accessibilityIdentifier = "resize\(title)"
            button.addTarget(self, action: selector, for: .touchUpInside); actions.addArrangedSubview(button)
        }
        status.font = .monospacedSystemFont(ofSize: 11, weight: .medium); status.textColor = .secondaryLabel; status.textAlignment = .center
        status.accessibilityIdentifier = "resizeStatus"
        sidebar.backgroundColor = .secondarySystemBackground
        let sidebarTitle = UILabel(); sidebarTitle.text = "Sidebar"; sidebarTitle.font = .boldSystemFont(ofSize: 22)
        sidebarTitle.frame = .init(x: 20, y: 16, width: 240, height: 30); sidebar.addSubview(sidebarTitle)
        divider.backgroundColor = .separator
        stage.clipsToBounds = true
        for subview in [sidebar, content] { stage.addSubview(subview) }
        for subview in [feed, chat, divider] { content.addSubview(subview) }
        for subview in [actions, status, stage] { view.addSubview(subview) }
        // The two lists split the content's width; it changes, they follow.
        feed.autoresizingMask = [.flexibleWidth, .flexibleRightMargin, .flexibleHeight]
        chat.autoresizingMask = [.flexibleWidth, .flexibleLeftMargin, .flexibleHeight]
        divider.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleHeight]
        feed.accessibilityIdentifier = "resizeFeed"; chat.accessibilityIdentifier = "resizeChat"
        chat.contentView.transform = .init(scaleX: 1, y: -1)

        feed.applyChanges(items: (0..<400).map { index in
            DemoListRow(identity: "card-\(index)", title: "Card \(index)",
                body: String(repeating: "A card with a fixed height: it keeps its place at any width. ", count: 1 + index % 3),
                height: 96 + Double(index % 3) * 20)
        })
        chat.applyChanges(items: thread.rows)
        feed.onVisibleWindowChanged = { [weak self] in self?.showStatus() }
        chat.onVisibleWindowChanged = { [weak self] in self?.showStatus() }

        let slow = UserDefaults.standard.double(forKey: "resizeSlow")
        if slow > 1 { DispatchQueue.main.async { [weak self] in self?.view.window?.layer.speed = Float(1 / slow) } }
        if UserDefaults.standard.bool(forKey: "resizeScenario") { Task { await runScenario() } }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        dragLink?.invalidate(); dragLink = nil
        view.window?.layer.speed = 1
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        actions.frame = .init(x: 12, y: 0, width: bounds.width - 24, height: 36)
        status.frame = .init(x: 0, y: 36, width: bounds.width, height: 20)
        stage.frame = .init(x: 0, y: 56, width: bounds.width, height: max(0, bounds.height - 56))
        layOutStage()
    }

    /// The sidebar takes 300 points at the leading edge when shown; the
    /// content takes the rest, or the drag's share of the stage.
    private func layOutStage() {
        let bounds = stage.bounds
        let sidebarWidth = min(300, bounds.width * 0.45)
        sidebar.frame = .init(x: showsSidebar ? 0 : -sidebarWidth, y: 0, width: sidebarWidth, height: bounds.height)
        let x = showsSidebar ? sidebarWidth : 0
        let width = dragFraction.map { bounds.width * $0 } ?? bounds.width - x
        let resized = content.bounds.size != CGSize(width: width, height: bounds.height)
        content.frame = .init(x: x, y: 0, width: width, height: bounds.height)
        if feed.frame == .zero {
            feed.frame = .init(x: 0, y: 0, width: width / 2, height: bounds.height)
            divider.frame = .init(x: width / 2, y: 0, width: 1, height: bounds.height)
            chat.frame = .init(x: width / 2 + 1, y: 0, width: width / 2 - 1, height: bounds.height)
        }
        // Lay the lists out now, inside any animation of the change.
        if resized {
            let started = CACurrentMediaTime()
            content.layoutIfNeeded()
            layoutTimes.append((CACurrentMediaTime() - started) * 1000)
        }
    }

    private func showStatus() {
        let reports = [feed.lastResize, chat.lastResize].compactMap { $0 }
        guard !reports.isEmpty else { status.text = "Resize the window, rotate, or toggle the sidebar"; return }
        let rows = reports.map(\.preparedRows).reduce(0, +), late = reports.map(\.lateRows).reduce(0, +)
        let wall = reports.map(\.milliseconds).reduce(0, +), cpu = reports.map(\.cpuMilliseconds).reduce(0, +)
        let text = String(format: "last resize: %d rows at %.0f + %.0f pt, %d late · %.1f ms (CPU %.1f)",
                          rows, reports[0].width, reports.last!.width, late, wall, cpu)
        if status.text != text { status.text = text }
    }

    @objc private func slideSidebar() {
        showsSidebar.toggle()
        UIView.animate(springDuration: 0.5, bounce: 0) { layOutStage() }
    }

    @objc private func rotate() {
        guard let scene = view.window?.windowScene else { return }
        let landscape = scene.effectiveGeometry.interfaceOrientation.isLandscape
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .portrait : .landscapeRight)) { error in
            print("RESIZE rotation failed: \(error)")
        }
    }

    /// The content's width follows a finger dragging a window's edge: in
    /// to 55% and back out over two seconds, a new width every frame.
    @objc private func drag() {
        dragLink?.invalidate()
        dragStart = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(dragFrame))
        link.preferredFrameRateRange = .init(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common); dragLink = link
    }
    @objc private func dragFrame() {
        let speed = Double(view.window?.layer.speed ?? 1)
        let phase = min(1, (CACurrentMediaTime() - dragStart) * speed / 2)
        let shown: CGFloat = showsSidebar ? (stage.bounds.width - sidebar.bounds.width) / max(1, stage.bounds.width) : 1
        dragFraction = shown - (shown - 0.55) * CGFloat(sin(phase * .pi))
        layOutStage()
        if phase >= 1 { dragFraction = nil; layOutStage(); dragLink?.invalidate(); dragLink = nil }
    }

    private func runScenario() async {
        let speed = max(1, UserDefaults.standard.double(forKey: "resizeSlow"))
        func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds * speed)) }
        await pause(1.5)
        slideSidebar(); await pause(1)
        slideSidebar(); await pause(1)
        drag(); await pause(2.5)
        rotate(); await pause(1.5)
        rotate(); await pause(1.5)
        let times = layoutTimes.sorted()
        if !times.isEmpty {
            print(String(format: "RESIZE-SCENARIO layouts %d, median %.2f ms, p95 %.2f ms, max %.2f ms", times.count,
                         times[times.count / 2], times[min(times.count - 1, times.count * 95 / 100)], times.last!))
        }
        print("RESIZE-SCENARIO done")
    }
}
#endif
