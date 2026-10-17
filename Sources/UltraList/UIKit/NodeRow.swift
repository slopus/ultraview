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
    private final class Prepared {
        let root: UltraNode
        let size: CGSize
        weak var host: NodeHostView?
        weak var owner: NodeRowView?
        init(root: UltraNode, size: CGSize) { self.root = root; self.size = size }
    }
    private var prepared: [PreparedKey: Prepared] = [:]

    public init(identity: String, revision: UInt64 = 0, pinsToBottomEdge: Bool = false, attachments: [String: any ListAttachment] = [:], environment: RenderEnvironment? = nil, measurer: any NodeRowMeasuring = NodeRowMeasurer(), makeNode: @escaping @Sendable () -> UltraNode) {
        self.identity = identity; self.revision = revision; self.pinsToBottomEdge = pinsToBottomEdge
        self.attachments = attachments; self.environment = environment; self.measurer = measurer; factory = makeNode
        measurementEnvironment = environment.map(environmentKey) ?? 0
    }
    public func measure(width: Double, environment: RenderEnvironment) async -> Double? {
        let resolved = self.environment ?? environment
        let key = PreparedKey(width: width, environment: environmentKey(resolved))
        if let ready = prepared[key] { return ready.size.height }
        let factory = factory, measurer = measurer
        let result = await Task.detached(priority: .userInitiated) {
            let root = factory()
            let size = await measurer.measure(root, width: width, environment: resolved)
            return (root, size)
        }.value
        guard result.1.height.isFinite, result.1.height >= 0 else { return nil }
        prepared[key] = Prepared(root: result.0, size: result.1)
        return result.1.height
    }
    public func makeView() -> ListRowView { NodeRowView(row: self) }
    public func apply(to view: ListRowView, transition: ListTransition) { (view as? NodeRowView)?.row = self }
    fileprivate func preparedNode(width: Double, environment: RenderEnvironment) -> UltraNode? { prepared[.init(width: width, environment: environmentKey(self.environment ?? environment))]?.root }
    fileprivate func host(width: Double, environment: RenderEnvironment, owner: NodeRowView) -> NodeHostView? {
        guard let ready = prepared[.init(width: width, environment: environmentKey(self.environment ?? environment))] else { return nil }
        let host: NodeHostView
        if let existing = ready.host {
            if ready.owner !== owner { ready.owner?.release(existing) }
            host = existing
        } else {
            host = NodeHostView(rootNode: ready.root)
            ready.host = host
        }
        ready.owner = owner
        return host
    }
}

@MainActor
fileprivate final class NodeRowView: ListRowView {
    var row: NodeRow
    private var displayedHost: NodeHostView?
    private var pendingHost: NodeHostView?
    private var preparing: (row: NodeRow, width: Double, environment: UInt64)?
    override var isDisplayReady: Bool { displayedHost != nil }
    init(row: NodeRow) { self.row = row; super.init(frame: .zero); clipsToBounds = true }
    fileprivate func release(_ host: NodeHostView) {
        if !host.isHidden, let snapshot = host.snapshotView(afterScreenUpdates: false) {
            snapshot.frame = host.frame; addSubview(snapshot)
        }
        if displayedHost === host { displayedHost = nil }
        if pendingHost === host { pendingHost = nil }
        host.onCommit = nil; host.removeFromSuperview()
    }
    private func showPreparedHost(_ host: NodeHostView) {
        guard pendingHost === host, host.hasContent else { return }
        // Keep the old tall content while the render server clips it down.
        // A short replacement would otherwise make the visible card jump.
        if let animation = layer.animation(forKey: "ultraview.list.height") as? CABasicAnimation,
           let from = animation.fromValue as? Double, let to = animation.toValue as? Double,
           from > to, let start = animation.value(forKey: "ultraviewStartTime") as? Double {
            let remaining = start + animation.duration / Double(animation.speed) - layer.convertTime(CACurrentMediaTime(), from: nil)
            if remaining > 0.001 {
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self, weak host] in
                    guard let self, let host else { return }; showPreparedHost(host)
                }
                return
            }
        }
        displayedHost?.removeFromSuperview()
        displayedHost = host; pendingHost = nil
        host.frame = bounds; host.isHidden = false
        reportDisplayReady()
    }
    override func applyMeasurement(width: Double, height: Double, environment: RenderEnvironment) {
        guard let root = row.preparedNode(width: width, environment: environment) else {
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
        if pendingHost?.rootNode !== root && displayedHost?.rootNode !== root {
            pendingHost?.removeFromSuperview()
            guard let host = row.host(width: width, environment: environment, owner: self) else { return }
            host.onCommit = { [weak self, weak host] in
                guard let self, let host else { return }
                showPreparedHost(host)
            }
            host.isHidden = true
            addSubview(host); pendingHost = host
            configureNodeRowHost(host, size: .init(width: width, height: height))
            if host.hasContent { showPreparedHost(host) }
        } else if displayedHost?.rootNode === root {
            pendingHost?.removeFromSuperview(); pendingHost = nil
        }
        if let displayedHost { displayedHost.frame = .init(x: 0, y: 0, width: width, height: pendingHost == nil ? height : max(height, displayedHost.bounds.height)) }
        pendingHost?.frame = .init(x: 0, y: 0, width: width, height: height)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if let displayedHost {
            var frame = bounds
            if pendingHost != nil { frame.size.height = max(frame.height, displayedHost.bounds.height) }
            displayedHost.frame = frame
        }
        pendingHost?.frame = bounds
    }
}
#endif