#if canImport(UIKit)
import QuartzCore
import Testing
import UIKit
import UltraCore
@testable import UltraList

/// Rows with `animatesContent` resized in lists whose clocks are stopped:
/// at points along the resize, a card's rounded background follows the
/// row's edges with its corners intact, and its text rides along at its
/// padding.
@MainActor
@Suite(.serialized) struct ElasticResizeTests {
    private static let phases = [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]

    /// A card like the demo's: a rounded, tinted box inset in its row, with
    /// a one-line title and wrapping detail text inside.
    private func card(identity: String, revision: UInt64, inset: (horizontal: Double, vertical: Double), padding: Double, height: Double?, detail: String) -> NodeRow {
        NodeRow(identity: identity, revision: revision, animatesContent: true) {
            let title = UltraTextNode("Card \(identity)", textStyle: .init(color: .white, fontSize: 17, fontWeight: .bold), numberOfLines: 1)
            title.transitionKey = "title"
            let body = UltraTextNode(detail, textStyle: .init(color: .white, fontSize: 13))
            body.transitionKey = "detail"
            var box = Style()
            box.flex = 1; box.padding = .points(padding); box.gap = 6; box.borderRadius = 16
            box.backgroundColor = .indigo; box.overflow = .hidden
            let card = UltraNode(style: box, children: [title, body])
            card.transitionKey = "card"
            var root = Style()
            root.paddingHorizontal = .points(inset.horizontal); root.paddingVertical = .points(inset.vertical)
            if let height { root.height = .points(height) }
            return UltraNode(style: root, children: [card])
        }
    }

    private func visibleHosts(in view: UIView) -> [NodeHostView] {
        view.subviews.compactMap { $0 as? NodeHostView }.filter { !$0.isHidden }
    }

    private func shown(_ layer: CALayer, in target: CALayer) throws -> CGRect {
        let presented = try #require(layer.presentation())
        let destination = try #require(target.presentation())
        return presented.convert(presented.bounds, to: destination)
    }

    private struct Sample {
        var row: CGRect, card: CGRect, title: CGRect
        var radius: CGFloat, cardHasBitmap: Bool, hosts: Int, opacity: Float
    }

    /// Steps the stopped clock through the resize and reads each frame.
    private func samples(clock: CALayer, rowView: UIView, contentView: UIView, target: CALayer, begin: Double) async throws -> [Sample] {
        var result: [Sample] = []
        for phase in Self.phases {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            clock.timeOffset = begin + phase
            CATransaction.commit(); CATransaction.flush()
            try await Task.sleep(for: .milliseconds(35))
            let hosts = visibleHosts(in: contentView)
            let host = try #require(hosts.first)
            let card = try #require(host.view(forTransitionKey: "card")).layer
            let title = try #require(host.view(forTransitionKey: "title")).layer
            let presented = try #require(card.presentation())
            result.append(Sample(
                row: try shown(rowView.layer, in: target),
                card: try shown(card, in: target),
                title: try shown(title, in: target),
                radius: presented.cornerRadius,
                cardHasBitmap: card.contents != nil,
                hosts: hosts.count,
                opacity: presented.opacity
            ))
        }
        return result
    }

