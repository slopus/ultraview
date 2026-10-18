#if canImport(UIKit)
import UIKit
import QuartzCore
import Testing
import UltraCore
import UltraLayout
@testable import UltraList

@MainActor
private final class GeometryRow: ListRow {
    let node: NodeRow
    let imposedHeight: Double?
    private(set) var intrinsicHeight: Double?
    private(set) var content: (any ListPreparedContent)?
    var identity: String { node.identity }
    var measuresAsynchronously: Bool { true }
    init(identity: String, animatesContent: Bool, imposedHeight: Double?) {
        self.imposedHeight = imposedHeight
        node = NodeRow(identity: identity, animatesContent: animatesContent) {
            var fill = Style(); fill.flex = 1; fill.minHeight = 68; fill.backgroundColor = .indigo
            let child = UltraNode(style: fill); child.transitionKey = "fill"
            var root = Style(); root.padding = 12
            return UltraNode(style: root, children: [child])
        }
    }
    func makeView() -> ListRowView { node.makeView() }
    func apply(to view: ListRowView, transition: ListTransition) { node.apply(to: view, transition: transition) }
    func prepare(width: Double, environment: RenderEnvironment) async -> ListPreparation? {
        guard var preparation = await node.prepare(width: width, environment: environment) else { return nil }
        intrinsicHeight = preparation.height
        content = preparation.content
        if let imposedHeight { preparation.height = imposedHeight }
        return preparation
    }
}

@MainActor
@Suite(.serialized) struct PreparedHostGeometryTests {
    @Test(arguments: ScrollEngineMode.allCases, [(false, false), (false, true), (true, false), (true, true)])
    func aColdLiveHostRedrawsAtItsAppliedModelSize(mode: ScrollEngineMode, configuration: (Bool, Bool)) async throws {
        let (horizontal, animatesContent) = configuration
        let window = makeWindow()
        window.frame = .init(x: 0, y: 0, width: 390, height: 600)
        let row = GeometryRow(identity: "geometry-\(mode)-\(horizontal)-\(animatesContent)", animatesContent: animatesContent, imposedHeight: horizontal ? nil : 160)
        let list: UltraListView
        if horizontal {
            let strip = HorizontalListView(engineMode: mode)
            strip.frame = .init(x: 0, y: 0, width: 390, height: 176)
            window.addSubview(strip); strip.layoutIfNeeded()
            list = strip.list
        } else {
            list = UltraListView(engineMode: mode); list.frame = window.bounds
            window.addSubview(list); list.layoutIfNeeded()
        }
        window.isHidden = false
        defer { list.haltScrolling(); window.isHidden = true }
        // Prepare this exact content outside the list's eager-draw queue, then
        // check it out through the ordinary row adapter before requesting a draw.
        let displayed: any ListRow
        if horizontal { displayed = HorizontalRow(row, width: 148) }
        else { displayed = row }
        let prepared = await displayed.prepare(width: horizontal ? 160 : 390, environment: .init())
        let preparation = try #require(prepared)
        #expect(row.intrinsicHeight == 92)
        let rowView = displayed.makeView()
        displayed.apply(to: rowView, transition: .none)
        rowView.frame = .init(x: 0, y: 0, width: horizontal ? 160 : 390, height: horizontal ? 148 : 160)
        list.contentView.addSubview(rowView)
        rowView.applyPreparation(preparation, width: horizontal ? 160 : 390, environment: .init())
        rowView.layoutIfNeeded()
        var views: [UIView] = [rowView]
        var found: NodeHostView?
        while let view = views.popLast() {
            if let host = view as? NodeHostView { found = host; break }
            views += view.subviews
        }
        let host = try #require(found)
        let appliedSize = CGSize(width: horizontal ? 148 : 390, height: 160)
        let content = try #require(row.content)
        // Establish the imposed model geometry without starting PreparedContent's
        // draw task; no earlier draw can satisfy the drawAhead call below.
        await host.prepareContent(size: appliedSize, environment: .init())
        for _ in 0..<300 where !host.isContentComplete { try await Task.sleep(for: .milliseconds(5)) }
        window.layoutIfNeeded(); rowView.layoutIfNeeded(); host.layoutIfNeeded()
        #expect(host.bounds.size == appliedSize)
        #expect(host.view(forTransitionKey: "fill")?.bounds.height == 136)

        // An in-flight size animation has an earlier presentation height,
        // while a redraw must retain the applied model endpoint.
        let animation = CABasicAnimation(keyPath: "bounds.size.height")
        animation.fromValue = 92; animation.toValue = 160; animation.duration = 1
        host.layer.add(animation, forKey: "geometry-size")
        var committedFillHeights: [CGFloat] = []
        let previousCommit = host.onCommit
        host.onCommit = { [weak host] in
            if let height = host?.view(forTransitionKey: "fill")?.bounds.height { committedFillHeights.append(height) }
            previousCommit?()
        }
        defer { host.onCommit = previousCommit }
        // A prior preparation can be cold at another width while its checked-out
        // host already has its final bounds. Both widths have a 136-point fill.
        host.prepare(size: .init(width: appliedSize.width + 1, height: appliedSize.height))
        #expect(!host.hasContent)
        #expect(content.hasLiveHost)
        let drawing = try #require(content.drawAhead())
        await drawing.value
        for _ in 0..<300 where !host.isContentComplete { try await Task.sleep(for: .milliseconds(5)) }
        #expect(host.isContentComplete)
        #expect(host.bounds.size == appliedSize)
        // Keep any short commit even if a later UIKit layout repairs the host.
        let drawnFillHeight = try #require(committedFillHeights.min())
        print("HOST_GEOMETRY mode=\(mode) horizontal=\(horizontal) animates=\(animatesContent) intrinsic=\(row.intrinsicHeight ?? -1) imposed=\(host.bounds.height) drawnRoot=\(host.rootNode.view?.bounds.height ?? -1) drawnFills=\(committedFillHeights)")
        #expect(drawnFillHeight == 136)
        host.layer.removeAnimation(forKey: "geometry-size")
    }
}
#endif