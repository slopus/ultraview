import Foundation
import Testing
@testable import UltraList

@Suite struct AdvancedGeometryTests {
    @Test func degenerateAttachmentBandClampsTowardFarEdge() {
        var map = AttachmentMap(low: 100, high: 60, height: 80, edge: .top, floating: true, screenAnchor: 20, contentBase: 0)
        #expect(map.position(offset: 0) == 60)
        map.edge = .bottom
        #expect(map.position(offset: 0) == 100)
    }
    @Test func floatingSolveAndFlightVerticesAgree() {
        let map = AttachmentMap(low: 0, high: 1000, height: 30, edge: .top, floating: true, screenAnchor: 20, contentBase: 0)
        #expect(map.position(offset: 100) - 100 == 20)
        var axis = ScrollAxis(); axis.release(velocity: 3)
        let flight = ScrollFlight(trajectory: .init(baking: axis), beginTime: 0, coordinateShift: 50)
        let values = map.flightValues(flight), settled = map.position(offset: flight.settledOffset)
        for (vertex, value) in zip(flight.trajectory.samples, values) {
            #expect(abs(settled + value - map.position(offset: vertex.offset + 50)) < 1e-9)
        }
        #expect(map.stickDistance(offset: 100) == 120)
    }
    @Test func yieldNeedsActualOverlapAndIsBaked() {
        var map = AttachmentMap(low: 0, high: 500, height: 20, edge: .top, floating: true, screenAnchor: 50, contentBase: 0)
        let far = AttachmentMap(low: 0, high: 500, height: 20, edge: .top, floating: true, screenAnchor: 0, contentBase: 0)
        map.partners = [far]; map.gap = 10
        #expect(map.position(offset: 100) == 150)
        map.partners[0].screenAnchor = 55
        #expect(map.position(offset: 100) == 145)
        var axis = ScrollAxis(); axis.release(velocity: 1)
        let flight = ScrollFlight(trajectory: .init(baking: axis), beginTime: 0, coordinateShift: 0)
        #expect(map.flightValues(flight) != AttachmentMap(low: 0, high: 500, height: 20, edge: .top, floating: true, screenAnchor: 50, contentBase: 0).flightValues(flight))
    }
    @Test func runSerialsSurviveClippingAndSplit() {
        let ids = (0..<10).map(String.init)
        var serial: UInt64 = 0
        let prior = AttachmentRuns.resolve(identities: ids, loaded: 0..<10, keys: { _ in ["a"] }, edge: { _, _ in .top }, combines: { _, _, _ in true }, prior: [], nextSerial: &serial)
        let clipped = AttachmentRuns.resolve(identities: ids, loaded: 3..<8, keys: { _ in ["a"] }, edge: { _, _ in .top }, combines: { _, _, _ in true }, prior: prior, nextSerial: &serial)
        #expect(!clipped[0].startsRun && !clipped[0].endsRun)
        let split = AttachmentRuns.resolve(identities: ids, loaded: 0..<10, keys: { _ in ["a"] }, edge: { _, _ in .top }, combines: { _, _, b in b != 5 }, prior: prior, nextSerial: &serial)
        #expect(split.count == 2 && split[0].serial == prior[0].serial)
        #expect(split[1].serial != split[0].serial)
    }
    @Test func ledgerRejectsCyclesAndRetainsEmptyWitnesses() {
        var ledger = DepartureLedger()
        ledger.insert(.init(id: 1, root: 100, localTop: 0, localBottom: 50, members: 1))
        ledger.insert(.init(id: 2, root: 150, localTop: 0, localBottom: 40, members: 1))
        let linked = ledger.link(2, to: .block(1, .bottom), edge: .top)
        let cycle = ledger.link(1, to: .block(2, .top), edge: .bottom)
        #expect(linked && !cycle)
        ledger.finishMember(1)
        #expect(ledger.collect().isEmpty)
        let targets = ledger.targets(rows: [:])
        #expect(targets[2] == 150)
        ledger.finishMember(2)
        #expect(ledger.collect() == [2, 1])
    }
    @Test func viewportBlocksCannotReattachAndSkipRebase() {
        var ledger = DepartureLedger()
        ledger.insert(.init(id: 1, root: 500, localTop: 0, localBottom: 50, members: 1))
        ledger.promoteToViewport(1, offset: 400); ledger.shift(by: 1000)
        let linked = ledger.link(1, to: .row("a", .top), edge: .bottom)
        #expect(!linked && ledger.blocks[1]?.root == 100)
    }
    @Test func crossingFallbackRetainsRigidSpacingAndClearsBand() {
        let endpoints = [CrossingPlanner.Endpoint(identity: "a", oldIndex: 0, newIndex: 0, y: 300, height: 50, outgoing: true), .init(identity: "b", oldIndex: 1, newIndex: 1, y: 350, height: 60, outgoing: true)]
        let plans = CrossingPlanner.infer(endpoints, samples: [], safeRange: -160...560, anchorY: 200)
        #expect(plans["a"] == 560 && plans["b"] == 610)
        let shared = CrossingPlanner.infer(endpoints, samples: [.init(oldIndex: 2, newIndex: 2, oldY: 400, newY: 500)], safeRange: -160...560, anchorY: 200)
        #expect(shared["a"] == 400 && shared["b"] == 450)
    }
    @Test func carouselStripsAreAdjacentInBothDirections() {
        for forward in [true, false] {
            let correction = ViewportTravel.carouselCorrection(oldStrip: -50...500, newStrip: -100...600, forward: forward)
            if forward { #expect(-100 - correction == 500) } else { #expect(600 - correction == -50) }
        }
        #expect(ViewportTravel.forward(target: 10, witness: 2, hint: false))
        #expect(!ViewportTravel.forward(target: 10, witness: nil, hint: false))
    }
    @Test(arguments: [UInt64(1), 42, 0xabcdef, 9999, 0x12345678, 0xffff])
    func seededWindowAndDiffOracle(seed: UInt64) {
        var random = seed, ids = Array(0..<100)
        func next() -> UInt64 { random = random &* 6364136223846793005 &+ 1442695040888963407; return random }
        for iteration in 0..<100 {
            let old = ids
            switch next() % 4 {
            case 0: ids.insert(1000 + iteration, at: Int(next() % UInt64(ids.count + 1)))
            case 1: if !ids.isEmpty { ids.remove(at: Int(next() % UInt64(ids.count))) }
            case 2: if ids.count > 1 { let row = ids.remove(at: Int(next() % UInt64(ids.count))); ids.insert(row, at: Int(next() % UInt64(ids.count + 1))) }
            default: ids.reverse()
            }
            let diff = ItemDiff(old: old, new: ids)
            for (index, id) in old.enumerated() { #expect(diff.survivingIndex(for: index) == ids.firstIndex(of: id)) }
            guard !ids.isEmpty else { continue }
            let anchor = Int(next() % UInt64(ids.count))
            let window = ListWindow.build(count: ids.count, anchor: anchor, viewport: .init(width: 320, height: 400), measure: { index in (Double(10 + ids[index] % 90), 0, 0) }, resolveY: { _ in 100 })
            #expect(window.range.contains(anchor))
            for (a, b) in zip(window.rows, window.rows.dropFirst()) { #expect(a.index + 1 == b.index); #expect(a.maxY == b.y) }
        }
    }
}