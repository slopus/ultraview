import Dispatch
import Foundation
import Synchronization
import UltraLayout

/// The queues the pipeline runs on. Passes are serial, on one layout queue
/// shared by every tree, so a pass owns every shadow and Yoga node while it
/// runs. Drawing fans out over a concurrent display queue.
enum Pipeline {
    static let layoutQueue = DispatchQueue(label: "dev.ultraview.layout", qos: .userInitiated)
    static let displayQueue = DispatchQueue(label: "dev.ultraview.display", qos: .userInitiated, attributes: .concurrent)
}

/// What a host tells the pipeline about where its tree is shown.
public struct RenderEnvironment: Sendable, Equatable {
    /// Pixels per point. Frames are rounded to this grid and bitmaps are
    /// drawn at it.
    public var scale: CGFloat
    /// The system text size as a multiple of the default size.
    public var fontScale: CGFloat
    public var isDark: Bool
    public var isRightToLeft: Bool

    public init(scale: CGFloat = 2, fontScale: CGFloat = 1, isDark: Bool = false, isRightToLeft: Bool = false) {
        self.scale = scale
        self.fontScale = fontScale
        self.isDark = isDark
        self.isRightToLeft = isRightToLeft
    }
}

/// Runs the passes for one tree and hands each commit to a sink.
///
/// A pass, on the layout queue:
/// 1. syncs the nodes that changed (copying their state under their locks),
/// 2. runs Yoga, measuring text through the measurer,
/// 3. collects the frames that changed,
/// 4. assigns interface states (window, scroll ranges), mounting and
///    unmounting,
/// 5. resolves view properties for the nodes that changed,
/// 6. draws the bitmaps that went out of date on the display queue, and
/// 7. hands the commit to the sink.
final class Renderer: @unchecked Sendable {
    // @unchecked Sendable: `inputs` is a Mutex and the flags are atomics.
    // Everything else mutable is touched only on the layout queue.

    struct Inputs: Sendable, Equatable {
        /// The box the root is laid out in; `nil` axes are unbounded.
        var width: CGFloat?
        var height: CGFloat?
        var inWindow = false
        /// The interface state of nodes outside scroll nodes while the
        /// host isn't in a window. Empty drops every view and bitmap;
        /// `[.preload, .display]` keeps them, so the host shows its content
        /// in its first frame back in a window.
        var outsideWindow: InterfaceState = []
        var environment = RenderEnvironment()
        /// Bumped by every `update`; commits report the newest they reflect.
        var request: UInt64 = 0
    }

    let root: UltraNode
    let measurer: any TextMeasurer
    let rasterizer: any Rasterizer
    private let sink: @Sendable (Commit) -> Void
    private let inputs = Mutex(Inputs())
    private let passScheduled = Atomic<Bool>(false)
    private let automatic: Bool
    /// Passes run so far, for tests.
    let passCount = Atomic<Int>(0)

    // Layout queue only.
    private var generation: UInt64 = 0
    private var lastInputs: Inputs?
    private var lastServedRequest: UInt64 = 0
    /// The environment of the pass in progress, for text measurement.
    private(set) var environment = RenderEnvironment()

    /// `automatic: false` leaves passes to `runPassNow()`, for tests.
    init(
        root: UltraNode,
        measurer: any TextMeasurer,
        rasterizer: any Rasterizer,
        automatic: Bool = true,
        sink: @escaping @Sendable (Commit) -> Void
    ) {
        self.root = root
        self.measurer = measurer
        self.rasterizer = rasterizer
        self.automatic = automatic
        self.sink = sink
        root.state.withLock { state in
            precondition(state.parent == nil, "only a root node can be hosted")
            precondition(state.renderer == nil, "a node can be hosted only once at a time")
            state.renderer = self
        }
        setNeedsPass()
    }

    /// Stops this renderer from receiving the root's changes.
    func detach() {
        root.state.withLock { state in
            if state.renderer === self {
                state.renderer = nil
            }
        }
    }

