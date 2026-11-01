#if canImport(UIKit)
import UIKit
import QuartzCore
import Synchronization
import UltraCore
import UltraLayout

/// Implementations measure an unhosted tree on its owning background queue.
public protocol NodeRowMeasuring: Sendable {
    func measure(_ root: UltraNode, width: CGFloat, environment: RenderEnvironment) async -> CGSize
}

public struct NodeRowMeasurer: NodeRowMeasuring {
    public init() {}
    public func measure(_ root: UltraNode, width: CGFloat, environment: RenderEnvironment) async -> CGSize {
        await NodeMeasurement.measure(root, width: width, environment: environment)
    }
}

@MainActor
fileprivate final class PreparedNodeContent: DisplayPreparedContent {
    let root: UltraNode
    let size: CGSize
    /// The row's width and environment, to draw at.
    private let width: Double
    private let environment: RenderEnvironment
    weak var host: NodeHostView?
    weak var owner: NodeRowView?
    /// Drawn ahead, outside a window, until a row view checks it out.
    var staged: NodeHostView?
    private var drawing: Task<Void, Never>?
    var hasLiveHost: Bool { host != nil }
    var isDisplayPrepared: Bool { (host ?? staged)?.isContentComplete == true }
    init(root: UltraNode, size: CGSize, width: Double, environment: RenderEnvironment) {
        self.root = root; self.size = size; self.width = width; self.environment = environment
    }
    func drawAhead() -> Task<Void, Never>? {
        let target: NodeHostView
        if let prepared = host ?? staged {
            guard !prepared.isContentComplete else { return nil }
            if let drawing { return drawing }
            target = prepared
        } else {
            target = NodeHostView(rootNode: root)
            staged = target
        }
        let measuredSize = CGSize(width: width, height: size.height), environment = environment
        let drawing = Task { [weak self] in
            // A checked-out host can have an imposed size, as in a horizontal
            // row. Read its model bounds when drawing starts, after any checkout.
            let size = self?.host === target ? target.bounds.size : measuredSize
            await target.prepareContent(size: size, environment: environment)
            self?.drawing = nil
        }
        self.drawing = drawing
        return drawing
    }
    /// Draws at the measured size with the pass queued at once, for a list
    /// that waits for the pipeline and then calls `applyDrawn()`.
    func drawNow() {
        let target = host ?? staged ?? NodeHostView(rootNode: root)
        if host == nil { staged = target }
        target.prepareNow(size: .init(width: width, height: size.height), environment: environment)
    }
    func applyDrawn() {
        (host ?? staged)?.applyArrivedCommits()
    }
    func checkout(owner: NodeRowView) -> NodeHostView {
        let result: NodeHostView
        if let host {
            if self.owner !== owner { self.owner?.release(host) }
            result = host
        } else {
            result = staged ?? NodeHostView(rootNode: root); host = result
        }
        staged = nil
        self.owner = owner
        return result
    }
}

/// A tree built and measured for an in-place preparation, which the main
/// thread waits for.
private final class InPlaceMeasurement: Sendable {
    private let measured = Mutex<(root: UltraNode, size: CGSize)?>(nil)
    private let done = DispatchSemaphore(value: 0)
    func finish(root: UltraNode, size: CGSize) {
        measured.withLock { $0 = (root, size) }
        done.signal()
    }
    var result: (root: UltraNode, size: CGSize)? { measured.withLock { $0 } }
    func wait(until deadline: DispatchTime) -> Bool {
        if measured.withLock({ $0 != nil }) { return true }
        return done.wait(timeout: deadline) == .success
    }
}

