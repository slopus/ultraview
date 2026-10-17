#if canImport(UIKit)
import QuartzCore
import Synchronization
import UIKit
import UltraLayout

/// Shows a node tree. The root is laid out to the host's bounds.
///
/// The main thread never waits for the pipeline. Commits are applied as they
/// arrive: a change of size, window or appearance only asks for a pass, and
/// the host keeps showing what it has until the pass's commit comes in.
/// Views for nodes on screen are created and removed in the turn their
/// commit arrives; views for nodes off screen (ahead in a scroll node, or
/// everything while the host is outside a window) a few at a time, within
/// `mountBudget` per frame.
///
/// While outside a window, a host that has a size keeps its views and
/// bitmaps, or prepares them before it first appears (see
/// `keepsContentOutsideWindow` and `prepare(size:)`), so that it shows its
/// content in its first frame in a window.
@MainActor
public final class NodeHostView: UIView {
    public let rootNode: UltraNode
    /// Main-thread cost of applying commits.
    public let statistics = CommitStatistics()

    /// Whether the host keeps views and bitmaps while it's outside a window:
    /// drawn ahead before it first appears, and kept when it leaves, so it
    /// shows its content in its first frame in a window. Turn it off for
    /// hosts that spend long out of a window, to give the memory back; they
    /// then show nothing for the first frames after they come back.
    public var keepsContentOutsideWindow = true {
        didSet {
            guard keepsContentOutsideWindow != oldValue else { return }
            let state = outsideWindowState
            renderer.update { $0.outsideWindow = state }
        }
    }

    /// Main-thread seconds per frame for creating and removing views of
    /// nodes that aren't on screen.
    public var mountBudget: TimeInterval = 0.004

    /// Called on the main thread after each commit is applied.
    public var onCommit: (@MainActor () -> Void)?

    /// Whether the host shows a layout for its current size: a commit made
    /// for that size has been applied (its on-screen part, at least).
    public private(set) var hasContent = false

    private let mailbox = CommitMailbox()
    private let link = HostLink()
    let renderer: Renderer
    private var queue = CommitQueue()
    private var frameLink: CADisplayLink?
    private var laidOutSize: CGSize?
    /// Main-thread seconds spent applying since the last frame.
    private var spentSinceFrame: CFTimeInterval = 0
    /// The request that set the current size.
    private var sizeRequest: UInt64 = .max

