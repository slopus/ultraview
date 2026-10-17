import Foundation
import Testing
@testable import UltraList

@Suite struct MutationStressTests {
    @Test(arguments: [UInt64(7), 91, 643, 0xabcdef]) func mixedMutationScrollAndResize(seed: UInt64) {
        var random = seed, serial = 200
        var rows = (0..<200).map { (id: $0, height: 30.0 + Double($0 % 7) * 13) }
        var viewport = ListViewport(width: 320, height: 600)
        var anchor = 0
        func next(_ limit: Int) -> Int {
            random = random &* 6364136223846793005 &+ 1442695040888963407
            return Int((random >> 32) % UInt64(max(1, limit)))
        }
        for iteration in 0..<1500 {
            let oldIDs = rows.map(\.id)
            switch next(6) {
            case 0:
                serial += 1; rows.insert((serial, Double(next(250) + 1)), at: next(rows.count + 1))
            case 1: if rows.count > 1 { rows.remove(at: next(rows.count)) }
            case 2:
                let row = rows.remove(at: next(rows.count)); rows.insert(row, at: next(rows.count + 1))
            case 3: rows[next(rows.count)].height = Double(next(400))
            case 4: viewport.height = Double(200 + next(800)); viewport.insets.top = Double(next(300))
            default: anchor = next(rows.count)
            }
            anchor = min(anchor, rows.count - 1)
            let diff = ItemDiff(old: oldIDs, new: rows.map(\.id))
            for (old, new) in diff.survivors { #expect(oldIDs[old] == rows[new].id) }
            for move in diff.moves { #expect(oldIDs[move.old] == rows[move.new].id) }
            var window = ListWindow.build(count: rows.count, anchor: anchor, viewport: viewport, measure: { (rows[$0].height, 0, 0) }, resolveY: { _ in 0 })
            window.rebalance(count: rows.count, offsetInFrameSpace: Double(next(500) - 250), viewportHeight: viewport.height, measure: { (rows[$0].height, 0, 0) })
            #expect(!window.rows.isEmpty, "seed \(seed), iteration \(iteration)")
            #expect(window.range.lowerBound >= 0 && window.range.upperBound <= rows.count)
            for row in window.rows { #expect(row.y.isFinite && row.height == rows[row.index].height) }
            for (first, second) in zip(window.rows, window.rows.dropFirst()) {
                #expect(second.index == first.index + 1)
                #expect(abs(second.y - first.maxY) < 1e-8)
            }
        }
    }
    @Test func configurableSpringAndNoneRemainDeterministic() {
        let transition = ListTransition.spring(0.7, damping: 22)
        let track = AnimationTrack(generation: 1, from: 50, to: 140, startTime: 2, transition: transition)
        #expect(track.value(at: 2) == 50)
        #expect(track.value(at: 2.7) == 140)
        #expect(track.value(at: 2.35).isFinite)
        #expect(ListTransition.none.isImmediate)
        #expect(ListTransition.default != .none)
    }
    @Test func finiteEdgesFollowAStableNativeCoordinateBase() {
        let window = ListWindow(rows: [.init(index: 0, y: -200, height: 100), .init(index: 1, y: -100, height: 100)])
        let viewport = ListViewport(width: 320, height: 100, insets: .init(top: 20, bottom: 10))
        let first = window.edges(origin: 5000, count: 2, viewport: viewport)
        let shifted = window.edges(origin: 5073, count: 2, viewport: viewport)
        #expect(first.minimum == 4980 && first.maximum == 5110)
        #expect(shifted.minimum == first.minimum.map { $0 + 73 })
        #expect(shifted.maximum == first.maximum.map { $0 + 73 })
    }
}