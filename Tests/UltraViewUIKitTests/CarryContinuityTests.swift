#if canImport(UIKit)
import UIKit
import QuartzCore
import Testing
@testable import UltraList

private struct CarryRow: ListRow {
    var identity: String
    var revision: UInt64 = 0
    var height: Double
    var inverted: Bool
    func makeView() -> ListRowView { CarryView() }
    func apply(to view: ListRowView, transition: ListTransition) {
        (view as? CarryView)?.identity = identity
        (view as? CarryView)?.height = height
        view.transform = inverted ? .init(scaleX: 1, y: -1) : .identity
    }
}

private final class CarryView: ListRowView {
    var identity = ""
    var height = 100.0
    override func update(width: Double, transition: ListTransition) -> Double { height }
}

@MainActor
@Suite(.serialized) struct CarryContinuityTests {
    @Test(arguments: ScrollEngineMode.allCases, [5, 15])
    private func anOutgoingRowStaysBeyondItsLoadedNeighbour(mode: ScrollEngineMode, sendToken: Int) async throws {
        for inverted in [false, true] { try await check(mode: mode, sendToken: sendToken, inverted: inverted) }
    }

    private func check(mode: ScrollEngineMode, sendToken: Int, inverted: Bool) async throws {
        let window = makeWindow()
        window.frame = .init(x: 0, y: 0, width: 390, height: 600)
        let list = UltraListView(engineMode: mode)
        list.frame = window.bounds
        list.contentView.transform = inverted ? .init(scaleX: 1, y: -1) : .identity
        window.addSubview(list); window.isHidden = false
        defer { window.isHidden = true }
        list.layoutIfNeeded()
        var rows = (0..<60).map { CarryRow(identity: String($0), height: [92.0, 116, 140][$0 % 3], inverted: inverted) }
        list.applyChanges(items: rows, newInsets: .init(top: 360), transition: .none)
        list.layer.speed = 0; list.layer.timeOffset = 100
        rows.insert(.init(identity: "stream", height: 84, inverted: inverted), at: 0)
        list.applyChanges(items: rows, scrollTo: .init(index: 0), transition: .easeInOut(0.3))
        try await flush()
        var sampledCarriesAfterSend = 0
        for token in 1...25 {
            list.layer.timeOffset = 100 + Double(token) / 10
            try await flush()
            if token == sendToken {
                rows.insert(.init(identity: "sent", height: 100, inverted: inverted), at: 0)
                list.applyChanges(items: rows, scrollTo: .init(index: 0), animatesInsertions: false, transition: .easeInOut(0.3))
                try await flush()
            }
            let stream = rows.firstIndex { $0.identity == "stream" }!
            rows[stream].revision += 1
            if token % 4 == 0 { rows[stream].height += 20 }
            list.applyChanges(items: rows, anchorMode: .preserveVisibleContent, transition: .easeInOut(0.2))
            try await flush()
            let loaded = Set(list.loadedItemViews.map(ObjectIdentifier.init))
            var all: [CarryView] = []
            func inspect(_ view: UIView) {
                if let row = view as? CarryView { all.append(row) }
                for child in view.subviews { inspect(child) }
            }
            inspect(list)
            let target = try #require(list.layer.presentation())
            func rectangle(_ view: UIView) throws -> CGRect {
                let layer = try #require(view.layer.presentation())
                return layer.convert(layer.bounds, to: target)
            }
            for outgoing in all where !loaded.contains(ObjectIdentifier(outgoing)) {
                let index = try #require(rows.firstIndex { $0.identity == outgoing.identity })
                guard index >= list.loadedIndexRange.upperBound, let neighbour = list.loadedItemViews.last else { continue }
                if token >= sendToken { sampledCarriesAfterSend += 1 }
                let rect = try rectangle(outgoing), edge = try rectangle(neighbour)
                let overlap = inverted ? rect.maxY - edge.minY : edge.maxY - rect.minY
                #expect(overlap <= 0.5,
                        "\(mode)/inverted=\(inverted), Send \(sendToken), token \(token): outgoing \(outgoing.identity) \(rect) overlaps loaded edge \(edge)")
            }
        }
        #expect(sampledCarriesAfterSend > 0, "\(mode)/inverted=\(inverted): no outgoing row was checked after Send")
    }

    private func flush() async throws {
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(35))
    }
}
#endif