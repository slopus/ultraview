#if canImport(UIKit)
import UIKit
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
    private var prepared: [PreparedKey: (UltraNode, CGSize)] = [:]

    public init(identity: String, revision: UInt64 = 0, pinsToBottomEdge: Bool = false, attachments: [String: any ListAttachment] = [:], environment: RenderEnvironment? = nil, measurer: any NodeRowMeasuring = NodeRowMeasurer(), makeNode: @escaping @Sendable () -> UltraNode) {
        self.identity = identity; self.revision = revision; self.pinsToBottomEdge = pinsToBottomEdge
        self.attachments = attachments; self.environment = environment; self.measurer = measurer; factory = makeNode
        measurementEnvironment = environment.map(environmentKey) ?? 0
    }
    public func measure(width: Double, environment: RenderEnvironment) async -> Double? {
        let resolved = self.environment ?? environment
        let key = PreparedKey(width: width, environment: environmentKey(resolved))
        if let ready = prepared[key] { return ready.1.height }
        let factory = factory, measurer = measurer
        let result = await Task.detached(priority: .userInitiated) {
            let root = factory()
            let size = await measurer.measure(root, width: width, environment: resolved)
            return (root, size)
        }.value
        guard result.1.height.isFinite, result.1.height >= 0 else { return nil }
        prepared[key] = result
        return result.1.height
    }
    public func makeView() -> ListRowView { NodeRowView(row: self) }
    public func apply(to view: ListRowView, transition: ListTransition) { (view as? NodeRowView)?.row = self }
    fileprivate func preparedNode(width: Double, environment: RenderEnvironment) -> UltraNode? { prepared[.init(width: width, environment: environmentKey(self.environment ?? environment))]?.0 }
}

@MainActor
private final class NodeRowView: ListRowView {
    var row: NodeRow
    private var displayedHost: NodeHostView?
    private var pendingHost: NodeHostView?
    override var isDisplayReady: Bool { displayedHost != nil }
    init(row: NodeRow) { self.row = row; super.init(frame: .zero) }
    override func applyMeasurement(width: Double, height: Double, environment: RenderEnvironment) {
        guard let root = row.preparedNode(width: width, environment: environment) else { return }
        if pendingHost?.rootNode !== root && displayedHost?.rootNode !== root {
            pendingHost?.removeFromSuperview()
            let host = NodeHostView(rootNode: root)
            host.onCommit = { [weak self, weak host] in
                guard let self, let host, pendingHost === host, host.hasContent else { return }
                displayedHost?.removeFromSuperview()
                displayedHost = host; pendingHost = nil
                host.isHidden = false
                reportDisplayReady()
            }
            host.isHidden = true
            addSubview(host); pendingHost = host
            configureNodeRowHost(host, size: .init(width: width, height: height))
        } else if displayedHost?.rootNode === root {
            pendingHost?.removeFromSuperview(); pendingHost = nil
        }
        for host in [displayedHost, pendingHost].compactMap({ $0 }) {
            host.frame = .init(x: 0, y: 0, width: width, height: height)
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        displayedHost?.frame = bounds; pendingHost?.frame = bounds
    }
}
#endif