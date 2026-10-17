#if canImport(UIKit)
import UIKit
import QuartzCore
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
fileprivate final class PreparedNodeContent: ListPreparedContent {
    let root: UltraNode
    let size: CGSize
    weak var host: NodeHostView?
    weak var owner: NodeRowView?
    var hasLiveHost: Bool { host != nil }
    init(root: UltraNode, size: CGSize) { self.root = root; self.size = size }
    func checkout(owner: NodeRowView) -> NodeHostView {
        let result: NodeHostView
        if let host {
            if self.owner !== owner { self.owner?.release(host) }
            result = host
        } else {
            result = NodeHostView(rootNode: root); host = result
        }
        self.owner = owner
        return result
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
    private let factory: @Sendable () -> UltraNode
    private let measurer: any NodeRowMeasuring
    private let environment: RenderEnvironment?
    private struct PreparedKey: Hashable { var width: Double; var environment: UInt64 }
    // The explicit measure/applyMeasurement API retains its legacy preparation.
    // Lists call prepare instead and own the returned content themselves.
    private var prepared: [PreparedKey: PreparedNodeContent] = [:]

    public init(identity: String, revision: UInt64 = 0, pinsToBottomEdge: Bool = false, attachments: [String: any ListAttachment] = [:], environment: RenderEnvironment? = nil, measurer: any NodeRowMeasuring = NodeRowMeasurer(), makeNode: @escaping @Sendable () -> UltraNode) {
        self.identity = identity; self.revision = revision; self.pinsToBottomEdge = pinsToBottomEdge
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
        return ListPreparation(height: result.1.height, content: PreparedNodeContent(root: result.0, size: result.1))
    }
    public func makeView() -> ListRowView { NodeRowView(row: self) }
    public func apply(to view: ListRowView, transition: ListTransition) { (view as? NodeRowView)?.row = self }
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
    override var isDisplayReady: Bool { displayedHost != nil }
    init(row: NodeRow) { self.row = row; super.init(frame: .zero); clipsToBounds = true }
    fileprivate func release(_ host: NodeHostView) {
        if !host.isHidden, let snapshot = host.snapshotView(afterScreenUpdates: false) {
            snapshot.frame = host.frame; addSubview(snapshot)
        }
        if displayedHost === host { displayedHost = nil }
        if pendingHost === host { pendingHost = nil; pendingCandidate = nil; revealDeadline = nil }
        queuedCandidate = nil
        host.onCommit = nil; host.removeFromSuperview()
    }
    private func showPreparedHost(_ host: NodeHostView) {
        guard pendingHost === host, host.hasContent else { return }
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
        if let pendingHost {
            if pendingHost.rootNode !== root { queuedCandidate = candidate }
            else { queuedCandidate = nil }
        } else if displayedHost?.rootNode !== root {
            start(candidate)
        }
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        displayedHost?.frame = .init(origin: .zero, size: displayedSize)
        if let pendingCandidate { pendingHost?.frame = .init(origin: .zero, size: pendingCandidate.size) }
    }
}
#endif