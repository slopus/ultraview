#if canImport(UIKit)
import UIKit
import UltraView

/// The demo's tabs. Launch with `-screen layout`, `-screen feed` or
/// `-screen stress` to open on a given one.
enum DemoScreen: String, CaseIterable {
    case layout
    case feed
    case stress
    case lists

    var title: String {
        switch self {
        case .layout: "Layout"
        case .feed: "Feed"
        case .stress: "Stress"
        case .lists: "Lists"
        }
    }

    var symbol: String {
        switch self {
        case .layout: "square.grid.2x2"
        case .feed: "text.bubble"
        case .stress: "speedometer"
        case .lists: "list.bullet"
        }
    }

    @MainActor
    func makeController() -> UIViewController {
        let controller: UIViewController = switch self {
        case .layout: NodeScreenController(rootNode: LayoutScreen.make())
        case .feed: NodeScreenController(rootNode: FeedScreen.make(cardCount: 1_000))
        case .stress: StressScreenController()
        case .lists: ListsScreenController()
        }
        controller.tabBarItem = UITabBarItem(title: title, image: UIImage(systemName: symbol), tag: 0)
        return controller
    }

    static var initial: DemoScreen {
        UserDefaults.standard.string(forKey: "screen").flatMap(DemoScreen.init(rawValue:)) ?? .layout
    }
}

/// Shows one node tree, filling the safe area.
class NodeScreenController: UIViewController {
    let rootNode: UltraNode
    private(set) lazy var host = NodeHostView(rootNode: rootNode)

    init(rootNode: UltraNode) {
        self.rootNode = rootNode
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            host.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }
}

/// Builds a style in place: `styled { $0.flexDirection = .row }`.
func styled(_ body: (inout Style) -> Void) -> Style {
    var style = Style()
    body(&style)
    return style
}

enum Palette {
    static let background = Color(UIColor.systemGroupedBackground)
    static let card = Color(UIColor.secondarySystemGroupedBackground)
    static let label = Color(UIColor.label)
    static let secondaryLabel = Color(UIColor.secondaryLabel)
    static let separator = Color(UIColor.separator)
    static let accent = Color.indigo
}
#endif
