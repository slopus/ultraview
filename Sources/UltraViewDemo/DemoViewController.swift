#if canImport(UIKit)
import UIKit
import UltraView

/// One screen whose every frame comes from UltraLayout: the node tree is
/// built and laid out on a background task, and the main thread only
/// applies the resulting frames to views that mirror the tree.
final class DemoViewController: UIViewController {
    private let screen = UIView()
    private var laidOutSize: CGSize?
    private var layoutTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.addSubview(screen)

        let header = label("UltraView", font: .systemFont(ofSize: 28, weight: .bold), color: .systemIndigo)
        let tiles = UIView()
        for (index, color) in [UIColor.systemPink, .systemOrange, .systemTeal].enumerated() {
            tiles.addSubview(label("\(index + 1)", font: .systemFont(ofSize: 24, weight: .semibold), color: color))
        }
        let card = label("Frames from Yoga", font: .systemFont(ofSize: 20, weight: .medium), color: .systemGreen)
        let footer = label(
            "Laid out off the main thread",
            font: .preferredFont(forTextStyle: .footnote),
            color: .secondarySystemBackground,
            textColor: .secondaryLabel
        )
        [header, tiles, card, footer].forEach(screen.addSubview)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        guard size != laidOutSize else { return }
        laidOutSize = size
        let insets = view.safeAreaInsets
        layoutTask?.cancel()
        layoutTask = Task { [screen] in
            let result = await Task.detached(priority: .userInitiated) {
                DemoScreen.layout(size: size, insets: insets)
            }.value
            guard !Task.isCancelled else { return }
            result.apply(to: screen)
        }
    }

    private func label(_ text: String, font: UIFont, color: UIColor, textColor: UIColor = .white) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = font
        label.textColor = textColor
        label.textAlignment = .center
        label.backgroundColor = color
        label.layer.cornerRadius = 16
        label.layer.cornerCurve = .continuous
        label.clipsToBounds = true
        return label
    }
}

/// The screen's node tree. Mirrors the view hierarchy in `DemoViewController`.
enum DemoScreen {
    static func layout(size: CGSize, insets: UIEdgeInsets) -> LayoutResult {
        var root = LayoutStyle()
        root.padding = LayoutInsets(
            top: insets.top + 16,
            left: insets.left + 16,
            bottom: insets.bottom + 16,
            right: insets.right + 16
        )
        root.gap = 16

        var header = LayoutStyle()
        header.height = .points(72)

        var tiles = LayoutStyle()
        tiles.flexDirection = .row
        tiles.gap = 12
        tiles.height = .points(120)
        var tile = LayoutStyle()
        tile.flexGrow = 1

        var card = LayoutStyle()
        card.flexGrow = 1

        var footer = LayoutStyle()
        footer.height = .points(44)

        let tree = Node(style: root, children: [
            Node(style: header),
            Node(style: tiles, children: [Node(style: tile), Node(style: tile), Node(style: tile)]),
            Node(style: card),
            Node(style: footer),
        ])
        return tree.layout(width: size.width, height: size.height)
    }
}
#endif