    public init(rootNode: UltraNode, measurer: (any TextMeasurer)? = nil, rasterizer: (any Rasterizer)? = nil) {
        self.rootNode = rootNode
        let mailbox = mailbox
        let link = link
        renderer = Renderer(
            root: rootNode,
            measurer: measurer ?? CoreTextMeasurer(),
            rasterizer: rasterizer ?? BitmapRasterizer()
        ) { commit in
            if mailbox.post(commit) {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        link.host?.commitArrived()
                    }
                }
            }
        }
        super.init(frame: .zero)
        link.host = self
        clipsToBounds = true
        let environment = currentEnvironment()
        let state = outsideWindowState
        renderer.update {
            $0.environment = environment
            $0.outsideWindow = state
        }
        registerForTraitChanges([
            UITraitPreferredContentSizeCategory.self,
            UITraitUserInterfaceStyle.self,
            UITraitDisplayScale.self,
            UITraitLayoutDirection.self,
        ]) { (host: NodeHostView, _: UITraitCollection) in
            host.environmentDidChange()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        renderer.detach()
        MainActor.assumeIsolated {
            frameLink?.invalidate()
            rootNode.unmountView()
        }
    }

    // MARK: Inputs

    public override func layoutSubviews() {
        super.layoutSubviews()
        setSize(bounds.size)
    }

    /// Lays the tree out at `size` and draws it ahead of time, before the
    /// host has that size or is in a window, so it shows its content as
    /// soon as it appears at that size. Returns at once; the work runs off
    /// the main thread and views are created within `mountBudget` per frame.
    public func prepare(size: CGSize) {
        setSize(size)
    }

    private func setSize(_ size: CGSize) {
        guard size != laidOutSize else { return }
        laidOutSize = size
        hasContent = false
        sizeRequest = renderer.update { inputs in
            inputs.width = size.width
            inputs.height = size.height
        }
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        let inWindow = window != nil
        let environment = currentEnvironment()
        renderer.update { inputs in
            inputs.inWindow = inWindow
            inputs.environment = environment
        }
    }

    private var outsideWindowState: InterfaceState {
        keepsContentOutsideWindow ? [.preload, .display] : []
    }

    private func environmentDidChange() {
        let environment = currentEnvironment()
        renderer.update { $0.environment = environment }
    }

    private func currentEnvironment() -> RenderEnvironment {
        let traits = traitCollection
        let scale = traits.displayScale > 0 ? traits.displayScale : (window?.screen.scale ?? 3)
        return RenderEnvironment(
            scale: scale,
            fontScale: UIFontMetrics.default.scaledValue(for: 100, compatibleWith: traits) / 100,
            isDark: traits.userInterfaceStyle == .dark,
            isRightToLeft: effectiveUserInterfaceLayoutDirection == .rightToLeft
        )
    }

    // MARK: Commits

    /// Applies what is on screen at once; views off screen wait for the
    /// next frame.
    private func commitArrived() {
        if let commit = mailbox.take() {
            queue.add(commit)
        }
        applyTurn(budget: 0, minimum: 0)
    }

    fileprivate func frame() {
        let budget = max(0, mountBudget - spentSinceFrame)
        spentSinceFrame = 0
        applyTurn(budget: budget, minimum: 1)
    }

    /// Applies what's queued: everything on screen, and views off screen
    /// while `budget` lasts (at least `minimum` of them). Leaves the rest
    /// for the next frames.
    private func applyTurn(budget: TimeInterval, minimum: Int) {
        guard let turn = queue.takeTurn() else {
            frameLink?.isPaused = true
            return
        }
        let start = CACurrentMediaTime()
        let applied = Signposts.mainInterval("Apply") {
            CommitApplier.apply(turn, in: self, until: start + budget, minimum: minimum)
        }
        queue.putBack(turn.later.dropFirst(applied), of: turn)
        let seconds = CACurrentMediaTime() - start
        spentSinceFrame += seconds
        let entries = turn.now.count + applied
        statistics.record(seconds: seconds, entries: entries)
        MainThreadMonitor.shared.note(String(
            format: "applied %d entries (%d of %d off screen) in %.1f ms",
            entries, applied, turn.later.count, seconds * 1000
        ))

        if queue.hasWork {
            startFrameLink()
        } else {
            frameLink?.isPaused = true
        }
        if turn.request >= sizeRequest {
            hasContent = true
        }
        onCommit?()
    }

    private func startFrameLink() {
        if let frameLink {
            frameLink.isPaused = false
            return
        }
        let frameLink = CADisplayLink(target: link, selector: #selector(HostLink.frame))
        frameLink.add(to: .main, forMode: .common)
        self.frameLink = frameLink
    }

    /// Waits until the pipeline is idle and applies everything it produced,
    /// with no budget. For tests: the waiting happens on a background thread.
    public func settle() async {
        let renderer = renderer
        await Task.detached { renderer.waitUntilIdle() }.value
        if let commit = mailbox.take() {
            queue.add(commit)
        }
        while queue.hasWork {
            applyTurn(budget: .infinity, minimum: 1)
        }
    }
}

/// Lets the commit sink, which runs on the layout queue, and the display
/// link reach the host on the main thread without keeping it alive.
private final class HostLink: NSObject, @unchecked Sendable {
    // @unchecked Sendable: `host` is set once on the main thread, before the
    // first commit can be posted, and read only on the main thread.
    weak var host: NodeHostView?

    @MainActor @objc func frame() {
        host?.frame()
    }
}

/// Main-thread milliseconds spent applying commits.
public final class CommitStatistics: Sendable {
    public struct Values: Sendable, Equatable {
        public var commits = 0
        public var lastMilliseconds: Double = 0
        public var averageMilliseconds: Double = 0
        public var maxMilliseconds: Double = 0
        public var lastEntries = 0
    }

    private let values = Mutex(Values())

    public var current: Values {
        values.withLock { $0 }
    }

    func record(seconds: Double, entries: Int) {
        let milliseconds = seconds * 1000
        values.withLock { values in
            values.commits += 1
            values.lastMilliseconds = milliseconds
            values.lastEntries = entries
            values.maxMilliseconds = max(values.maxMilliseconds, milliseconds)
            // A running average over roughly the last 60 commits.
            let weight = 1 / Double(min(values.commits, 60))
            values.averageMilliseconds += (milliseconds - values.averageMilliseconds) * weight
        }
    }

    public func reset() {
        values.withLock { $0 = Values() }
    }
}
#endif
