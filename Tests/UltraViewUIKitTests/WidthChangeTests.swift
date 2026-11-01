#if canImport(UIKit)
import QuartzCore
import Testing
import UIKit
@testable import UltraCore
import UltraLayout
@testable import UltraList

/// A list whose width changes, at once, inside an animation or a little
/// every frame as a window is dragged larger: every row on screen shows,
/// in every frame, content laid out and drawn for the width it has; rows
/// with a fixed height keep their places; other rows take their heights at
/// the new width; and the row being read stays where it was.
@MainActor
@Suite(.serialized) struct WidthChangeTests {
    /// Text that wraps differently at every width, in a padded card. A
    /// fixed row's root has a height in points, which the list learns.
    /// With `animates`, a new layout animates its keyed nodes from the old one.
    private func row(_ index: Int, fixed: Bool, animates: Bool = false, measurer: any NodeRowMeasuring = NodeRowMeasurer()) -> NodeRow {
        NodeRow(identity: "row-\(index)", measurer: measurer, animatesContent: animates) {
            let text = UltraTextNode(
                "Row \(index). " + String(repeating: "Words that wrap again at each new width. ", count: 1 + index % 4),
                textStyle: .init(fontSize: 15), numberOfLines: fixed ? 2 : 0)
            var card = Style()
            card.padding = 10; card.borderRadius = 10; card.backgroundColor = .white
            text.transitionKey = "text"
            if fixed { card.flex = 1 }
            var root = Style()
            root.paddingHorizontal = 12; root.paddingVertical = 4
            if fixed { root.height = 72 }
            let box = UltraNode(style: card, children: [text])
            box.transitionKey = "card"
            return UltraNode(style: root, children: [box])
        }
    }

    /// Every width change's report, kept as the changes happen.
    @MainActor private final class ResizeLog {
        var reports: [ListResizeReport] = []
        func record(_ list: UltraListView) {
            if let report = list.lastResize, reports.last != report { reports.append(report) }
        }
        var summary: String {
            guard let worst = reports.max(by: { $0.milliseconds < $1.milliseconds }) else { return "no resizes" }
            let total = reports.map(\.milliseconds).sorted()
            return String(format: "%d resizes, median %.1f ms, worst %.1f ms (CPU %.1f, waited %.1f, applying %.1f, pass %.1f, %d rows, %d late)",
                reports.count, total[total.count / 2], worst.milliseconds, worst.cpuMilliseconds, worst.waitedMilliseconds, worst.applyingMilliseconds,
                worst.passMilliseconds, worst.preparedRows, worst.lateRows)
        }
    }

    @MainActor private struct Fixture {
        let window: UIWindow
        let container: UIView
        let list: UltraListView
        let log = ResizeLog()
        func layOut() { container.layoutIfNeeded(); log.record(list) }
    }

    private func makeList(_ mode: ScrollEngineMode = .keyframe, fixed: Bool, animates: Bool = false, count: Int = 80, width: CGFloat = 390,
                          inverted: Bool = false, measurer: any NodeRowMeasuring = NodeRowMeasurer()) async throws -> Fixture {
        let window = makeWindow()
        window.frame = .init(x: 0, y: 0, width: 1024, height: 700)
        let container = UIView(frame: .init(x: 0, y: 0, width: width, height: 700))
        let list = UltraListView(engineMode: mode)
        list.frame = container.bounds
        list.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if inverted { list.contentView.transform = .init(scaleX: 1, y: -1) }
        container.addSubview(list); window.addSubview(container); window.isHidden = false
        list.layoutIfNeeded()
        list.applyChanges(items: (0..<count).map { row($0, fixed: fixed, animates: animates, measurer: measurer) }, transition: .none)
        try await waitUntilDrawn(list)
        return Fixture(window: window, container: container, list: list)
    }