    /// Changes the inputs and schedules a pass. Returns the request number a
    /// commit will carry once it reflects the change.
    @discardableResult
    func update(_ body: (inout Inputs) -> Void) -> UInt64 {
        let request = inputs.withLock { inputs -> UInt64 in
            body(&inputs)
            inputs.request += 1
            return inputs.request
        }
        // Straight to the layout queue, even from the main thread, and
        // coalesced with any pass already due.
        if automatic, !passScheduled.exchange(true, ordering: .sequentiallyConsistent) {
            Pipeline.layoutQueue.async { self.runPass() }
        }
        return request
    }

    var currentInputs: Inputs {
        inputs.withLock { $0 }
    }

    // MARK: Scheduling

    /// Schedules a pass unless one is already pending. Changes made on the
    /// main thread wait for the end of the current main-queue turn first, so
    /// everything changed in one event handler lands in one pass.
    func setNeedsPass() {
        guard automatic, !passScheduled.exchange(true, ordering: .sequentiallyConsistent) else { return }
        if Thread.isMainThread {
            DispatchQueue.main.async {
                Pipeline.layoutQueue.async { self.runPass() }
            }
        } else {
            Pipeline.layoutQueue.async { self.runPass() }
        }
    }

    /// Runs a pass on the layout queue and waits for it. Never call it on the
    /// main thread: the pass would run there.
    func runPassNow() {
        precondition(!Thread.isMainThread, "passes never run on the main thread")
        Pipeline.layoutQueue.sync { runPass() }
    }

    /// Waits until no pass is pending or running.
    ///
    /// The flag is read on the layout queue, where no pass is running: read
    /// anywhere else, a pass that just started has already cleared it.
    func waitUntilIdle() {
        while Pipeline.layoutQueue.sync(execute: { passScheduled.load(ordering: .sequentiallyConsistent) }) {
            // A pass is due: queued behind us, or still hopping through the
            // main queue.
        }
    }

    // MARK: The pass

    func runPass() {
        dispatchPrecondition(condition: .onQueue(Pipeline.layoutQueue))
        passScheduled.store(false, ordering: .sequentiallyConsistent)
        guard root.state.withLock({ $0.renderer === self }) else { return }
        Signposts.interval("Pass") { runPassSteps() }
    }

    private func runPassSteps() {
        Diagnostics.shared.recordPass()
        passCount.add(1, ordering: .relaxed)

        let inputs = self.inputs.withLock { $0 }
        // A host supplies both dimensions before its first useful pass. In
        // particular, entering a window must not draw an unbounded scroll tree.
        guard !automatic || (inputs.width != nil && inputs.height != nil) else { return }
        let previous = lastInputs
        lastInputs = inputs
        environment = inputs.environment
        generation += 1
        let firstPass = previous == nil
        let environmentChanged = previous?.environment != inputs.environment
        let pass = Pass(
            generation: generation,
            inputs: inputs,
            environmentChanged: environmentChanged,
            config: LayoutConfig.shared(pointScaleFactor: inputs.environment.scale)
        )
        #if canImport(UIKit)
        pass.measuresTextInParallel = measurer is CoreTextMeasurer
        #endif

        // 1. Sync.
        Signposts.interval("Sync") {
            if firstPass {
                attach(root, parent: nil, pass: pass)
            }
            sync(root, forced: firstPass || environmentChanged, pass: pass)
            if previous?.width != inputs.width || previous?.height != inputs.height, let state = root.shadow.snapshot {
                root.shadow.layout.style = layoutStyle(for: root, state: state, inputs: inputs)
            }
        }

        // 2. Layout.
        Signposts.interval("Text") { prepareText(pass) }
        Signposts.interval("Layout") {
            root.shadow.layout.calculateLayout(
                width: inputs.width,
                height: inputs.height,
                direction: inputs.environment.isRightToLeft ? .rightToLeft : .leftToRight
            )
        }

        // 3. Frames.
        Signposts.interval("Frames") {
            collectFrames(root, force: firstPass || environmentChanged, pass: pass)
        }

        // 4. Interface states.
        Signposts.interval("Ranges") {
            if firstPass || environmentChanged || previous?.inWindow != inputs.inWindow
                || previous?.outsideWindow != inputs.outsideWindow {
                assignState(root, rootState(inputs), force: true, pass: pass)
            } else {
                for node in pass.attached where node.shadow.isAttached {
                    assignInheritedState(node, pass: pass)
                }
            }
            for scroll in pass.rangeUpdates where scroll.shadow.isAttached {
                updateRanges(scroll, force: false, pass: pass)
            }
        }

        // 5. Properties.
        Signposts.interval("Props") {
            var index = 0
            while index < pass.toEvaluate.count {
                evaluate(pass.toEvaluate[index], pass: pass)
                index += 1
            }
            for parent in pass.childrenChanged where parent.shadow.isMounted && parent.shadow.isAttached {
                let mounted = parent.shadow.children.filter { $0.shadow.isMounted }
                pass.commit.update(parent) { $0.children = mounted }
            }
        }

        // 6. Bitmaps.
        Signposts.interval("Draw") { draw(pass) }

        // 7. Hand over, marking what's on screen (for an unmount: what was):
        // the main thread applies that first.
        pass.commit.updateAll { entry in
            if entry.kind != .unmount {
                entry.isVisible = entry.node.shadow.interfaceState.contains(.visible)
            }
        }
        if !pass.commit.isEmpty || inputs.request > lastServedRequest {
            lastServedRequest = inputs.request
            sink(pass.commit)
        }
    }

