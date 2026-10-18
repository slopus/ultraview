#if canImport(UIKit)
import UIKit
import QuartzCore
import Testing
@testable import UltraList

private struct MotionRow: ListRow {
    var identity: String
    var revision: UInt64 = 0
    var height: Double = 100
    func makeView() -> ListRowView { MotionRowView() }
    func apply(to view: ListRowView, transition: ListTransition) { (view as? MotionRowView)?.height = height }
}

private final class MotionRowView: ListRowView {
    var height = 100.0
    override func update(width: Double, transition: ListTransition) -> Double { height }
}

private enum MotionSequence: String, CaseIterable {
    case resizeThenMove, moveThenResize, resizeThenResize, insertThenResize, resizeBelowThenMove
    case resizeMovedRowThenMove, moveThenResizeMovedRow, twoResizesThenMove
    case insertThenMoveAndResize
}

@MainActor
@Suite(.serialized) struct LayeredMotionTests {
    @Test(arguments: ScrollEngineMode.allCases, [0.0, 0.25, 0.5, 0.75])
    private func sizeAndMovementKeepTheirOwnClocks(mode: ScrollEngineMode, interruption: Double) async throws {
        for sequence in MotionSequence.allCases { try await check(sequence, mode: mode, interruption: interruption) }
    }

