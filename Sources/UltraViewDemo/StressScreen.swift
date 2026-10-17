#if canImport(UIKit)
import Synchronization
import UIKit
import UltraView

/// Background threads change a grid of tiles several times a second: colors,
/// sizes, corner radii and text. Each change only schedules a pass; the
/// header shows what applying the resulting commits costs the main thread.
final class StressScreenController: NodeScreenController {
    private let tiles: [UltraNode]
    private let labels: [UltraTextNode]
    private let ticker: UltraTextNode
    private let stats: UltraTextNode
    private var timers: [any DispatchSourceTimer] = []

    init() {
        let colors: [Color] = [.indigo, .pink, .orange, .teal, .purple, .blue, .green, .red]
        var tiles: [UltraNode] = []
        var labels: [UltraTextNode] = []
        for index in 0..<48 {
            let label = UltraTextNode(
                "\(index)",
                textStyle: TextStyle(color: .white, fontSize: 15, fontWeight: .bold, textAlign: .center)
            )
            let tile = UltraNode(
                style: styled {
                    $0.width = 56
                    $0.height = 56
                    $0.justifyContent = .center
                    $0.alignItems = .center
                    $0.backgroundColor = colors[index % colors.count]
                    $0.borderRadius = 12
                },
                children: [label]
            )
            tiles.append(tile)
            labels.append(label)
        }
        self.tiles = tiles
        self.labels = labels
        ticker = UltraTextNode(
            "Starting…",
            style: styled {
                $0.padding = 12
                $0.backgroundColor = Palette.card
                $0.borderRadius = 12
            },
            textStyle: TextStyle(color: Palette.label, fontSize: 15, lineHeight: 20)
        )
        stats = UltraTextNode(
            "",
            textStyle: TextStyle(color: Palette.label, fontSize: 13, fontFamily: "Menlo", lineHeight: 18)
        )
        let root = UltraNode(
            style: styled {
                $0.flex = 1
                $0.padding = 16
                $0.gap = 12
            },
            children: [
                UltraTextNode("Stress", textStyle: TextStyle(color: Palette.label, fontSize: 34, fontWeight: .bold)),
                UltraNode(
                    style: styled {
                        $0.padding = 12
                        $0.backgroundColor = Color(hex: 0x1C1C1E)
                        $0.borderRadius = 12
                    },
                    children: [stats]
                ),
                ticker,
                UltraNode(
                    style: styled {
                        $0.flexDirection = .row
                        $0.flexWrap = .wrap
                        $0.gap = 6
                        $0.justifyContent = .center
                        $0.alignContent = .flexStart
                    },
                    children: tiles
                ),
            ]
        )
        stats.textStyle.color = Color(hex: 0x30D158)
        super.init(rootNode: root)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startMutating()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        timers.forEach { $0.cancel() }
        timers = []
    }

    private func startMutating() {
        guard timers.isEmpty else { return }
        let tiles = tiles
        let labels = labels
        let ticker = ticker
        let stats = stats
        let statistics = host.statistics
        let mutations = MutationCount()
        let baseline = Diagnostics.shared.counts
        statistics.reset()

        // Two queues change tiles at different rates.
        for (rate, label) in [(8.0, "tiles.a"), (5.0, "tiles.b")] {
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dev.ultraview.demo.\(label)"))
            timer.schedule(deadline: .now(), repeating: 1 / rate)
            timer.setEventHandler {
                var random = SystemRandomNumberGenerator()
                for _ in 0..<6 {
                    let index = Int.random(in: 0..<tiles.count, using: &random)
                    let size = CGFloat([44, 56, 68].randomElement(using: &random)!)
                    let hue = CGFloat.random(in: 0...1, using: &random)
                    tiles[index].updateStyle {
                        $0.width = .points(size)
                        $0.height = .points(size)
                        $0.borderRadius = CGFloat.random(in: 4...(size / 2), using: &random)
                        $0.backgroundColor = Color(UIColor(hue: hue, saturation: 0.7, brightness: 0.9, alpha: 1))
                    }
                    labels[index].text = "\(Int.random(in: 0..<1000, using: &random))"
                    mutations.value.add(2, ordering: .relaxed)
                }
            }
            timers.append(timer)
        }

        // A third queue rewrites a paragraph of styled text.
        let words = ["layout", "measure", "draw", "commit", "apply", "coalesce", "cancel", "mount"]
        let textTimer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dev.ultraview.demo.text"))
        textTimer.schedule(deadline: .now(), repeating: 1 / 6.0)
        textTimer.setEventHandler {
            var random = SystemRandomNumberGenerator()
            ticker.spans = (0..<12).map { _ in
                let word = words.randomElement(using: &random)!
                return TextSpan(word + " ", style: TextStyle(
                    color: Bool.random(using: &random) ? Palette.label : .indigo,
                    fontWeight: Bool.random(using: &random) ? .bold : .regular,
                    fontStyle: Bool.random(using: &random) ? .italic : .normal
                ))
            }
            mutations.value.add(1, ordering: .relaxed)
        }
        timers.append(textTimer)

        // The statistics are a node too, updated from a background queue.
        let statsTimer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dev.ultraview.demo.stats"))
        statsTimer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        statsTimer.setEventHandler {
            let values = statistics.current
            let work = Diagnostics.shared.counts - baseline
            stats.text = """
                main ms/commit  last \(format(values.lastMilliseconds))  avg \(format(values.averageMilliseconds))  max \(format(values.maxMilliseconds))
                commits \(values.commits)  entries \(values.lastEntries)  mutations \(mutations.value.load(ordering: .relaxed))
                passes \(work.passes)  text layouts \(work.measurements)  draws \(work.draws)
                on main: passes \(work.passesOnMain)  text \(work.measurementsOnMain)  draws \(work.drawsOnMain)
                """
        }
        timers.append(statsTimer)

        timers.forEach { $0.resume() }
    }
}

private final class MutationCount: Sendable {
    let value = Atomic<Int>(0)
}

private func format(_ milliseconds: Double) -> String {
    String(format: "%.2f", milliseconds)
}
#endif