    private func rootState(_ inputs: Inputs) -> InterfaceState {
        inputs.inWindow ? .all : inputs.outsideWindow
    }

    // MARK: 1. Sync

    private func sync(_ node: UltraNode, forced: Bool, pass: Pass) {
        let shadow = node.shadow
        let changed = node.needsSync.exchange(false, ordering: .sequentiallyConsistent)
        let descendantsChanged = node.descendantsNeedSync.exchange(false, ordering: .sequentiallyConsistent)
        if forced || changed {
            let current = node.state.withLock { $0 }
            let previous = shadow.snapshot
            shadow.snapshot = current
            shadow.renderer = self
            if forced {
                shadow.layout.config = pass.config
            }
            shadow.layout.style = layoutStyle(for: node, state: current, inputs: pass.inputs)
            node.syncContent(previous: previous, current: current, pass: pass)
            if forced || previous == nil || !Self.sameNodes(previous!.children, current.children) {
                reconcileChildren(of: node, with: current.children, pass: pass)
            }
            pass.evaluate(node)
        }
        if forced || descendantsChanged {
            for child in shadow.children where child.shadow.attachedInPass != pass.generation {
                sync(child, forced: forced, pass: pass)
            }
        }
    }

    /// The style Yoga gets for `node`. The root fills the host exactly
    /// along each axis the host gives a size for, rather than sizing to its
    /// content within it.
    private func layoutStyle(for node: UltraNode, state: NodeState, inputs: Inputs) -> LayoutStyle {
        var style = node.effectiveLayoutStyle(state)
        if node === root {
            if let width = inputs.width {
                style.width = .points(width)
            }
            if let height = inputs.height {
                style.height = .points(height)
            }
        }
        return style
    }

