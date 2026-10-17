#if canImport(UIKit)
import UIKit
import UltraLayout

/// The view of a mounted node. It shows what commits set on it and handles
/// presses: on the node itself when it has press handlers, and on pressable
/// text spans. All press state is main-thread state; nothing here measures
/// or draws.
final class NodeView: UIView {
    weak var node: UltraNode?

    /// The properties last applied, for hit testing and presses.
    var props: ViewProps? {
        didSet { updatePressedAppearance() }
    }

    private enum Target: Equatable {
        case node
        case link(index: Int, version: UInt64)
    }

    private var recognizer: PressRecognizer?
    private var target: Target?
    private var longPressTimer: Task<Void, Never>?
    private var highlight: CAShapeLayer?

    init(node: UltraNode) {
        self.node = node
        super.init(frame: .zero)
        isOpaque = false
        isMultipleTouchEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Hit testing

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        NodeHitTesting.point(point, isInside: self, props: props)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        NodeHitTesting.hitTest(point, in: self, props: props) { super.hitTest(point, with: event) }
    }

    // MARK: Presses

    private func target(at point: CGPoint) -> Target? {
        if let text = props?.text {
            for region in text.links where region.rects.contains(where: { $0.insetBy(dx: -4, dy: -4).contains(point) }) {
                return .link(index: region.index, version: text.version)
            }
        }
        return props?.isPressable == true ? .node : nil
    }

    private func isInside(_ point: CGPoint, for target: Target) -> Bool {
        let retention = PressRecognizer.retentionOffset
        switch target {
        case .node:
            let slop = props?.hitSlop ?? .zero
            return bounds.inset(by: UIEdgeInsets(
                top: -(slop.top + retention),
                left: -(slop.left + retention),
                bottom: -(slop.bottom + retention),
                right: -(slop.right + retention)
            )).contains(point)
        case .link(let index, _):
            let rects = props?.text?.links.first { $0.index == index }?.rects ?? []
            return rects.contains { $0.insetBy(dx: -retention, dy: -retention).contains(point) }
        }
    }

    private struct Handlers {
        var onPress: PressHandler?
        var onLongPress: PressHandler?
        var onPressIn: PressHandler?
        var onPressOut: PressHandler?
    }

    private func handlers(for target: Target) -> Handlers {
        switch target {
        case .node:
            guard let node else { return Handlers() }
            return Handlers(onPress: node.onPress, onLongPress: node.onLongPress, onPressIn: node.onPressIn, onPressOut: node.onPressOut)
        case .link(let index, let version):
            guard let span = (node as? UltraTextNode)?.link(at: index, version: version) else { return Handlers() }
            return Handlers(onPress: span.onPress, onLongPress: span.onLongPress)
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard recognizer == nil, let touch = touches.first, let target = target(at: touch.location(in: self)) else {
            super.touchesBegan(touches, with: event)
            return
        }
        beginPress(on: target)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let target, let touch = touches.first else {
            super.touchesMoved(touches, with: event)
            return
        }
        movePress(inside: isInside(touch.location(in: self), for: target))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let target, let touch = touches.first else {
            super.touchesEnded(touches, with: event)
            return
        }
        endPress(inside: isInside(touch.location(in: self), for: target))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard target != nil else {
            super.touchesCancelled(touches, with: event)
            return
        }
        cancelPress()
    }

    // Separate from the touch overrides so tests can drive them.

    /// Starts a press at `point` if something there handles presses.
    @discardableResult
    func beginPress(at point: CGPoint) -> Bool {
        guard recognizer == nil, let target = target(at: point) else { return false }
        beginPress(on: target)
        return true
    }

    private func beginPress(on target: Target) {
        var recognizer = PressRecognizer(handlesLongPress: handlers(for: target).onLongPress != nil)
        let events = recognizer.touchBegan()
        self.recognizer = recognizer
        self.target = target
        perform(events, on: target)
        longPressTimer?.cancel()
        longPressTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(PressRecognizer.longPressDelay))
            guard !Task.isCancelled else { return }
            self?.longPressTimerFired()
        }
    }

    func movePress(inside: Bool) {
        guard var recognizer, let target else { return }
        let events = recognizer.touchMoved(inside: inside)
        self.recognizer = recognizer
        perform(events, on: target)
    }

    func endPress(inside: Bool) {
        guard var recognizer, let target else { return }
        let events = recognizer.touchEnded(inside: inside)
        finishPress()
        perform(events, on: target)
    }

    func cancelPress() {
        guard var recognizer, let target else { return }
        let events = recognizer.touchCancelled()
        finishPress()
        perform(events, on: target)
    }

    func longPressTimerFired() {
        guard var recognizer, let target else { return }
        let events = recognizer.longPressTimerFired()
        self.recognizer = recognizer
        perform(events, on: target)
    }

    private func finishPress() {
        recognizer = nil
        target = nil
        longPressTimer?.cancel()
        longPressTimer = nil
    }

    private func perform(_ events: [PressRecognizer.Event], on target: Target) {
        let handlers = handlers(for: target)
        for event in events {
            switch event {
            case .pressIn:
                setPressed(true, target: target)
                handlers.onPressIn?()
            case .pressOut:
                setPressed(false, target: target)
                handlers.onPressOut?()
            case .press:
                handlers.onPress?()
            case .longPress:
                handlers.onLongPress?()
            }
        }
    }

    private var isPressed = false

    private func setPressed(_ pressed: Bool, target: Target) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        switch target {
        case .node:
            isPressed = pressed
            updatePressedAppearance()
        case .link(let index, _):
            highlight?.removeFromSuperlayer()
            highlight = nil
            guard pressed, props?.text?.highlightsPress == true,
                  let rects = props?.text?.links.first(where: { $0.index == index })?.rects
            else { return }
            let path = CGMutablePath()
            for rect in rects {
                path.addRoundedRect(in: rect.insetBy(dx: -2, dy: 0), cornerWidth: 3, cornerHeight: 3)
            }
            let layer = CAShapeLayer()
            layer.path = path
            layer.fillColor = UIColor(white: 0, alpha: 0.15).cgColor
            self.layer.addSublayer(layer)
            highlight = layer
        }
    }

    private func updatePressedAppearance() {
        let opacity = props?.opacity ?? 1
        if isPressed, let pressedOpacity = props?.pressedOpacity {
            alpha = pressedOpacity
        } else {
            alpha = opacity
        }
    }

    // MARK: Accessibility

    override func accessibilityActivate() -> Bool {
        guard let onPress = node?.onPress else { return false }
        onPress()
        return true
    }
}

/// Hit testing shared by every node view.
@MainActor
enum NodeHitTesting {
    static func point(_ point: CGPoint, isInside view: UIView, props: ViewProps?) -> Bool {
        let slop = props?.hitSlop ?? .zero
        return view.bounds.inset(by: UIEdgeInsets(top: -slop.top, left: -slop.left, bottom: -slop.bottom, right: -slop.right))
            .contains(point)
    }

    /// Applies `pointerEvents` to UIKit's own hit testing.
    static func hitTest(_ point: CGPoint, in view: UIView, props: ViewProps?, default hit: () -> UIView?) -> UIView? {
        switch props?.pointerEvents ?? .auto {
        case .auto:
            return hit()
        case .none:
            return nil
        case .boxNone:
            let result = hit()
            return result === view ? nil : result
        case .boxOnly:
            guard view.isUserInteractionEnabled, !view.isHidden, view.alpha > 0.01,
                  view.point(inside: point, with: nil) else { return nil }
            return view
        }
    }
}
#endif