/// Creates node trees off main, measures ahead, and mounts only a prepared tree.
@MainActor
public final class NodeRow: ListRow {
    public let identity: String
    public let revision: UInt64
    public var pinsToBottomEdge: Bool
    public var attachments: [String: any ListAttachment]
    public var measuresAsynchronously: Bool { true }
    public let measurementEnvironment: UInt64
    /// Whether a new revision's nodes animate from where the shown
    /// revision's were, on the row's own timing (see `transitionKey`).
    ///
    /// Any node row draws a new revision before its pass applies when the
    /// identity is on screen, and its first content when the list will show
    /// it as soon as it's prepared (`ListPreparationHint.showsSoon`), so the
    /// content shows in the transaction that places or resizes the row.
    public let animatesContent: Bool
    /// How content animates in the first time this row is shown. A row with
    /// an appearance is drawn before its pass applies.
    public let appearance: NodeRowAppearance?
    /// The appearance plays once, the first time any view shows this row.
    var appearanceShown = false
    private let factory: @Sendable () -> UltraNode
    private let measurer: any NodeRowMeasuring
    private let environment: RenderEnvironment?
    private struct PreparedKey: Hashable { var width: Double; var environment: UInt64 }
    // The explicit measure/applyMeasurement API retains its legacy preparation.
    // Lists call prepare instead and own the returned content themselves.
    private var prepared: [PreparedKey: PreparedNodeContent] = [:]

    public init(identity: String, revision: UInt64 = 0, pinsToBottomEdge: Bool = false, attachments: [String: any ListAttachment] = [:], environment: RenderEnvironment? = nil, measurer: any NodeRowMeasuring = NodeRowMeasurer(), animatesContent: Bool = false, appearance: NodeRowAppearance? = nil, makeNode: @escaping @Sendable () -> UltraNode) {
        self.identity = identity; self.revision = revision; self.pinsToBottomEdge = pinsToBottomEdge
        self.animatesContent = animatesContent; self.appearance = appearance
        self.attachments = attachments; self.environment = environment; self.measurer = measurer; factory = makeNode
        measurementEnvironment = environment.map(environmentKey) ?? 0
    }
    public func measure(width: Double, environment: RenderEnvironment) async -> Double? {
        let resolved = self.environment ?? environment
        let key = PreparedKey(width: width, environment: environmentKey(resolved))
        if let ready = prepared[key] { return ready.size.height }
        guard let result = await prepare(width: width, environment: environment),
              let content = result.content as? PreparedNodeContent else { return nil }
        prepared[key] = content
        return result.height
    }
    public func prepare(width: Double, environment: RenderEnvironment) async -> ListPreparation? {
        let resolved = self.environment ?? environment
        let factory = factory, measurer = measurer
        let result = await Task.detached(priority: .userInitiated) {
            let root = factory()
            let size = await measurer.measure(root, width: width, environment: resolved)
            return (root, size)
        }.value
        guard result.1.height.isFinite, result.1.height >= 0 else { return nil }
        let content = PreparedNodeContent(root: result.0, size: result.1, width: width, environment: resolved)
        if animatesContent && appearance != nil && !appearanceShown || NodeRowLiveness.isLive(identity) || ListPreparationHint.showsSoon {
            // Drawn now, so the pass that shows it can swap in the same
            // transaction as its own geometry and animations.
            await content.drawAhead()?.value
        }
        return ListPreparation(height: result.1.height, content: content, hasFixedHeight: result.0.style.layout.hasFixedHeight)
    }
    /// Builds and measures the tree off the main thread, then draws it with
    /// its pass queued at once: the list waits for both.
    public func prepareInPlace(width: Double, environment: RenderEnvironment) -> ListInPlacePreparation? {
        let resolved = self.environment ?? environment
        let factory = factory, measurer = measurer
        let job = InPlaceMeasurement()
        Task.detached(priority: .high) {
            let root = factory()
            let size = await measurer.measure(root, width: width, environment: resolved)
            job.finish(root: root, size: size)
        }
        return ListInPlacePreparation(wait: { job.wait(until: $0) }, finish: {
            guard let measured = job.result, measured.size.height.isFinite, measured.size.height >= 0 else { return nil }
            let content = PreparedNodeContent(root: measured.root, size: measured.size, width: width, environment: resolved)
            content.drawNow()
            return ListPreparation(height: measured.size.height, content: content, hasFixedHeight: measured.root.style.layout.hasFixedHeight)
        })
    }
    public func makeView() -> ListRowView { NodeRowView(row: self) }
    public func apply(to view: ListRowView, transition: ListTransition) {
        guard let view = view as? NodeRowView else { return }
        view.row = self
        view.passTransition = transition
        if animatesContent { view.motion.passWillApply(transition) }
    }
    fileprivate func preparedContent(width: Double, environment: RenderEnvironment) -> PreparedNodeContent? {
        prepared[.init(width: width, environment: environmentKey(self.environment ?? environment))]
    }
}