    /// Waits until the list shows the revision whose root is not `old`.
    private func waitForReplacement(of old: UltraNode, in view: UIView) async throws -> NodeHostView {
        for _ in 0..<200 {
            if let host = visibleHosts(in: view).first, host.rootNode !== old, host.hasContent { return host }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the resized revision never showed")
        return try #require(visibleHosts(in: view).first)
    }

    @Test func aCardGrowsInHeightWithItsCornersAndPaddingIntact() async throws {
        let window = makeWindow()
        window.frame = .init(x: 0, y: 0, width: 320, height: 600)
        let list = UltraListView()
        list.frame = window.bounds
        window.addSubview(list); window.isHidden = false
        defer { window.isHidden = true }
        list.layoutIfNeeded()
        func row(_ revision: UInt64, height: Double) -> NodeRow {
            card(identity: "0", revision: revision, inset: (12, 4), padding: 14, height: height, detail: "Rows resize with their content.")
        }
        list.applyChanges(items: [row(0, height: 88)], transition: .none)
        for _ in 0..<200 where list.loadedItemView(at: 0)?.isDisplayReady != true { try await Task.sleep(for: .milliseconds(10)) }
        let view = try #require(list.loadedItemView(at: 0))
        let before = try #require(visibleHosts(in: view).first).rootNode

        list.layer.speed = 0; list.layer.timeOffset = 100
        list.applyChanges(items: [row(1, height: 240)], transition: .easeInOut(1))
        _ = try await waitForReplacement(of: before, in: view)
        let frames = try await samples(clock: list.layer, rowView: view, contentView: view, target: list.layer, begin: 100)

        for (phase, sample) in zip(Self.phases, frames) {
            let row = sample.row, card = sample.card
            #expect(abs(card.minX - row.minX - 12) < 0.01 && abs(row.maxX - card.maxX - 12) < 0.01, "phase \(phase): card \(card) in row \(row)")
            #expect(abs(card.minY - row.minY - 4) < 0.01 && abs(row.maxY - card.maxY - 4) < 0.01, "phase \(phase): card \(card) in row \(row)")
            #expect(abs(sample.title.minX - card.minX - 14) < 0.01 && abs(sample.title.minY - card.minY - 14) < 0.01, "phase \(phase): title \(sample.title) in card \(card)")
            #expect(sample.radius == 16 && !sample.cardHasBitmap, "phase \(phase): the box is a layer with its own corners")
            #expect(sample.hosts == 1 && sample.opacity == 1, "phase \(phase): one revision shows, fully")
        }
        let heights = frames.map(\.row.height)
        #expect(abs(heights[0] - 88) < 0.01 && abs(heights[heights.count - 1] - 240) < 0.01, "\(heights)")
        for (a, b) in zip(heights, heights.dropFirst()) { #expect(b > a, "the row grows at every step: \(heights)") }
    }

    @Test(arguments: [false, true]) func aCardWidensWithItsCornersAndPaddingIntact(shrinks: Bool) async throws {
        let window = makeWindow()
        window.frame = .init(x: 0, y: 0, width: 390, height: 600)
        let horizontal = HorizontalListView(engineMode: .keyframe)
        horizontal.frame = .init(x: 0, y: 100, width: 390, height: 220)
        window.addSubview(horizontal); window.isHidden = false
        defer { window.isHidden = true }
        horizontal.layoutIfNeeded()
        let list = horizontal.list
        let (from, to): (Double, Double) = shrinks ? (260, 120) : (120, 260)
        func rows(_ revision: UInt64, width: Double) -> [HorizontalRow] {
            [HorizontalRow(card(identity: "0", revision: revision, inset: (4, 0), padding: 12, height: nil, detail: "\(Int(width)) points wide"), width: width)]
                + (1..<4).map { HorizontalRow(card(identity: String($0), revision: 0, inset: (4, 0), padding: 12, height: nil, detail: "Next"), width: 120) }
        }
        list.applyChanges(items: rows(0, width: from), newInsets: .init(top: 12, left: 12, bottom: 12, right: 12), transition: .none)
        for _ in 0..<200 where list.loadedItemView(at: 0)?.isDisplayReady != true { try await Task.sleep(for: .milliseconds(10)) }
        let view = try #require(list.loadedItemView(at: 0) as? HorizontalRowView)
        let before = try #require(visibleHosts(in: view.content).first).rootNode

        list.layer.speed = 0; list.layer.timeOffset = 100
        list.applyChanges(items: rows(1, width: to), transition: .easeInOut(1))
        _ = try await waitForReplacement(of: before, in: view.content)
        let frames = try await samples(clock: list.layer, rowView: view, contentView: view.content, target: horizontal.layer, begin: 100)

        for (phase, sample) in zip(Self.phases, frames) {
            let row = sample.row, card = sample.card
            #expect(abs(card.minX - row.minX - 4) < 0.01 && abs(row.maxX - card.maxX - 4) < 0.01, "phase \(phase): card \(card) in row \(row)")
            #expect(abs(card.minY - row.minY) < 0.01 && abs(row.maxY - card.maxY) < 0.01, "phase \(phase): card \(card) in row \(row)")
            #expect(abs(sample.title.minX - card.minX - 12) < 0.01 && abs(sample.title.minY - card.minY - 12) < 0.01, "phase \(phase): title \(sample.title) in card \(card)")
            #expect(sample.radius == 16 && !sample.cardHasBitmap, "phase \(phase): the box is a layer with its own corners")
            #expect(sample.hosts == 1 && sample.opacity == 1, "phase \(phase): one revision shows, fully")
        }
        let widths = frames.map(\.row.width)
        #expect(abs(widths[0] - from) < 0.01 && abs(widths[widths.count - 1] - to) < 0.01, "\(widths)")
        for (a, b) in zip(widths, widths.dropFirst()) { #expect(shrinks ? b < a : b > a, "the row changes at every step: \(widths)") }
    }

    /// Animated and plain node rows inserted, removed, resized, scrolled
    /// away and back over and over, with transitions overlapping: views are
    /// released, reused and crossfaded mid-flight. Run under a sanitizer, a
    /// freed view or layer reached by a later commit shows here.
    @Test func rowsSurviveChurnWhileTheirContentAnimates() async throws {
        let window = makeWindow()
        window.frame = .init(x: 0, y: 0, width: 320, height: 500)
        let list = UltraListView()
        list.frame = window.bounds
        window.addSubview(list); window.isHidden = false
        defer { window.isHidden = true }
        list.layoutIfNeeded()
        var seed: UInt64 = 0x5eed
        func next(_ range: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(range))
        }
        struct Model { var identity: String; var revision: UInt64; var lines: Int; var animates: Bool }
        var serial = 0
        func model() -> Model { serial += 1; return Model(identity: "c\(serial)", revision: 0, lines: 1 + next(4), animates: next(3) != 0) }
        var models = (0..<40).map { _ in model() }
        func rows() -> [NodeRow] {
            models.map { model in
                let text = String(repeating: "Churning row \(model.identity). ", count: model.lines)
                return NodeRow(identity: model.identity, revision: model.revision, animatesContent: model.animates) {
                    let body = UltraTextNode(text, textStyle: .init(fontSize: 14))
                    body.transitionKey = "body"
                    var box = Style(); box.padding = 10; box.borderRadius = 12; box.backgroundColor = .indigo
                    if model.lines % 2 == 0 { box.borderBottomLeftRadius = 4 }
                    let card = UltraNode(style: box, children: [body])
                    card.transitionKey = "card"
                    var root = Style(); root.paddingVertical = 4; root.paddingHorizontal = 8
                    return UltraNode(style: root, children: [card])
                }
            }
        }
        list.applyChanges(items: rows(), transition: .none)
        for step in 0..<120 {
            switch next(6) {
            case 0: models.insert(model(), at: next(models.count + 1))
            case 1: if models.count > 10 { models.remove(at: next(models.count)) }
            case 2, 3:
                for _ in 0..<3 {
                    let index = next(models.count)
                    models[index].lines = 1 + next(5); models[index].revision += 1
                }
            case 4: list.scrollTo(.init(index: next(models.count)), transition: next(2) == 0 ? .immediate : .easeInOut(0.2))
            default: models.insert(models.remove(at: next(models.count)), at: next(models.count))
            }
            list.applyChanges(items: rows(), transition: step % 5 == 0 ? .immediate : .easeInOut(0.25))
            try await Task.sleep(for: .milliseconds(8 + next(30)))
        }
        try await Task.sleep(for: .milliseconds(400))
        for view in list.loadedItemViews { #expect(visibleHosts(in: view).count <= 1) }
    }
}
#endif
