#if canImport(UIKit)
import UIKit
import QuartzCore
import Testing
@testable import UltraList

private struct MountMotionRow: ListRow {
    var identity: String
    var revision: UInt64 = 0
    var height = 100.0
    func makeView() -> ListRowView { MountMotionRowView() }
    func apply(to view: ListRowView, transition: ListTransition) { (view as? MountMotionRowView)?.height = height }
}
private final class MountMotionRowView: ListRowView {
    var height = 100.0
    override func update(width: Double, transition: ListTransition) -> Double { height }
}
private enum MountMutation: CaseIterable {
    case deletion, insertion, resize, move, deletionThenResize, deletionThenImmediateResize
}
private enum UnloadedMutation: CaseIterable {
    case insertion, move
}

@MainActor
@Suite(.serialized) struct OffscreenMotionTests {
    @Test(arguments: ScrollEngineMode.allCases)
    func anIncomingWitnessKeepsTheCommitOriginAfterItsOwnTrackIsReplaced(mode: ScrollEngineMode) async throws {
        let window = makeWindow()
        window.frame = .init(x: 0, y: 0, width: 320, height: 300)
        let list = UltraListView(engineMode: mode)
        list.frame = window.bounds; list.preloadMargin = 0
        window.addSubview(list); window.isHidden = false
        defer { list.haltScrolling(); window.isHidden = true }
        list.layoutIfNeeded()
        var rows = (0..<30).map { MountMotionRow(identity: String($0)) }
        list.applyChanges(items: rows, transition: .none)
        try await flush()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rows.remove(at: 2)
        list.applyChanges(items: rows, transition: .init(duration: 1, curve: .linear))
        delayCommit()
        CATransaction.commit()
        try await flush()
        let incoming = try #require(list.loadedItemView(at: 2))
        let original = try #require(incoming.layer.animation(forKey: "ultraview.list.continuation"))
        let originalOrigin = list.layer.convertTime(original.beginTime, from: incoming.layer)
        list.setScrollOffset(list.currentScrollOffset + 100)
        list.handleScroll(list.currentScrollOffset)
        try await flush()
        let mounted = try #require(list.loadedItemView(at: 3))
        let inherited = try #require(mounted.layer.animation(forKey: "ultraview.list.continuation"))
        let inheritedOrigin = list.layer.convertTime(inherited.beginTime, from: mounted.layer)
        #expect(abs(inheritedOrigin - originalOrigin) <= 0.001,
                "\(mode): replacing an incoming witness moved later mounts to the pass clock")
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func aResizingSourceCanMoveAcrossTheMountedInterval(mode: ScrollEngineMode) async throws {
        let window = (UIWindow.self as NSObject.Type).init() as! UIWindow
        window.frame = .init(x: 0, y: 0, width: 320, height: 300)
        let list = UltraListView(engineMode: mode)
        list.frame = window.bounds; list.preloadMargin = 0
        window.addSubview(list); window.isHidden = false
        defer { list.haltScrolling(); window.isHidden = true }
        list.layoutIfNeeded()
        var rows = (0..<30).map { MountMotionRow(identity: String($0)) }
        list.applyChanges(items: rows, transition: .none)
        list.layer.speed = 0; list.layer.timeOffset = 100
        let transition = ListTransition(duration: 1, curve: .linear)
        rows[2].height = 240; rows[2].revision += 1
        list.applyChanges(items: rows, transition: transition)
        try await flush()
        list.layer.timeOffset = 100.5
        try await flush()
        let moved = rows.remove(at: 2)
        rows.insert(moved, at: 8)
        list.applyChanges(items: rows, transition: transition)
        try await flush()
        #expect(!list.loadedIndexRange.contains(9))
        list.layer.timeOffset = 100.6
        try await flush()
        list.setScrollOffset(list.currentScrollOffset + 750)
        list.handleScroll(list.currentScrollOffset)
        try await flush()
        let mounted = try #require(list.loadedItemView(at: 9))
        for (phase, expected) in [(0.6, -56.0), (1.0, 0.0), (1.5, 0.0)] {
            list.layer.timeOffset = 100 + phase
            try await flush()
            let shown = try #require(shownFrame(mounted, in: list))
            let settled = try #require(list.settledFrame(at: 9))
            #expect(abs(shown.minY - settled.minY - expected) <= 0.5,
                    "\(mode) at \(phase): crossing a resizing source changed the row's own movement")
        }
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func aResizeAlreadyRunningAtTheStructuralPassIsNotCountedTwice(mode: ScrollEngineMode) async throws {
        let window = (UIWindow.self as NSObject.Type).init() as! UIWindow
        window.frame = .init(x: 0, y: 0, width: 320, height: 300)
        let list = UltraListView(engineMode: mode)
        list.frame = window.bounds; list.preloadMargin = 0
        window.addSubview(list); window.isHidden = false
        defer { list.haltScrolling(); window.isHidden = true }
        list.layoutIfNeeded()
        var rows = (0..<30).map { MountMotionRow(identity: String($0)) }
        list.applyChanges(items: rows, transition: .none)
        list.layer.speed = 0; list.layer.timeOffset = 100
        let transition = ListTransition(duration: 1, curve: .linear)
        rows[2].height = 240; rows[2].revision += 1
        list.applyChanges(items: rows, transition: transition)
        try await flush()
        list.layer.timeOffset = 100.5
        try await flush()
        rows.remove(at: 0)
        list.applyChanges(items: rows, transition: transition)
        try await flush()
        #expect(!list.loadedIndexRange.contains(2))
        list.layer.timeOffset = 100.6
        try await flush()
        list.setScrollOffset(list.currentScrollOffset + 150)
        list.handleScroll(list.currentScrollOffset)
        try await flush()
        let mounted = try #require(list.loadedItemView(at: 2))
        for (phase, expected) in [(0.6, 34.0), (1.0, 50.0), (1.5, 0.0)] {
            list.layer.timeOffset = 100 + phase
            try await flush()
            let shown = try #require(shownFrame(mounted, in: list))
            let settled = try #require(list.settledFrame(at: 2))
            #expect(abs(shown.minY - settled.minY - expected) <= 0.5,
                    "\(mode) at \(phase): an older resize entered the structural clock twice")
        }
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func anImmediateOffscreenInsertKeepsTheRunningMountContinuation(mode: ScrollEngineMode) async throws {
        let window = (UIWindow.self as NSObject.Type).init() as! UIWindow
        window.frame = .init(x: 0, y: 0, width: 320, height: 300)
        let list = UltraListView(engineMode: mode)
        list.frame = window.bounds; list.preloadMargin = 0
        window.addSubview(list); window.isHidden = false
        defer { list.haltScrolling(); window.isHidden = true }
        list.layoutIfNeeded()
        var rows = (0..<30).map { MountMotionRow(identity: String($0)) }
        list.applyChanges(items: rows, transition: .none)
        list.layer.speed = 0; list.layer.timeOffset = 100
        rows.remove(at: 1)
        list.applyChanges(items: rows, transition: .init(duration: 1, curve: .linear))
        try await flush()
        list.layer.timeOffset = 100.25
        try await flush()
        rows.insert(.init(identity: "pagination"), at: 20)
        list.applyChanges(items: rows, transition: .none)
        try await flush()
        let oldRange = list.loadedIndexRange
        list.layer.timeOffset = 100.3
        try await flush()
        list.setScrollOffset(list.currentScrollOffset + 150)
        list.handleScroll(list.currentScrollOffset)
        try await flush()
        let newIndex = try #require(list.loadedIndexRange.first { !oldRange.contains($0) })
        let mounted = try #require(list.loadedItemView(at: newIndex))
        let shown = try #require(shownFrame(mounted, in: list))
        let settled = try #require(list.settledFrame(at: newIndex))
        #expect(abs(shown.minY - settled.minY - 70) <= 0.5,
                "\(mode): immediate pagination discarded the earlier running motion")
    }

    @Test(arguments: ScrollEngineMode.allCases, UnloadedMutation.allCases)
    private func aNeverLoadedMutationKeepsNewNeighboursTogether(mode: ScrollEngineMode, mutation: UnloadedMutation) async throws {
        let window = (UIWindow.self as NSObject.Type).init() as! UIWindow
        window.frame = .init(x: 0, y: 0, width: 320, height: 300)
        let list = UltraListView(engineMode: mode)
        list.frame = window.bounds; list.preloadMargin = 0
        window.addSubview(list); window.isHidden = false
        defer { list.haltScrolling(); window.isHidden = true }
        list.layoutIfNeeded()
        var rows = (0..<30).map { MountMotionRow(identity: String($0)) }
        list.applyChanges(items: rows, transition: .none)
        list.layer.speed = 0; list.layer.timeOffset = 100
        switch mutation {
        case .insertion: rows.insert(.init(identity: "new", height: 150), at: 8)
        case .move:
            let moved = rows.remove(at: 20)
            rows.insert(moved, at: 8)
        }
        list.applyChanges(items: rows, transition: .init(duration: 1, curve: .linear))
        try await flush()
        list.layer.timeOffset = 100.25
        try await flush()
        list.setScrollOffset(list.currentScrollOffset + 750)
        list.handleScroll(list.currentScrollOffset)
        try await flush()
        #expect(list.loadedIndexRange.contains(8) && list.loadedIndexRange.contains(9))
        for index in list.loadedIndexRange {
            let mounted = try #require(list.loadedItemView(at: index))
            let shown = try #require(shownFrame(mounted, in: list))
            let settled = try #require(list.settledFrame(at: index))
            #expect(abs(shown.minY - settled.minY) <= 0.5,
                    "\(mode)/\(mutation), row \(rows[index].identity): an unknown band split adjacent rows")
        }
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func sameTransactionMountsShareTheParticipantsNativeOrigin(mode: ScrollEngineMode) async throws {
        let window = (UIWindow.self as NSObject.Type).init() as! UIWindow
        window.frame = .init(x: 0, y: 0, width: 320, height: 300)
        let list = UltraListView(engineMode: mode)
        list.frame = window.bounds; list.preloadMargin = 500
        window.addSubview(list); window.isHidden = false
        defer { list.haltScrolling(); window.isHidden = true }
        list.layoutIfNeeded()
        var rows = (0..<30).map { MountMotionRow(identity: String($0)) }
        list.applyChanges(items: rows, transition: .none)
        try await flush()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let moved = rows.remove(at: 1)
        rows.insert(moved, at: 9)
        list.applyChanges(items: rows, transition: .init(duration: 1, curve: .linear))
        list.setScrollOffset(list.currentScrollOffset + 300)
        list.handleScroll(list.currentScrollOffset)
        delayCommit()
        CATransaction.commit()
        try await flush()
        let participant = try #require(list.loadedItemView(at: 1))
        let mounted = try #require(list.loadedItemView(at: 10))
        let original = try #require(participant.layer.animation(forKey: "ultraview.list.positionY"))
        let originalOrigin = list.layer.convertTime(original.beginTime, from: participant.layer)
        for key in ["ultraview.list.positionY", "ultraview.list.continuation"] {
            let inherited = try #require(mounted.layer.animation(forKey: key))
            let inheritedOrigin = list.layer.convertTime(inherited.beginTime, from: mounted.layer)
            #expect(abs(inheritedOrigin - originalOrigin) <= 0.001,
                    "\(mode)/\(key): a same-transaction mount started before its participant")
        }
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func aShortMutationKeepsAnOlderMovesMountWitness(mode: ScrollEngineMode) async throws {
        let window = (UIWindow.self as NSObject.Type).init() as! UIWindow
        window.frame = .init(x: 0, y: 0, width: 320, height: 300)
        let list = UltraListView(engineMode: mode)
        list.frame = window.bounds; list.preloadMargin = 0
        window.addSubview(list); window.isHidden = false
        defer { list.haltScrolling(); window.isHidden = true }
        list.layoutIfNeeded()
        var rows = (0..<30).map { MountMotionRow(identity: String($0)) }
        list.applyChanges(items: rows, transition: .none)
        list.layer.speed = 0; list.layer.timeOffset = 100
        rows.insert(.init(identity: "new", height: 150), at: 0)
        list.applyChanges(items: rows, transition: .init(duration: 2, curve: .linear))
        try await flush()
        list.layer.timeOffset = 100.2
        try await flush()
        rows.removeAll { $0.identity == "20" }
        list.applyChanges(items: rows, transition: .init(duration: 0.3, curve: .linear))
        try await flush()
        let oldRange = list.loadedIndexRange
        list.layer.timeOffset = 100.8
        try await flush()
        list.setScrollOffset(list.currentScrollOffset + 150)
        list.handleScroll(list.currentScrollOffset)
        try await flush()
        let newIndex = try #require(list.loadedIndexRange.first { !oldRange.contains($0) })
        let mounted = try #require(list.loadedItemView(at: newIndex))
        let shown = try #require(shownFrame(mounted, in: list))
        let settled = try #require(list.settledFrame(at: newIndex))
        #expect(abs(shown.minY - settled.minY + 90) <= 0.5,
                "\(mode): the short mutation expired while the inherited move was still running")
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func aLaterResizeStaysIndependentWhenTheMoveWitnessIsItsSource(mode: ScrollEngineMode) async throws {
        let window = (UIWindow.self as NSObject.Type).init() as! UIWindow
        window.frame = .init(x: 0, y: 0, width: 320, height: 300)
        let list = UltraListView(engineMode: mode)
        list.frame = window.bounds; list.preloadMargin = 0
        window.addSubview(list); window.isHidden = false
        defer { list.haltScrolling(); window.isHidden = true }
        list.layoutIfNeeded()
        var rows = (0..<30).map { MountMotionRow(identity: String($0)) }
        list.applyChanges(items: rows, transition: .none)
        list.layer.speed = 0; list.layer.timeOffset = 100
        let transition = ListTransition(duration: 1, curve: .linear)
        rows.remove(at: 1)
        list.applyChanges(items: rows, transition: transition)
        try await flush()
        list.layer.timeOffset = 100.2
        try await flush()
        rows[0].height = 600; rows[0].revision += 1
        list.applyChanges(items: rows, transition: transition)
        try await flush()
        #expect(list.loadedIndexRange == 0..<1)
        list.layer.timeOffset = 100.8
        try await flush()
        list.setScrollOffset(list.currentScrollOffset + 500)
        list.handleScroll(list.currentScrollOffset)
        try await flush()
        let mounted = try #require(list.loadedItemView(at: 1))
        for (phase, expected) in [(0.8, -180.0), (1.1, -50.0), (1.2, 0.0)] {
            list.layer.timeOffset = 100 + phase
            try await flush()
            let shown = try #require(shownFrame(mounted, in: list))
            let settled = try #require(list.settledFrame(at: 1))
            #expect(abs(shown.minY - settled.minY - expected) <= 0.5,
                    "\(mode) at \(phase): a later height clock entered the older move")
        }
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func aHeightClockKeepsItsOriginWhenItsSourceUnmounts(mode: ScrollEngineMode) async throws {
        let window = (UIWindow.self as NSObject.Type).init() as! UIWindow
        window.frame = .init(x: 0, y: 0, width: 320, height: 300)
        let list = UltraListView(engineMode: mode)
        list.frame = window.bounds; list.preloadMargin = 0
        window.addSubview(list); window.isHidden = false
        defer { list.haltScrolling(); window.isHidden = true }
        list.layoutIfNeeded()
        var rows = (0..<30).map { MountMotionRow(identity: String($0)) }
        list.applyChanges(items: rows, transition: .none)
        list.layer.speed = 0; list.layer.timeOffset = 100
        rows[0].height = 240; rows[0].revision += 1
        list.applyChanges(items: rows, transition: .init(duration: 1, curve: .linear))
        try await flush()
        let source = try #require(list.loadedItemView(at: 0))
        let height = try #require(source.layer.animation(forKey: "ultraview.list.height"))
        let expectedOrigin = list.layer.convertTime(height.beginTime, from: source.layer)
        let oldRange = list.loadedIndexRange
        list.layer.timeOffset = 100.4
        try await flush()
        list.setScrollOffset(list.currentScrollOffset + 250)
        list.handleScroll(list.currentScrollOffset)
        try await flush()
        #expect(!list.loadedIndexRange.contains(0))
        let newIndex = try #require(list.loadedIndexRange.first { !oldRange.contains($0) })
        let mounted = try #require(list.loadedItemView(at: newIndex))
        let follower = try #require(mounted.layer.animation(forKey: "ultraview.list.sizePosition.0"))
        let preservedOrigin = list.layer.convertTime(follower.beginTime, from: mounted.layer)
        #expect(abs(preservedOrigin - expectedOrigin) <= 1e-6,
                "\(mode): source clock moved from \(expectedOrigin) to \(preservedOrigin) when its view detached")
    }

    @Test(arguments: ScrollEngineMode.allCases, MountMutation.allCases)
    private func aNewlyMountedRowInheritsItsExistingMovement(mode: ScrollEngineMode, mutation: MountMutation) async throws {
        let window = (UIWindow.self as NSObject.Type).init() as! UIWindow
        window.frame = .init(x: 0, y: 0, width: 320, height: 300)
        let list = UltraListView(engineMode: mode)
        list.frame = window.bounds; list.preloadMargin = 0
        window.addSubview(list); window.isHidden = false
        defer { list.haltScrolling(); window.isHidden = true }
        list.layoutIfNeeded()
        var rows = (0..<30).map { MountMotionRow(identity: String($0)) }
        list.applyChanges(items: rows, transition: .none)
        let movedView = list.loadedItemView(at: 1)
        list.layer.speed = 0; list.layer.timeOffset = 100
        let transition = ListTransition(duration: 1, curve: .linear)
        switch mutation {
        case .deletion, .deletionThenResize, .deletionThenImmediateResize: rows.remove(at: 1)
        case .insertion: rows.insert(.init(identity: "new", height: 150), at: 1)
        case .resize: rows[0].height = 240; rows[0].revision += 1
        case .move:
            let moved = rows.remove(at: 1)
            rows.insert(moved, at: 5)
        }
        list.applyChanges(items: rows, transition: transition)
        try await flush()
        if mutation == .deletionThenResize || mutation == .deletionThenImmediateResize {
            list.layer.timeOffset = 100.2
            try await flush()
            rows[0].height = 240; rows[0].revision += 1
            list.applyChanges(items: rows, transition: mutation == .deletionThenImmediateResize ? .none : transition)
            try await flush()
        }
        let initialLoaded = list.loadedIndexRange
        for (step, phase) in [0.25, 0.5, 0.75, 1, 1.2].enumerated() {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            list.layer.timeOffset = 100 + phase
            CATransaction.commit()
            try await flush()
            let movedIndex = rows.firstIndex { $0.identity == "1" }
            let wasCarried = mutation == .move && movedIndex.map { !list.loadedIndexRange.contains($0) } == true
            let beforeMount = wasCarried ? shownFrame(movedView, in: list) : nil
            let scrollDistance = step == 0 ? 100.0 : 150.0
            list.setScrollOffset(list.currentScrollOffset + scrollDistance)
            list.handleScroll(list.currentScrollOffset)
            try await flush()
            #expect(list.loadedIndexRange.upperBound > initialLoaded.upperBound)
            for index in list.loadedIndexRange {
                guard let identity = Int(rows[index].identity) else { continue }
                let view = try #require(list.loadedItemView(at: index))
                let layer = try #require(view.layer.presentation()), destination = try #require(list.layer.presentation())
                let shown = layer.convert(layer.bounds, to: destination)
                let settled = try #require(list.settledFrame(at: index))
                if mutation == .move, identity == 1 {
                    if wasCarried, let beforeMount {
                        #expect(abs(shown.minY - (beforeMount.minY - scrollDistance)) <= 0.5,
                                "\(mode) moved row jumps when its slot mounts at \(phase)")
                    }
                    #expect(shown.minY <= settled.minY + 0.5)
                    if phase >= 1 { #expect(abs(shown.minY - settled.minY) <= 0.5) }
                    continue
                }
                let expected = residual(identity: identity, index: index, mutation: mutation, phase: phase)
                #expect(abs(shown.minY - settled.minY - expected) <= 0.5,
                        "\(mode)/\(mutation) at \(phase), row \(identity): residual \(shown.minY - settled.minY), expected \(expected)")
            }
        }
    }

    private func residual(identity: Int, index: Int, mutation: MountMutation, phase: Double) -> Double {
        let remaining = 1 - min(1, phase)
        switch mutation {
        case .deletion, .deletionThenImmediateResize: return identity > 1 ? 100 * remaining : 0
        case .insertion: return identity >= 1 ? -150 * remaining : 0
        case .resize: return identity > 0 ? -140 * remaining : 0
        case .move: return Double(identity - index) * 100 * remaining
        case .deletionThenResize:
            return (identity > 1 ? 100 * remaining : 0)
                - (identity > 0 ? 140 * (1 - min(1, max(0, phase - 0.2))) : 0)
        }
    }
    private func flush() async throws {
        CATransaction.flush(); try await Task.sleep(for: .milliseconds(35))
    }
    private func delayCommit() { Thread.sleep(forTimeInterval: 0.03) }
    private func shownFrame(_ view: ListRowView?, in list: UltraListView) -> CGRect? {
        guard let layer = view?.layer.presentation(), let destination = list.layer.presentation() else { return nil }
        return layer.convert(layer.bounds, to: destination)
    }
}
#endif