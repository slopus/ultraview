#if canImport(UIKit)
import QuartzCore
import Synchronization
import UIKit
import UltraLayout

/// Shows a node tree. The root is laid out to the host's bounds; views are
/// created for nodes once the host is in a window.
///
/// Commits from the pipeline are applied on the main thread as they arrive.
/// When the host first appears in a window, and whenever its size changes,
/// it waits (up to `firstCommitTimeout`) for the commit that reflects the new
/// state and applies it before returning from layout, so the first frame is
/// never blank. The waiting is the only thing the main thread does; the pass
/// itself runs on the pipeline's queues.
@MainActor
public final class NodeHostView: UIView {
    public let rootNode: UltraNode
    /// Main-thread cost of applying commits.
    public let statistics = CommitStatistics()
    /// How long layout may block waiting for the first commit at a new size.
    public var firstCommitTimeout: TimeInterval = 1

    private let mailbox = CommitMailbox()
    private let link = HostLink()
    let renderer: Renderer
    private var laidOutSize: CGSize?
    private var lastAppliedGeneration: UInt64 = 0

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
                        link.host?.applyPendingCommit()
                    }
                }
            }
        }
        super.init(frame: .zero)
        link.host = self
        clipsToBounds = true
        renderer.update { $0.environment = currentEnvironment() }
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
            rootNode.unmountView()
        }
    }

    // MARK: Inputs

    public override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        guard size != laidOutSize else { return }
        laidOutSize = size
        let request = renderer.update { inputs in
            inputs.width = size.width
            inputs.height = size.height
        }
        if window != nil {
            waitForCommit(serving: request)
        }
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        let inWindow = window != nil
        let environment = currentEnvironment()
        let request = renderer.update { inputs in
            inputs.inWindow = inWindow
            inputs.environment = environment
        }
        if inWindow, laidOutSize != nil {
            waitForCommit(serving: request)
        }
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

    /// Blocks until the pipeline has posted a commit reflecting `request`,
    /// then applies it. Gives up after `firstCommitTimeout`; the commit is
    /// then applied whenever it arrives.
    private func waitForCommit(serving request: UInt64) {
        let deadline = DispatchTime.now() + firstCommitTimeout
        while true {
            if let commit = mailbox.take(servingRequest: request) {
                apply(commit)
                return
            }
            guard mailbox.waitForPost(until: deadline) else { return }
        }
    }

    func applyPendingCommit() {
        if let commit = mailbox.take() {
            apply(commit)
        }
    }

    private func apply(_ commit: Commit) {
        guard commit.generation > lastAppliedGeneration else { return }
        lastAppliedGeneration = commit.generation
        let start = CACurrentMediaTime()
        CommitApplier.apply(commit, root: rootNode, in: self)
        statistics.record(seconds: CACurrentMediaTime() - start, entries: commit.entries.count)
    }

    /// Waits until the pipeline is idle and applies what it produced. For
    /// tests: the waiting happens on a background thread.
    public func settle() async {
        let renderer = renderer
        await Task.detached { renderer.waitUntilIdle() }.value
        applyPendingCommit()
    }
}

/// Lets the commit sink, which runs on the layout queue, reach the host on
/// the main thread without keeping it alive.
private final class HostLink: @unchecked Sendable {
    // @unchecked Sendable: `host` is set once on the main thread, before the
    // first commit can be posted, and read only on the main thread.
    weak var host: NodeHostView?
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
