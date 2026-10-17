#if canImport(UIKit)
import QuartzCore
import UIKit
import UltraView

/// A scripted run through the demo that measures the main thread: launch,
/// the first appearance of every tab, repeated and rapid tab switches,
/// scrolling the whole feed fast both ways, the stress tab and rotation.
///
/// Launch with `-perfRun YES`. `MainThreadMonitor` records every phase; the
/// report is printed as one `PERF-RESULT {json}` line, shown in a label with
/// the accessibility identifier `perf.result`, and announced with the Darwin
/// notification `dev.ultraview.demo.perf.done`. With `-perfBackground YES`
/// the run then waits for the app to go to the background and come back
/// (the UI test presses Home), and measures the return before reporting.
@MainActor
final class PerfRun {
    static var isRequested: Bool {
        UserDefaults.standard.bool(forKey: "perfRun")
    }

    static let scenarioDone = "dev.ultraview.demo.perf.scenario-done"
    static let done = "dev.ultraview.demo.perf.done"

    private let tabs: UITabBarController
    private let window: UIWindow
    private let monitor = MainThreadMonitor.shared
    private var switchMilliseconds: [String: [Double]] = [:]
    private var returnedFromBackground: CheckedContinuation<Void, Never>?

    init(tabs: UITabBarController, window: UIWindow) {
        self.tabs = tabs
        self.window = window
    }

    func run() async {
        // List scenarios have their own streaming, keyboard and timing probes.
        let screens = DemoScreen.allCases.filter { $0 != .lists }
        await pause(1.5)

        for screen in screens where screen != DemoScreen.initial {
            monitor.beginPhase("first \(screen.rawValue)")
            await select(screen, label: "first")
            await pause(1.5)
        }
        monitor.beginPhase("first \(DemoScreen.initial.rawValue) again")
        await select(DemoScreen.initial, label: "first")
        await pause(1)

        monitor.beginPhase("tab switches")
        for _ in 0..<8 {
            for screen in [DemoScreen.feed, .stress, .layout] {
                await select(screen, label: "repeat")
                await pause(0.4)
            }
        }
        monitor.beginPhase("rapid tab switches")
        for _ in 0..<8 {
            for screen in [DemoScreen.feed, .stress, .layout] {
                await select(screen, label: "rapid")
                await pause(0.05)
            }
        }
        await pause(1)

        await select(.feed, label: "repeat")
        await pause(1)
        if let feed = feedScrollView {
            let end = max(0, feed.contentSize.height - feed.bounds.height)
            monitor.beginPhase("feed fling down")
            await scroll(feed, to: end, pointsPerSecond: 8000)
            await pause(0.5)
            monitor.beginPhase("feed fling up")
            await scroll(feed, to: 0, pointsPerSecond: 8000)
            await pause(0.5)
            monitor.beginPhase("feed jumps")
            for target in [end, 0, end / 2, 0] {
                feed.setContentOffset(CGPoint(x: 0, y: target), animated: false)
                await pause(0.6)
            }
        }

        monitor.beginPhase("stress")
        await select(.stress, label: "repeat")
        await pause(6)

        monitor.beginPhase("rotation")
        await rotate(to: .landscapeRight)
        await select(.feed, label: "landscape")
        await pause(1)
        await select(.layout, label: "landscape")
        await pause(1)
        await rotate(to: .portrait)
        await select(.feed, label: "repeat")
        await pause(1)

        monitor.beginPhase("idle")
        await pause(1)

        if UserDefaults.standard.bool(forKey: "perfBackground") {
            monitor.beginPhase("background")
            postDarwinNotification(Self.scenarioDone)
            await withCheckedContinuation { returnedFromBackground = $0 }
            monitor.beginPhase("return from background")
            await pause(2)
        }
        monitor.stop()
        report()
    }

    /// Called when the scene comes back to the foreground.
    func didEnterForeground() {
        returnedFromBackground?.resume()
        returnedFromBackground = nil
    }

    // MARK: Steps

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// Selects a tab and records the time until the next frame callback:
    /// the main thread's share of the switch.
    private func select(_ screen: DemoScreen, label: String) async {
        guard let index = DemoScreen.allCases.firstIndex(of: screen), tabs.selectedIndex != index else { return }
        let start = CACurrentMediaTime()
        tabs.selectedIndex = index
        await FrameWaiter.nextFrame()
        switchMilliseconds[label, default: []].append((CACurrentMediaTime() - start) * 1000)
    }

    private var feedScrollView: UIScrollView? {
        let index = DemoScreen.allCases.firstIndex(of: .feed)!
        let controller = tabs.viewControllers?[index] as? NodeScreenController
        return (controller?.rootNode.children.first as? UltraScrollNode)?.view as? UIScrollView
    }

    private func scroll(_ view: UIScrollView, to target: CGFloat, pointsPerSecond: CGFloat) async {
        await withCheckedContinuation { continuation in
            ScrollDriver(view: view, target: target, speed: pointsPerSecond) {
                continuation.resume()
            }.start()
        }
    }

