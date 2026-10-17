#if canImport(UIKit)
import UIKit
import UltraCore
import UltraLayout

/// Implementations measure an unhosted tree on its owning background queue.
public protocol NodeRowMeasuring: Sendable {
    func measure(_ root: UltraNode, width: CGFloat, environment: RenderEnvironment) async -> CGSize
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
    private let environment: RenderEnvironment
    private var prepared: [Double: (UltraNode, CGSize)] = [:]

    public init(identity: String, revision: UInt64 = 0, pinsToBottomEdge: Bool = false, attachments: [String: any ListAttachment] = [:], environment: RenderEnvironment = .init(), measurer: any NodeRowMeasuring, makeNode: @escaping @Sendable () -> UltraNode) {
        self.identity = identity; self.revision = revision; self.pinsToBottomEdge = pinsToBottomEdge
        self.attachments = attachments; self.environment = environment; self.measurer = measurer; factory = makeNode
        var hash = Hasher()
        hash.combine(Double(environment.scale)); hash.combine(Double(environment.fontScale))
        hash.combine(environment.isDark); hash.combine(environment.isRightToLeft)
        measurementEnvironment = UInt64(bitPattern: Int64(hash.finalize()))
    }
    public func measure(width: Double) async -> Double? {
        if let ready = prepared[width] { return ready.1.height }
        let factory = factory, measurer = measurer, environment = environment
        let result = await Task.detached(priority: .userInitiated) {
            let root = factory()
            let size = await measurer.measure(root, width: width, environment: environment)
            return (root, size)
        }.value
        guard result.1.height.isFinite, result.1.height >= 0 else { return nil }
        prepared[width] = result
        return result.1.height
    }
    public func makeView() -> ListRowView { NodeRowView(row: self) }
    public func apply(to view: ListRowView, transition: ListTransition) { (view as? NodeRowView)?.row = self }
    fileprivate func preparedNode(width: Double) -> UltraNode? { prepared[width]?.0 }
}

@MainActor
private final class NodeRowView: ListRowView {
    var row: NodeRow
    private var host: NodeHostView?
    init(row: NodeRow) { self.row = row; super.init(frame: .zero) }
    override func applyMeasurement(width: Double, height: Double) {
        guard let root = row.preparedNode(width: width) else { return }
        if host?.rootNode !== root {
            host?.removeFromSuperview()
            let host = NodeHostView(rootNode: root)
            configureNodeRowHost(host, size: .init(width: width, height: height))
            addSubview(host); self.host = host
        }
        host?.frame = .init(x: 0, y: 0, width: width, height: height)
    }
    override func layoutSubviews() { super.layoutSubviews(); host?.frame = bounds }
}
#endif