    private func check(_ sequence: MotionSequence, mode: ScrollEngineMode, interruption: Double) async throws {
        let window = makeWindow()
        window.frame = .init(x: 0, y: 0, width: 320, height: 900)
        let list = UltraListView(engineMode: mode)
        list.frame = window.bounds; window.addSubview(list); window.isHidden = false
        defer { window.isHidden = true }
        list.layoutIfNeeded()
        var rows = (0..<30).map { MotionRow(identity: String($0)) }
        list.applyChanges(items: rows, transition: .none)
        list.layer.speed = 0; list.layer.timeOffset = 100
        let transition = ListTransition(duration: 1, curve: .linear)
        let source = sequence == .resizeBelowThenMove || sequence == .insertThenMoveAndResize ? "6"
            : (sequence == .resizeMovedRowThenMove || sequence == .moveThenResizeMovedRow ? "1" : "0")
        func resize(_ height: Double) {
            let index = rows.firstIndex { $0.identity == source }!
            rows[index].height = height; rows[index].revision += 1
        }
        func move() {
            let row = rows.remove(at: rows.firstIndex { $0.identity == "1" }!)
            rows.insert(row, at: rows.firstIndex { $0.identity == "5" }! + 1)
        }
        switch sequence {
        case .resizeThenMove, .resizeThenResize, .resizeBelowThenMove, .resizeMovedRowThenMove, .twoResizesThenMove: resize(240)
        case .moveThenResize, .moveThenResizeMovedRow: move()
        case .insertThenResize, .insertThenMoveAndResize: rows.insert(.init(identity: "inserted"), at: 0)
        }
        list.applyChanges(items: rows, transition: transition)
        try await flush()
        advance(list, to: 100 + interruption); try await flush()
        let sourceView = try #require(list.loadedItemView(at: rows.firstIndex { $0.identity == source }!))
        let sizeBefore = sourceView.layer.animation(forKey: "ultraview.list.height")
        var movesBefore: [String: CAAnimation] = [:]
        if sequence == .insertThenMoveAndResize {
            for identity in ["6", "7"] {
                let view = try #require(list.loadedItemView(at: rows.firstIndex { $0.identity == identity }!))
                let animation: CAAnimation = try #require(view.layer.animation(forKey: "ultraview.list.positionY"))
                movesBefore[identity] = animation
            }
        }
        switch sequence {
        case .resizeThenMove, .resizeBelowThenMove, .resizeMovedRowThenMove: move()
        case .moveThenResize, .insertThenResize, .moveThenResizeMovedRow: resize(240)
        case .resizeThenResize: resize(88)
        case .twoResizesThenMove:
            rows[6].height = 180; rows[6].revision += 1; move()
        case .insertThenMoveAndResize: move(); resize(240)
        }
        list.applyChanges(items: rows, transition: transition)
        for (identity, before) in movesBefore {
            let view = try #require(list.loadedItemView(at: rows.firstIndex { $0.identity == identity }!))
            let after = try #require(view.layer.animation(forKey: "ultraview.list.positionY"))
            #expect(after.beginTime == before.beginTime && after.duration == before.duration,
                    "\(mode)/\(sequence)/\(interruption): unrelated movement changed row \(identity)'s existing clock")
            #expect((after.value(forKey: "ultraviewGeneration") as? NSNumber) == (before.value(forKey: "ultraviewGeneration") as? NSNumber))
        }
        if sequence == .resizeThenMove || sequence == .resizeBelowThenMove || sequence == .resizeMovedRowThenMove || sequence == .twoResizesThenMove {
            let before = try #require(sizeBefore), after = try #require(sourceView.layer.animation(forKey: "ultraview.list.height"))
            #expect(after.beginTime == before.beginTime && after.duration == before.duration,
                    "\(mode)/\(sequence)/\(interruption): a move changed the height clock")
            #expect((after.value(forKey: "ultraviewGeneration") as? NSNumber) == (before.value(forKey: "ultraviewGeneration") as? NSNumber),
                    "\(mode)/\(sequence)/\(interruption): a move replaced the height track")
        }
        let times = [interruption, interruption + 0.125, interruption + 0.25, interruption + 0.5, 1, interruption + 0.75, interruption + 1].sorted()
        for phase in times {
            advance(list, to: 100 + phase); try await flush()
            var frames: [String: CGRect] = [:]
            for identity in ["0", "1", "2", "3", "4", "5", "6", "7"] {
                let index = try #require(rows.firstIndex { $0.identity == identity })
                let view = try #require(list.loadedItemView(at: index))
                let presentation = try #require(view.layer.presentation()), destination = try #require(list.layer.presentation())
                let frame = presentation.convert(presentation.bounds, to: destination)
                frames[identity] = frame
                let expected = expectedFrame(identity, sequence: sequence, phase: phase, interruption: interruption)
                #expect(abs(frame.minY - expected.minY) <= 0.5 && abs(frame.height - expected.height) <= 0.5,
                        "\(mode)/\(sequence)/\(interruption) at \(phase), row \(identity): \(frame), expected \(expected)")
            }
            for (upper, lower) in [("2", "3"), ("3", "4"), ("4", "5"), ("6", "7")] {
                let first = try #require(frames[upper]), second = try #require(frames[lower])
                #expect(abs(first.maxY - second.minY) <= 0.5,
                        "\(mode)/\(sequence)/\(interruption) at \(phase): seam \(upper)/\(lower) is \(second.minY - first.maxY)")
            }
        }
    }

    private func expectedFrame(_ identity: String, sequence: MotionSequence, phase: Double, interruption: Double) -> CGRect {
        let index = Int(identity)!, first = min(1, max(0, phase)), second = min(1, max(0, phase - interruption))
        var y = Double(index * 100), height = 100.0
        let source = sequence == .resizeBelowThenMove || sequence == .insertThenMoveAndResize ? 6
            : (sequence == .resizeMovedRowThenMove || sequence == .moveThenResizeMovedRow ? 1 : 0)
        let growth: Double
        switch sequence {
        case .resizeThenMove, .resizeBelowThenMove, .resizeMovedRowThenMove, .twoResizesThenMove: growth = 140 * first
        case .moveThenResize, .insertThenResize, .moveThenResizeMovedRow, .insertThenMoveAndResize: growth = 140 * second
        case .resizeThenResize:
            let start = 140 * interruption
            growth = start + (-12 - start) * second
        }
        if index == source { height += growth }
        if index > source { y += growth }
        if sequence == .resizeMovedRowThenMove {
            if index == 1 { y += 400 * second }
            else if (2...5).contains(index) {
                y = Double(index * 100) + 140 * interruption - (100 + 140 * interruption) * second
            }
        }
        if sequence == .moveThenResizeMovedRow {
            if index == 1 { y += 400 * first }
            else if (2...5).contains(index) { y = Double(index * 100) - 100 * first }
        }
        if sequence == .twoResizesThenMove {
            if index == 6 { height += 80 * second }
            if index > 6 { y += 80 * second }
        }
        if sequence == .insertThenResize || sequence == .insertThenMoveAndResize { y += 100 * first }
        if sequence == .resizeThenMove || sequence == .resizeBelowThenMove || sequence == .moveThenResize || sequence == .twoResizesThenMove || sequence == .insertThenMoveAndResize {
            let progress = sequence == .moveThenResize ? first : second
            if index == 1 { y += 400 * progress }
            else if (2...5).contains(index) { y -= 100 * progress }
        }
        if sequence == .insertThenMoveAndResize {
            // Rows given a new move resume their own displacement on the new
            // clock. The unchanged rows keep the insertion's original clock.
            if index == 1 { y = 600 + (100 + 100 * interruption - 600) * (1 - second) }
            else if (2...5).contains(index) { y = Double(index * 100) + 100 * interruption * (1 - second) }
        }
        return .init(x: 0, y: y, width: 320, height: height)
    }

    private func advance(_ list: UltraListView, to time: Double) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        list.layer.timeOffset = time; CATransaction.commit()
    }
    private func flush() async throws {
        CATransaction.flush(); try await Task.sleep(for: .milliseconds(35))
    }
}
#endif