@MainActor
fileprivate final class NodeRowView: ListRowView {
    var row: NodeRow
    private var displayedHost: NodeHostView?
    private var pendingHost: NodeHostView?
    private struct Candidate {
        var content: PreparedNodeContent
        var size: CGSize
    }
    private var pendingCandidate: Candidate?
    private var queuedCandidate: Candidate?
    private var displayedSize = CGSize.zero
    private var revealDeadline: Double?
    private var preparing: (row: NodeRow, width: Double, environment: UInt64)?
    /// What a host this view gave away showed, until this view shows a host again.
    private var releasedSnapshot: UIView?
    /// The transition of the list pass applying this row, until it ends.
    var passTransition: ListTransition?
    /// A shorter revision, ready inside a pass, waits for the pass's end:
    /// only then is the row's shrinking clip there to keep the old content for.
    private var awaitsPassEnd = false
    override var isDisplayReady: Bool { displayedHost != nil }
    let motion = NodeRowMotion()
    override class var layerClass: AnyClass { NodeRowLayer.self }
    init(row: NodeRow) {
        self.row = row; super.init(frame: .zero); clipsToBounds = true
        motion.view = self
        (layer as? NodeRowLayer)?.onAnimationAdded = { [weak self] animation, key in
            guard let self, self.row.animatesContent else { return }
            motion.rowDidAnimate(animation, key: key)
        }
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { NodeRowLiveness.add(self, identity: row.identity) }
        else { NodeRowLiveness.remove(self, identity: row.identity) }
    }
    fileprivate func release(_ host: NodeHostView) {
        guard displayedHost === host || pendingHost === host else { return }
        if !host.isHidden, let snapshot = host.snapshotView(afterScreenUpdates: false) {
            releasedSnapshot?.removeFromSuperview()
            snapshot.frame = host.frame; addSubview(snapshot); releasedSnapshot = snapshot
        }
        if displayedHost === host { displayedHost = nil }
        if pendingHost === host { pendingHost = nil; pendingCandidate = nil; revealDeadline = nil }
        queuedCandidate = nil
        host.onCommit = nil; host.removeFromSuperview()
    }
    private func showPreparedHost(_ host: NodeHostView) {
        guard pendingHost === host, host.hasContent else { return }
        if row.animatesContent {
            // The new nodes animate from where the old ones are; the row's
            // own clip follows its height.
            let old = displayedHost
            displayedSize = pendingCandidate?.size ?? host.bounds.size
            displayedHost = host; pendingHost = nil
            releasedSnapshot?.removeFromSuperview(); releasedSnapshot = nil
            pendingCandidate = nil; revealDeadline = nil
            host.clipsToBounds = false
            host.frame = .init(origin: .zero, size: displayedSize); host.isHidden = false
            let appearance = row.appearanceShown ? nil : row.appearance
            row.appearanceShown = true
            CATransaction.begin(); CATransaction.setDisableActions(true)
            motion.show(host, replacing: old, appearance: appearance)
            CATransaction.commit()
            old?.removeFromSuperview()
            reportDisplayReady()
            if let next = queuedCandidate {
                queuedCandidate = nil
                if next.content.root !== host.rootNode { start(next) }
            }
            return
        }
        // Content laid out at another width is worse to keep than a short
        // replacement: the list's width changed, so the new one shows now.
        let sameWidth = abs((pendingCandidate?.size.width ?? host.bounds.width) - displayedSize.width) <= 0.5 || displayedHost == nil
        if !sameWidth { revealDeadline = 0 }
        if revealDeadline == nil, let transition = passTransition, !transition.isImmediate, displayedHost != nil,
           (pendingCandidate?.size.height ?? host.bounds.height) < displayedSize.height {
            if !awaitsPassEnd {
                awaitsPassEnd = true
                DispatchQueue.main.async { [weak self] in self?.passDidEnd() }
            }
            return
        }
        // Keep the old tall content while the render server clips it down.
        // A short replacement would otherwise make the visible card jump.
        if revealDeadline == nil {
            if let animation = layer.animation(forKey: "ultraview.list.height") as? CABasicAnimation,
               let from = animation.fromValue as? Double, let to = animation.toValue as? Double,
               from > to, let start = animation.value(forKey: "ultraviewStartTime") as? Double {
                revealDeadline = start + animation.duration / Double(animation.speed)
            } else { revealDeadline = 0 }
        }
        let remaining = (revealDeadline ?? 0) - layer.convertTime(CACurrentMediaTime(), from: nil)
        if remaining > 0.001 {
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self, weak host] in
                guard let self, let host else { return }; showPreparedHost(host)
            }
            return
        }
        displayedHost?.removeFromSuperview()
        displayedSize = pendingCandidate?.size ?? host.bounds.size
        displayedHost = host; pendingHost = nil
        releasedSnapshot?.removeFromSuperview(); releasedSnapshot = nil
        pendingCandidate = nil; revealDeadline = nil
        host.frame = .init(origin: .zero, size: displayedSize); host.isHidden = false
        reportDisplayReady()
        if let next = queuedCandidate {
            queuedCandidate = nil
            if next.content.root !== host.rootNode { start(next) }
        }
    }
    private func start(_ candidate: Candidate) {
        let host = candidate.content.checkout(owner: self)
        pendingCandidate = candidate; revealDeadline = nil
        host.onCommit = { [weak self, weak host] in
            guard let self, let host else { return }
            showPreparedHost(host)
        }
        host.isHidden = true
        addSubview(host); pendingHost = host
        configureNodeRowHost(host, size: candidate.size)
        if host.hasContent { showPreparedHost(host) }
    }
    override func applyMeasurement(width: Double, height: Double, environment: RenderEnvironment) {
        guard let content = row.preparedContent(width: width, environment: environment) else {
            let key = environmentKey(environment)
            if let preparing, preparing.row === row, preparing.width == width, preparing.environment == key { return }
            let requested = row
            preparing = (requested, width, key)
            Task { [weak self] in
                let measured = await requested.measure(width: width, environment: environment)
                guard let self, row === requested, preparing?.row === requested,
                      preparing?.width == width, preparing?.environment == key else { return }
                preparing = nil
                if measured != nil { applyMeasurement(width: width, height: height, environment: environment) }
            }
            return
        }
        preparing = nil
        accept(content, width: width, height: height)
    }
    override func applyPreparation(_ preparation: ListPreparation, width: Double, environment: RenderEnvironment) {
        guard let content = preparation.content as? PreparedNodeContent else {
            super.applyPreparation(preparation, width: width, environment: environment); return
        }
        preparing = nil
        accept(content, width: width, height: preparation.height)
    }
    private func accept(_ content: PreparedNodeContent, width: Double, height: Double) {
        let root = content.root
        let candidate = Candidate(content: content, size: .init(width: width, height: height))
        if let pendingHost, let pending = pendingCandidate, pendingHost.rootNode !== root,
           abs(pending.size.width - width) > 0.5 {
            // The width changed again before the last one showed: that
            // content is already out of date.
            pendingHost.onCommit = nil; pendingHost.removeFromSuperview()
            self.pendingHost = nil; pendingCandidate = nil; queuedCandidate = nil; revealDeadline = nil
        }
        if let pendingHost {
            if pendingHost.rootNode !== root { queuedCandidate = candidate }
            else { queuedCandidate = nil }
        } else if displayedHost?.rootNode !== root {
            start(candidate)
        }
        setNeedsLayout()
    }
    override func visibleRectUpdated(_ rect: CGRect?) {
        if row.animatesContent { motion.passDidComplete() }
        passDidEnd()
    }
    private func passDidEnd() {
        passTransition = nil
        guard awaitsPassEnd else { return }
        awaitsPassEnd = false
        if let pendingHost { showPreparedHost(pendingHost) }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        // Content drawn for another width keeps its leading edge where it
        // was until its replacement shows: stretched, text and circles would
        // all change shape for those frames, and pinned, only what sits at
        // the trailing edge is out of place.
        let leading = effectiveUserInterfaceLayoutDirection == .rightToLeft ? bounds.width - displayedSize.width : 0
        displayedHost?.frame = .init(origin: .init(x: leading, y: 0), size: displayedSize)
        if let pendingCandidate { pendingHost?.frame = .init(origin: .zero, size: pendingCandidate.size) }
    }
}
#endif