    private static func sameNodes(_ lhs: [UltraNode], _ rhs: [UltraNode]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0 === $1 }
    }

    private func reconcileChildren(of node: UltraNode, with children: [UltraNode], pass: Pass) {
        let shadow = node.shadow
        let kept = Set(children.map(ObjectIdentifier.init))
        for old in shadow.children where !kept.contains(ObjectIdentifier(old)) && old.shadow.parent === node {
            detach(old, pass: pass)
        }

        // Yoga's children follow the node's children exactly.
        let layoutChildren = children.map(\.shadow.layout)
        if !zip(shadow.layout.children, layoutChildren).allSatisfy({ $0 === $1 })
            || shadow.layout.children.count != layoutChildren.count {
            shadow.layout.removeAllChildren()
            for child in layoutChildren {
                child.removeFromParent()
                shadow.layout.addChild(child)
            }
        }

        let previous = shadow.children
        shadow.children = children
        for child in children where !(child.shadow.isAttached && child.shadow.parent === node) {
            attach(child, parent: node, pass: pass)
            sync(child, forced: true, pass: pass)
        }
        if !Self.sameNodes(previous, children) {
            pass.childrenDidChange(node)
        }
    }

    private func attach(_ node: UltraNode, parent: UltraNode?, pass: Pass) {
        let shadow = node.shadow
        if shadow.isAttached {
            // Moved from somewhere else, in this tree or another. The old
            // parent may not be synced in this pass: take the node out of
            // its list now. Another tree's own pass updates its views.
            let oldParent = shadow.parent
            detach(node, pass: pass)
            if let oldParent, oldParent !== parent {
                oldParent.shadow.children.removeAll { $0 === node }
                if oldParent.shadow.renderer === self {
                    pass.childrenDidChange(oldParent)
                }
            }
        }
        shadow.isAttached = true
        shadow.parent = parent
        shadow.renderer = self
        shadow.depth = (parent?.shadow.depth ?? -1) + 1
        shadow.attachedInPass = pass.generation
        if parent.map({ $0.shadow.attachedInPass != pass.generation }) ?? true {
            pass.attached.append(node)
        }
    }

    /// Takes a subtree out of the tree: views go, bitmaps are dropped, and
    /// drawing in flight is cancelled.
    private func detach(_ node: UltraNode, pass: Pass) {
        let shadow = node.shadow
        if shadow.isMounted {
            shadow.isMounted = false
            var entry = CommitEntry(kind: .unmount, node: node)
            entry.isVisible = shadow.interfaceState.contains(.visible)
            pass.commit.record(entry)
        }
        shadow.interfaceState = []
        node.publish([])
        shadow.contents = nil
        shadow.drawnKey = nil
        shadow.sentProps = nil
        shadow.sentFrame = nil
        shadow.isAttached = false
        shadow.parent = nil
        node.displaySentinel.add(1, ordering: .relaxed)
        for child in shadow.children where child.shadow.parent === node {
            detach(child, pass: pass)
            child.shadow.parent = node
        }
    }

    // MARK: 3. Frames

    private func collectFrames(_ node: UltraNode, force: Bool, pass: Pass) {
        let shadow = node.shadow
        guard force || shadow.layout.hasNewLayout else { return }
        shadow.layout.hasNewLayout = false
        let frame = shadow.layout.frame
        let padding = shadow.layout.resolvedPadding
        let border = shadow.layout.resolvedBorder
        let insets = Insets(
            top: padding.top + border.top,
            left: padding.left + border.left,
            bottom: padding.bottom + border.bottom,
            right: padding.right + border.right
        )
        if insets != shadow.contentInsets {
            // Content (text, drawn borders) moves inside an unchanged frame.
            shadow.contentInsets = insets
            pass.evaluate(node)
        }
        if frame != shadow.frame || force {
            shadow.frame = frame
            pass.evaluate(node)
            if let scroll = node as? UltraScrollNode {
                pass.needsRangeUpdate(scroll)
            }
            if node is ScrollContentNode, let scroll = shadow.parent as? UltraScrollNode {
                pass.needsRangeUpdate(scroll)
                pass.evaluate(scroll)
            }
            if let content = shadow.parent as? ScrollContentNode, let scroll = content.shadow.parent as? UltraScrollNode {
                pass.needsRangeUpdate(scroll)
            }
        }
        for child in shadow.children where child.shadow.parent === node {
            collectFrames(child, force: force, pass: pass)
        }
    }

    // MARK: 4. Interface states

    private func assignInheritedState(_ node: UltraNode, pass: Pass) {
        guard let parent = node.shadow.parent else {
            assignState(node, rootState(pass.inputs), force: true, pass: pass)
            return
        }
        if parent is ScrollContentNode, let scroll = parent.shadow.parent as? UltraScrollNode {
            pass.needsRangeUpdate(scroll)
        } else {
            assignState(node, parent.shadow.interfaceState, force: true, pass: pass)
        }
    }

    private func assignState(_ node: UltraNode, _ state: InterfaceState, force: Bool, pass: Pass) {
        let shadow = node.shadow
        let old = shadow.interfaceState
        guard force || old != state else { return }
        if old != state {
            transition(node, from: old, to: state, pass: pass)
        }
        if node is ScrollContentNode, let scroll = shadow.parent as? UltraScrollNode {
            updateRanges(scroll, force: force, pass: pass)
        } else {
            // A child moved away in this pass is the new parent's to assign.
            for child in shadow.children where child.shadow.parent === node {
                assignState(child, state, force: force, pass: pass)
            }
        }
    }

    private func updateRanges(_ scroll: UltraScrollNode, force: Bool, pass: Pass) {
        let content = scroll.contentNode
        guard content.shadow.parent === scroll else { return }
        let cap = content.shadow.interfaceState
        let configuration = scroll.shadow.snapshot?.scroll ?? ScrollConfiguration()
        let viewport = CGRect(
            x: scroll.shadow.contentOffset.x - content.shadow.frame.minX,
            y: scroll.shadow.contentOffset.y - content.shadow.frame.minY,
            width: scroll.shadow.frame.width,
            height: scroll.shadow.frame.height
        )
        for child in content.shadow.children where child.shadow.parent === content {
            let state = cap.isEmpty
                ? []
                : configuration.rangeTuning
                    .state(for: child.shadow.frame, viewport: viewport, horizontal: configuration.horizontal)
                    .intersection(cap)
            assignState(child, state, force: force, pass: pass)
        }
    }

    private func transition(_ node: UltraNode, from old: InterfaceState, to new: InterfaceState, pass: Pass) {
        let shadow = node.shadow
        shadow.interfaceState = new
        node.publish(new)

        let shouldMount = new.contains(.preload)
        if shouldMount && !shadow.isMounted {
            shadow.isMounted = true
            var entry = CommitEntry(kind: .mount, node: node)
            entry.parent = shadow.parent
            entry.depth = shadow.depth
            pass.commit.record(entry)
            pass.evaluate(node)
            if let parent = shadow.parent {
                pass.childrenDidChange(parent)
            }
        } else if !shouldMount && shadow.isMounted {
            shadow.isMounted = false
            shadow.sentProps = nil
            shadow.sentFrame = nil
            var entry = CommitEntry(kind: .unmount, node: node)
            entry.isVisible = old.contains(.visible)
            pass.commit.record(entry)
            if let parent = shadow.parent {
                pass.childrenDidChange(parent)
            }
        } else if shadow.isMounted && new.contains(.visible) != old.contains(.visible) {
            // The entry carries the node's visibility to the main thread,
            // which may still be holding back the node's mount.
            pass.commit.update(node) { _ in }
        }

        if new.contains(.display) && !old.contains(.display) {
            pass.evaluate(node)
        } else if !new.contains(.display) && old.contains(.display) {
            node.displaySentinel.add(1, ordering: .relaxed)
            let hadContents = shadow.contents != nil
            shadow.contents = nil
            shadow.drawnKey = nil
            if hadContents && shadow.isMounted {
                pass.commit.update(node) { $0.contents = .clear }
            }
        }
    }

    // MARK: 5. Properties

    private func evaluate(_ node: UltraNode, pass: Pass) {
        let shadow = node.shadow
        guard shadow.isAttached, let state = shadow.snapshot else { return }
        node.updateContentForFrame(pass: pass)
        guard shadow.isMounted else { return }

        let box = boxStyle(for: node, state: state, pass: pass)
        let props = makeProps(for: node, state: state, box: box, pass: pass)
        let frame = shadow.frame
        let isMounting = pass.commit.entry(for: node)?.kind == .mount
        if isMounting {
            pass.commit.update(node) { entry in
                entry.frame = frame
                entry.props = props
            }
        } else {
            let propsChanged = props != shadow.sentProps
            let frameChanged = frame != shadow.sentFrame
            if propsChanged || frameChanged {
                pass.commit.update(node) { entry in
                    if propsChanged { entry.props = props }
                    if frameChanged { entry.frame = frame }
                }
            }
        }
        shadow.sentProps = props
        shadow.sentFrame = frame

        guard shadow.interfaceState.contains(.display) else { return }
        let input = drawingInput(for: node, state: state, box: box, pass: pass)
        if input?.key != shadow.drawnKey {
            if let input {
                pass.drawJobs.append(DrawJob(
                    node: node,
                    drawing: input.drawing,
                    key: input.key,
                    sentinel: node.displaySentinel.load(ordering: .relaxed),
                    isVisible: shadow.interfaceState.contains(.visible)
                ))
            } else {
                shadow.drawnKey = nil
                if shadow.contents != nil {
                    shadow.contents = nil
                    pass.commit.update(node) { $0.contents = .clear }
                }
            }
        } else if isMounting, let contents = shadow.contents {
            pass.commit.update(node) { $0.contents = .set(contents) }
        }
    }

    private func boxStyle(for node: UltraNode, state: NodeState, pass: Pass) -> BoxStyle {
        BoxStyle(
            style: state.style,
            borderWidths: node.shadow.layout.resolvedBorder,
            size: node.shadow.frame.size,
            isDark: pass.environment.isDark,
            isRightToLeft: pass.environment.isRightToLeft
        )
    }

    private func makeProps(for node: UltraNode, state: NodeState, box: BoxStyle, pass: Pass) -> ViewProps {
        let style = state.style
        let size = node.shadow.frame.size
        var props = ViewProps()
        if box.isLayerRepresentable {
            props.backgroundColor = box.background
            props.cornerRadius = box.radii.uniformRadius ?? 0
            props.maskedCorners = box.radii.mask
            if box.hasBorder {
                props.borderWidth = box.widths.top
                props.borderColor = box.topColor
            }
        }
        props.opacity = style.opacity
        props.transform = Transform3D(style.transform)
        props.clipsToBounds = style.layout.overflow != .visible
        if let shadowColor = style.shadowColor, style.shadowOpacity > 0 {
            let hasOpaqueBox = box.isLayerRepresentable && !(box.background?.isClear ?? true)
            props.shadow = ShadowProps(
                color: shadowColor.resolved(dark: pass.environment.isDark),
                opacity: style.shadowOpacity,
                offset: style.shadowOffset,
                radius: style.shadowRadius,
                path: hasOpaqueBox ? RoundedRect(rect: CGRect(origin: .zero, size: size), cornerRadius: props.cornerRadius) : nil
            )
        }
        props.isHidden = style.layout.display == .none
        props.pointerEvents = style.pointerEvents
        props.hitSlop = style.hitSlop
        props.isPressable = !state.handlers.isEmpty
        props.pressedOpacity = state.pressedOpacity
        let accessibility = state.accessibility
        props.accessibility = AccessibilityProps(
            isElement: accessibility.isElement ?? (accessibility.label != nil || (accessibility.role.map { $0 != .none } ?? false)),
            label: accessibility.label,
            hint: accessibility.hint,
            role: accessibility.role,
            hidden: accessibility.hidden
        )
        node.contributeProps(&props, state: state, pass: pass)
        return props
    }

    private func drawingInput(for node: UltraNode, state: NodeState, box: BoxStyle, pass: Pass) -> (drawing: any Drawing, key: DrawingKey)? {
        let size = node.shadow.frame.size
        guard size.width > 0, size.height > 0 else { return nil }
        let drawnBox = box.isLayerRepresentable || box.isEmpty ? nil : box
        let content = node.contentDrawing(state: state)
        guard drawnBox != nil || content != nil else { return nil }
        return (
            NodeDrawing(box: drawnBox, content: content?.drawing),
            DrawingKey(size: size, scale: pass.environment.scale, box: drawnBox, content: content?.key ?? .none)
        )
    }

    // MARK: 6. Bitmaps

    private func prepareText(_ pass: Pass) {
        #if canImport(UIKit)
        guard let measurer = measurer as? CoreTextMeasurer else { return }
        // New text: build the attributed strings and typesetters, the
        // costly part of measuring, in parallel. Yoga then only breaks lines.
        if !pass.textSources.isEmpty {
            let sources = parallelWork(pass.textSources) { CoreTextSource($0.text) }
            for (preparation, source) in zip(pass.textSources, sources) {
                preparation.node.shadow.textSource = source
            }
        }
        guard !pass.textPreparations.isEmpty else { return }
        let scale = pass.environment.scale
        let layouts = parallelWork(pass.textPreparations) { preparation -> [TextLayout] in
            Diagnostics.shared.recordMeasurement()
            let measured = measurer.layout(preparation.text, maxWidth: preparation.width, scale: scale)
            // Text nodes often shrink to the measured glyph width. Prepare
            // that drawing width too, using the same attributed text/typesetter.
            if measured.size.width > 0, !measured.fits(width: measured.size.width) {
                Diagnostics.shared.recordMeasurement()
                return [measurer.layout(preparation.text, maxWidth: measured.size.width, scale: scale, reusing: measured), measured]
            }
            return [measured]
        }
        for (preparation, layouts) in zip(pass.textPreparations, layouts) {
            preparation.node.shadow.textLayouts = layouts
        }
        #endif
    }

    /// Draws every job concurrently on the display queue and waits for all
    /// of them. A job whose node changed or left meanwhile is dropped; the
    /// change already scheduled the pass that redraws it.
    private func draw(_ pass: Pass) {
        guard !pass.drawJobs.isEmpty else { return }
        let jobs = pass.drawJobs.filter(\.isVisible) + pass.drawJobs.filter { !$0.isVisible }
        let rasterizer = self.rasterizer
        let scale = pass.environment.scale
        let finished = parallelWork(jobs) { job -> Contents? in
            let isCancelled = { job.node.displaySentinel.load(ordering: .relaxed) != job.sentinel }
            guard !isCancelled() else { return nil }
            Diagnostics.shared.recordDraw()
            guard let contents = rasterizer.rasterize(job.drawing, size: job.key.size, scale: scale, isCancelled: isCancelled),
                  !isCancelled() else { return nil }
            return contents
        }
        for (index, job) in jobs.enumerated() {
            let shadow = job.node.shadow
            guard let contents = finished[index],
                  job.node.displaySentinel.load(ordering: .relaxed) == job.sentinel,
                  shadow.isMounted,
                  shadow.interfaceState.contains(.display)
            else { continue }
            shadow.contents = contents
            shadow.drawnKey = job.key
            pass.commit.update(job.node) { $0.contents = .set(contents) }
        }
    }
}