    private func waitUntilDrawn(_ list: UltraListView) async throws {
        for _ in 0..<300 {
            if !list.loadedIndexRange.isEmpty, defects(in: list).isEmpty { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the list never showed every row drawn: \(defects(in: list))")
    }

    /// The node hosts a row view shows.
    private func shownHosts(_ view: UIView) -> [NodeHostView] {
        view.subviews.compactMap { $0 as? NodeHostView }.filter { !$0.isHidden }
    }

    private func textNode(_ node: UltraNode) -> UltraNode? {
        if node is UltraTextNode { return node }
        return node.children.lazy.compactMap { textNode($0) }.first
    }

    /// What a viewer would see wrong now, in the presented frame when
    /// `presented`: a row on screen with nothing drawn in it, or with content
    /// laid out for a width other than the list's.
    private func defects(in list: UltraListView, presented: Bool = false) -> [String] {
        let listLayer = presented ? list.layer.presentation() ?? list.layer : list.layer
        let visible = listLayer.bounds
        let width = list.bounds.width - list.viewportInsets.left - list.viewportInsets.right
        var found: [String] = []
        for index in list.loadedIndexRange {
            guard let view = list.loadedItemView(at: index), !view.isHidden else { continue }
            let layer = presented ? view.layer.presentation() ?? view.layer : view.layer
            let frame = layer.convert(layer.bounds, to: listLayer)
            guard frame.intersects(visible), frame.height > 0.5 else { continue }
            let hosts = shownHosts(view)
            guard let host = hosts.last, host.hasContent else { found.append("row \(index) is blank"); continue }
            if abs(host.bounds.width - width) > 0.5 { found.append("row \(index) shows content \(host.bounds.width) wide in a list \(width) wide") }
            if textNode(host.rootNode)?.view?.layer.contents == nil { found.append("row \(index) has no drawn text") }
        }
        return found
    }

    private func frames(_ list: UltraListView) -> [Int: CGRect] {
        Dictionary(uniqueKeysWithValues: list.loadedIndexRange.compactMap { index in list.settledFrame(at: index).map { (index, $0) } })
    }

    /// The first row showing below the top edge and how much of it is above it.
    private func reading(_ list: UltraListView) throws -> (index: Int, fraction: Double) {
        let index = try #require(list.loadedIndexRange.first { (list.settledFrame(at: $0)?.maxY ?? 0) > 0 })
        let frame = try #require(list.settledFrame(at: index))
        return (index, max(0, -frame.minY) / frame.height)
    }

    private func resize(_ fixture: Fixture, to width: CGFloat) {
        fixture.container.frame.size.width = width
        fixture.layOut()
    }

    // MARK: At once

    @Test(arguments: ScrollEngineMode.allCases)
    func fixedRowsKeepTheirPlacesAndRedrawAtTheNewWidth(mode: ScrollEngineMode) async throws {
        let fixture = try await makeList(mode, fixed: true)
        let list = fixture.list
        list.scrollTo(.init(index: 12, pointOffset: -30), transition: .none)
        try await waitUntilDrawn(list)
        for width in [620.0, 320, 390] as [CGFloat] {
            let before = frames(list)
            resize(fixture, to: width)
            #expect(defects(in: list).isEmpty, "\(mode) at \(width): \(defects(in: list))")
            for (index, frame) in frames(list) {
                guard let old = before[index] else { continue }
                #expect(abs(frame.minY - old.minY) < 0.01 && abs(frame.height - old.height) < 0.01,
                        "\(mode) at \(width): row \(index) moved from \(old) to \(frame)")
                #expect(abs(frame.width - width) < 0.01)
            }
            let report = try #require(list.lastResize)
            #expect(report.lateRows == 0, "\(report)")
            // Widths the list hasn't been at have no measurements: the rows
            // are known to be fixed, from their roots, and keep their heights.
            if width != 390 { #expect(report.fixedRows > 0 && report.preparedRows > 0, "\(report)") }
            print("Width change \(mode), fixed rows, to \(Int(width)): \(String(format: "%.2f", report.milliseconds)) ms on main, \(report.preparedRows) rows")
        }
    }

    @Test(arguments: [ScrollEngineMode.keyframe, .uiKit])
    func variableRowsTakeTheirNewHeightsAndKeepTheReadingPosition(mode: ScrollEngineMode) async throws {
        let fixture = try await makeList(mode, fixed: false)
        let list = fixture.list
        list.scrollTo(.init(index: 9, pointOffset: -40), transition: .none)
        try await waitUntilDrawn(list)
        for width in [300.0, 760, 390] as [CGFloat] {
            let read = try reading(list)
            let oldHeights = frames(list).mapValues(\.height)
            resize(fixture, to: width)
            #expect(defects(in: list).isEmpty, "\(mode) at \(width): \(defects(in: list))")
            let now = try reading(list)
            #expect(now.index == read.index && abs(now.fraction - read.fraction) < 0.01,
                    "\(mode) at \(width): read row \(read.index) at \(read.fraction), now \(now.index) at \(now.fraction)")
            let shown = frames(list)
            #expect(shown.contains { index, frame in oldHeights[index].map { abs($0 - frame.height) > 1 } == true },
                    "\(mode) at \(width): the text rewraps, so some heights change")
            // Each visible row is as tall as the content it shows.
            for (index, frame) in shown where frame.maxY > 0 && frame.minY < list.bounds.height {
                let host = try #require(list.loadedItemView(at: index).flatMap { shownHosts($0).last })
                #expect(abs(host.bounds.height - frame.height) < 0.01, "row \(index): \(host.bounds.height) in \(frame.height)")
            }
            // Measuring again later in the background moves nothing shown.
            try await Task.sleep(for: .milliseconds(300))
            for (index, frame) in frames(list) where frame.maxY > 0 && frame.minY < list.bounds.height {
                if let old = shown[index] { #expect(abs(old.minY - frame.minY) < 0.01 && abs(old.height - frame.height) < 0.01, "row \(index) moved later") }
            }
            print("Width change \(mode), variable rows, to \(Int(width)): \(String(describing: list.lastResize))")
        }
    }

    @Test(arguments: [false, true])
    func aFlippedListKeepsItsNewestRowAtTheBottom(scrolledAway: Bool) async throws {
        let fixture = try await makeList(fixed: false, inverted: true)
        let list = fixture.list
        if scrolledAway {
            list.scrollTo(.init(index: 14, pointOffset: -25), transition: .none)
            try await waitUntilDrawn(list)
        }
        for width in [300.0, 700, 390] as [CGFloat] {
            let read = try reading(list)
            resize(fixture, to: width)
            #expect(defects(in: list).isEmpty, "at \(width): \(defects(in: list))")
            if scrolledAway {
                let now = try reading(list)
                #expect(now.index == read.index && abs(now.fraction - read.fraction) < 0.01, "at \(width): \(read) then \(now)")
            } else {
                // The list's top is the screen's bottom: the newest row rests there.
                let newest = try #require(list.settledFrame(at: 0))
                #expect(abs(newest.minY) < 0.01, "at \(width): newest row at \(newest)")
            }
        }
    }

    @Test func rowsNotReadyInTimeKeepTheirOldContentAndHeight() async throws {
        let fixture = try await makeList(fixed: false, measurer: SlowMeasurer())
        let list = fixture.list
        list.inPlaceResizeTimeLimit = 0.005
        let before = frames(list)
        let oldWidth = list.bounds.width
        resize(fixture, to: 600)
        let report = try #require(list.lastResize)
        #expect(report.lateRows > 0, "\(report)")
        // Nothing blank: each visible row still shows its old content, at
        // its old size, pinned to its leading edge.
        for (index, frame) in frames(list) where frame.maxY > 0 && frame.minY < list.bounds.height {
            let view = try #require(list.loadedItemView(at: index))
            let host = try #require(shownHosts(view).last, "row \(index) is blank")
            #expect(host.hasContent && host.frame.minX == 0 && abs(host.bounds.width - oldWidth) < 0.01)
            if let old = before[index] { #expect(abs(old.height - frame.height) < 0.01) }
        }
        try await waitUntilDrawn(list)
        #expect(defects(in: list).isEmpty)
    }

    // MARK: Every frame of a change

    enum Motion: String, CaseIterable, Sendable {
        /// `UIView.animate` around the container's new frame.
        case curve
        /// A spring, as a split view's column uses.
        case spring
        /// A sidebar column showing and hiding beside the list, which a
        /// split-like container lays out inside an animation.
        case column
        /// A window dragged larger and smaller: a new width every frame.
        case dragged
    }

    enum Rows: String, CaseIterable, Sendable {
        /// A root with a height in points.
        case fixed
        /// Wrapping text sets the height.
        case variable
        /// Variable rows whose keyed nodes animate to a new layout.
        case animated
    }

    @Test(arguments: Motion.allCases, Rows.allCases)
    func everyFrameShowsEveryRowDrawnAtItsWidth(_ motion: Motion, rows: Rows) async throws {
        let fixture = try await makeList(fixed: rows == .fixed, animates: rows == .animated)
        let list = fixture.list
        list.scrollTo(.init(index: 10, pointOffset: -20), transition: .none)
        try await waitUntilDrawn(list)
        var problems: [String] = [], kept = 0, sampled = 0, widths = Set<Int>()
        let sampler = FrameSampler { frame in
            sampled += 1
            let presented = list.layer.presentation()?.bounds.width ?? list.bounds.width
            widths.insert(Int(presented.rounded()))
            // Past the time limit a row keeps its old drawing until its new
            // one arrives: that is the fallback, not a defect.
            let late = (list.lastResize?.lateRows ?? 0) > 0
            for problem in defects(in: list, presented: true) {
                if late, problem.contains(" shows content ") { kept += 1 } else { problems.append("frame \(frame): \(problem)") }
            }
            // The rows follow the list's own width on its way.
            for index in list.loadedIndexRange {
                guard let view = list.loadedItemView(at: index), let layer = view.layer.presentation() else { continue }
                if abs(layer.bounds.width - presented) > 1.5 {
                    problems.append("frame \(frame): row \(index) is \(layer.bounds.width) wide in a list \(presented) wide")
                }
            }
        }
        sampler.start()
        defer { sampler.stop() }
        switch motion {
        case .curve:
            for width in [640.0, 330] as [CGFloat] {
                UIView.animate(withDuration: 0.5) { resize(fixture, to: width) }
                try await Task.sleep(for: .milliseconds(650))
            }
        case .spring:
            for width in [700.0, 300] as [CGFloat] {
                UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0) { resize(fixture, to: width) }
                try await Task.sleep(for: .milliseconds(650))
            }
        case .column:
            // A 320-point sidebar slides in at the leading edge, then out.
            for shown in [true, false] {
                UIView.animate(springDuration: 0.45, bounce: 0) {
                    fixture.container.frame = shown ? .init(x: 320, y: 0, width: 704, height: 700) : .init(x: 0, y: 0, width: 1024, height: 700)
                    fixture.layOut()
                }
                try await Task.sleep(for: .milliseconds(600))
            }
        case .dragged:
            let steps = (0..<40).map { 390 + 8 * CGFloat($0) } + (0..<40).map { 702 - 9 * CGFloat($0) }
            var stepped = 0
            let drag = FrameSampler { frame in
                guard frame < steps.count else { return }
                resize(fixture, to: steps[frame]); stepped = frame + 1
            }
            drag.start()
            for _ in 0..<600 where stepped < steps.count { try await Task.sleep(for: .milliseconds(10)) }
            try await Task.sleep(for: .milliseconds(200))
            drag.stop()
        }
        print("Width change \(motion), \(rows) rows: \(sampled) frames sampled, \(widths.count) widths, \(problems.count) problems, \(kept) old drawings kept past the limit, \(list.resizeFallbacks) fallbacks; \(fixture.log.summary)")
        #expect(sampled > 25, "\(sampled) frames")
        #expect(widths.count > (motion == .dragged ? 20 : 5), "the list's width changed over \(widths.count) frames")
        #expect(problems.isEmpty, "\(motion), \(rows) rows: \(problems.prefix(12)) of \(problems.count)")
    }
}

/// A measurer that takes its time, so a width change can't wait for it.
private struct SlowMeasurer: NodeRowMeasuring {
    func measure(_ root: UltraNode, width: CGFloat, environment: RenderEnvironment) async -> CGSize {
        try? await Task.sleep(for: .milliseconds(60))
        return await NodeMeasurement.measure(root, width: width, environment: environment)
    }
}

/// Calls its body once per display frame, on the main thread.
@MainActor
final class FrameSampler: NSObject {
    private var link: CADisplayLink?
    private var frame = 0
    private let body: (Int) -> Void
    init(_ body: @escaping (Int) -> Void) { self.body = body }
    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = .init(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    func stop() { link?.invalidate(); link = nil }
    @objc private func tick() {
        body(frame)
        frame += 1
    }
}
#endif