    private func rotate(to orientation: UIInterfaceOrientationMask) async {
        guard let scene = window.windowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation)) { error in
            print("PERF rotation failed: \(error)")
        }
        tabs.setNeedsUpdateOfSupportedInterfaceOrientations()
        await pause(1.5)
    }

    // MARK: Report

    private func report() {
        let summaries = monitor.summaries
        var hosts: [String: [String: Double]] = [:]
        for (index, controller) in (tabs.viewControllers ?? []).enumerated() {
            guard let controller = controller as? NodeScreenController, controller.isViewLoaded else { continue }
            let values = controller.host.statistics.current
            hosts[DemoScreen.allCases[index].rawValue] = [
                "commits": Double(values.commits),
                "averageApplyMs": values.averageMilliseconds,
                "maxApplyMs": values.maxMilliseconds,
            ]
        }
        let result = PerfResult(
            configuration: Self.configuration,
            device: UIDevice.current.model + " " + Self.machine,
            system: UIDevice.current.systemVersion,
            thresholdMs: monitor.threshold,
            mainThreadWork: Diagnostics.shared.counts.mainThreadWork,
            maxTurnMs: summaries.map(\.maxTurnMilliseconds).max() ?? 0,
            phases: summaries.map(PerfResult.Phase.init),
            stalls: monitor.stalls.map { PerfResult.Stall(phase: $0.phase, ms: $0.milliseconds, at: $0.startTime, notes: $0.notes) },
            tabSwitchMs: switchMilliseconds.mapValues { values in
                ["count": Double(values.count), "max": values.max() ?? 0, "median": MainThreadMonitorMath.median(values)]
            },
            hosts: hosts
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(result)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        if let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? Data(json.utf8).write(to: directory.appendingPathComponent("performance.json"))
        }
        print("PERF-RESULT \(json)")
        for phase in summaries {
            print(String(
                format: "PERF %-24@ max turn %6.1f ms  p99 turn %5.1f ms  stalls %3d  max frame %6.1f ms  p99 frame %5.1f ms  hitch %5.1f ms/s",
                phase.phase as NSString, phase.maxTurnMilliseconds, phase.p99TurnMilliseconds, phase.stalls,
                phase.maxFrameMilliseconds, phase.p99FrameMilliseconds, phase.hitchRatio
            ))
        }
        for stall in monitor.stalls {
            print("PERF stall \(stall)")
        }

        let label = UILabel()
        label.accessibilityIdentifier = "perf.result"
        label.accessibilityLabel = json
        label.text = String(format: "perf done: max turn %.1f ms, %d stalls", result.maxTurnMs, monitor.stalls.count)
        label.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.backgroundColor = monitor.stalls.isEmpty ? .systemGreen : .systemRed
        label.textAlignment = .center
        label.frame = CGRect(x: 0, y: window.bounds.height / 2 - 20, width: window.bounds.width, height: 40)
        window.addSubview(label)
        postDarwinNotification(Self.done)
    }

    private static var configuration: String {
        #if DEBUG
        "Debug"
        #else
        "Release"
        #endif
    }

    private static var machine: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private func postDarwinNotification(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }
}

/// The run's report, as JSON.
struct PerfResult: Codable {
    struct Phase: Codable {
        var phase: String
        var seconds: Double
        var maxTurnMs: Double
        var p99TurnMs: Double
        var stalls: Int
        var frames: Int
        var maxFrameMs: Double
        var p99FrameMs: Double
        var hitches: Int
        var hitchRatio: Double

        init(_ summary: MainThreadMonitor.PhaseSummary) {
            phase = summary.phase
            seconds = summary.seconds
            maxTurnMs = summary.maxTurnMilliseconds
            p99TurnMs = summary.p99TurnMilliseconds
            stalls = summary.stalls
            frames = summary.frames
            maxFrameMs = summary.maxFrameMilliseconds
            p99FrameMs = summary.p99FrameMilliseconds
            hitches = summary.hitches
            hitchRatio = summary.hitchRatio
        }
    }

    struct Stall: Codable {
        var phase: String
        var ms: Double
        var at: Double
        var notes: [String]
    }

    var configuration: String
    var device: String
    var system: String
    var thresholdMs: Double
    var mainThreadWork: Int
    var maxTurnMs: Double
    var phases: [Phase]
    var stalls: [Stall]
    var tabSwitchMs: [String: [String: Double]]
    var hosts: [String: [String: Double]]
}

enum MainThreadMonitorMath {
    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

/// Resumes after the next display-link callback.
@MainActor
private final class FrameWaiter: NSObject {
    private var continuation: CheckedContinuation<Void, Never>?
    private var link: CADisplayLink?

    static func nextFrame() async {
        let waiter = FrameWaiter()
        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            let link = CADisplayLink(target: waiter, selector: #selector(frame))
            waiter.link = link
            link.add(to: .main, forMode: .common)
        }
    }

    @objc private func frame() {
        link?.invalidate()
        link = nil
        continuation?.resume()
        continuation = nil
    }
}

/// Moves a scroll view's offset toward a target at a constant speed, one
/// step per display frame, like a long fast fling.
@MainActor
private final class ScrollDriver: NSObject {
    private let view: UIScrollView
    private let target: CGFloat
    private let speed: CGFloat
    private var completion: (() -> Void)?
    private var link: CADisplayLink?
    private var last: CFTimeInterval?

    init(view: UIScrollView, target: CGFloat, speed: CGFloat, completion: @escaping () -> Void) {
        self.view = view
        self.target = target
        self.speed = speed
        self.completion = completion
    }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let elapsed = last.map { now - $0 } ?? (link.targetTimestamp - link.timestamp)
        last = now
        let current = view.contentOffset.y
        let distance = speed * CGFloat(elapsed)
        let next = target > current ? min(target, current + distance) : max(target, current - distance)
        view.contentOffset = CGPoint(x: view.contentOffset.x, y: next)
        if next == target {
            link.invalidate()
            self.link = nil
            completion?()
            completion = nil
        }
    }
}
#endif