/// The state of one pass in progress. Layout queue only.
final class Pass {
    let generation: UInt64
    let inputs: Renderer.Inputs
    let environmentChanged: Bool
    let config: LayoutConfig
    var commit: Commit
    var measuresTextInParallel = false
    /// Text measured before at a known width: measured again in parallel.
    var textPreparations: [TextPreparation] = []
    /// New text: its typesetter is built in parallel before layout.
    var textSources: [TextPreparation] = []

    /// Nodes attached in this pass whose parents were already attached.
    var attached: [UltraNode] = []
    private(set) var toEvaluate: [UltraNode] = []
    private var evaluated = Set<ObjectIdentifier>()
    private(set) var childrenChanged: [UltraNode] = []
    private var childrenChangedSet = Set<ObjectIdentifier>()
    private(set) var rangeUpdates: [UltraScrollNode] = []
    private var rangeUpdateSet = Set<ObjectIdentifier>()
    var drawJobs: [DrawJob] = []

    var environment: RenderEnvironment { inputs.environment }

    init(generation: UInt64, inputs: Renderer.Inputs, environmentChanged: Bool, config: LayoutConfig) {
        self.generation = generation
        self.inputs = inputs
        self.environmentChanged = environmentChanged
        self.config = config
        commit = Commit(generation: generation, request: inputs.request)
    }

    /// Queues the node for step 5: its props, frame and bitmap are checked.
    func evaluate(_ node: UltraNode) {
        if evaluated.insert(ObjectIdentifier(node)).inserted {
            toEvaluate.append(node)
        }
    }

    func childrenDidChange(_ node: UltraNode) {
        if childrenChangedSet.insert(ObjectIdentifier(node)).inserted {
            childrenChanged.append(node)
        }
    }

    func needsRangeUpdate(_ scroll: UltraScrollNode) {
        if rangeUpdateSet.insert(ObjectIdentifier(scroll)).inserted {
            rangeUpdates.append(scroll)
        }
    }
}

struct DrawJob: Sendable {
    let node: UltraNode
    let drawing: any Drawing
    let key: DrawingKey
    /// The node's display sentinel when the job was made.
    let sentinel: UInt64
    let isVisible: Bool
}

struct TextPreparation: Sendable {
    let node: UltraTextNode
    let text: AttributedText
    let width: CGFloat?
}
