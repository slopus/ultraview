#if canImport(UIKit)
import QuartzCore
import UIKit
import os

/// Watches the main thread for stalls, for debugging and performance tests.
///
/// It measures two things while it runs:
/// - busy turns: how long the main thread works before its run loop goes
///   back to sleep, including UIKit layout and the Core Animation commit at
///   the end of the turn. A turn longer than `threshold` is a stall: touches,
///   animations driven by the main thread and the next frame all wait for it.
/// - frames: the interval between display-link callbacks. An interval longer
///   than one and a half refresh periods is a hitch; the time beyond one
///   period counts as hitch time.
///
/// Results are kept per phase (`beginPhase`), so a test can tell which
/// scenario stalled. The library notes what it did on the main thread during
/// a turn (waiting for a commit, applying one), and a stall reports those
/// notes. Running the monitor costs a run-loop observer and a display link.
@MainActor
public final class MainThreadMonitor {
    public static let shared = MainThreadMonitor()

    /// A busy turn longer than the threshold.
    public struct Stall: Sendable, CustomStringConvertible {
        public var phase: String
        public var milliseconds: Double
        /// Seconds since the monitor started, at the start of the turn.
        public var startTime: Double
        /// What the library did on the main thread in that turn.
        public var notes: [String]

        public var description: String {
            let what = notes.isEmpty ? "" : ": " + notes.joined(separator: ", ")
            return String(format: "%.1f ms at %.3f s in %@", milliseconds, startTime, phase) + what
        }
    }

    /// Statistics for one phase.
    public struct PhaseSummary: Sendable {
        public var phase: String
        public var seconds: Double
        public var turns: Int
        public var maxTurnMilliseconds: Double
        public var p99TurnMilliseconds: Double
        public var stalls: Int
        public var frames: Int
        public var maxFrameMilliseconds: Double
        public var p99FrameMilliseconds: Double
        public var hitches: Int
        public var hitchMilliseconds: Double

        /// Milliseconds of hitch time per second, as Instruments reports it.
        public var hitchRatio: Double {
            seconds > 0 ? hitchMilliseconds / seconds : 0
        }
    }

    /// The longest busy turn that isn't a stall, in milliseconds.
    public var threshold: Double = 1000 / 60
    /// Called for every stall, after its turn ends.
    public var onStall: ((Stall) -> Void)?
    /// Optional detailed observations for an opt-in interaction probe.
    public struct Turn: Sendable {
        /// Monotonic media time, in seconds.
        public var startTime: Double
        public var milliseconds: Double
        public var notes: [String]
    }
    public var onTurn: ((Turn) -> Void)?
    public private(set) var isRunning = false
    public private(set) var stalls: [Stall] = []

    private final class Phase {
        let name: String
        let start: CFTimeInterval
        var end: CFTimeInterval?
        var turns: [Double] = []
        var frames: [Double] = []
        var hitches = 0
        var hitchMilliseconds: Double = 0

        init(name: String, start: CFTimeInterval) {
            self.name = name
            self.start = start
        }
    }

    private var phases: [Phase] = []
    private var startTime: CFTimeInterval = 0
    private var turnStart: CFTimeInterval?
    private var notes: [String] = []
    private var observers: [CFRunLoopObserver] = []
    private var displayLink: CADisplayLink?
    private var lastFrame: CFTimeInterval?
    private let log = Logger(subsystem: "dev.ultraview", category: "Stalls")

    private init() {}

    /// Starts measuring, from now, in a phase called `phase`. The turn in
    /// progress counts from here.
    public func start(phase: String = "start") {
        guard !isRunning else { return }
        isRunning = true
        startTime = CACurrentMediaTime()
        turnStart = startTime
        phases = [Phase(name: phase, start: startTime)]
        stalls = []
        notes = []

        // First after waking up, last before going to sleep: the turn covers
        // every other observer, UIKit layout and the Core Animation commit.
        let wake = CFRunLoopObserverCreateWithHandler(
            nil,
            CFRunLoopActivity.entry.rawValue | CFRunLoopActivity.afterWaiting.rawValue,
            true,
            CFIndex.min
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.turnBegan() }
        }
        let sleep = CFRunLoopObserverCreateWithHandler(
            nil,
            CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue,
            true,
            CFIndex.max
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.turnEnded() }
        }
        for observer in [wake, sleep].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer)
        }

        let link = CADisplayLink(target: FrameTarget.shared, selector: #selector(FrameTarget.frame(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastFrame = nil
    }

    public func stop() {
        guard isRunning else { return }
        turnEnded()
        phases.last?.end = CACurrentMediaTime()
        for observer in observers {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
        observers = []
        displayLink?.invalidate()
        displayLink = nil
        isRunning = false
    }

    /// Ends the current phase and starts one called `name`.
    public func beginPhase(_ name: String) {
        guard isRunning else { return }
        let now = CACurrentMediaTime()
        phases.last?.end = now
        phases.append(Phase(name: name, start: now))
        lastFrame = nil
    }

    /// The statistics of every phase so far, in order.
    public var summaries: [PhaseSummary] {
        let now = CACurrentMediaTime()
        return phases.map { phase in
            let seconds = (phase.end ?? now) - phase.start
            return PhaseSummary(
                phase: phase.name,
                seconds: seconds,
                turns: phase.turns.count,
                maxTurnMilliseconds: phase.turns.max() ?? 0,
                p99TurnMilliseconds: Self.percentile(99, of: phase.turns),
                stalls: phase.turns.filter { $0 > threshold }.count,
                frames: phase.frames.count,
                maxFrameMilliseconds: phase.frames.max() ?? 0,
                p99FrameMilliseconds: Self.percentile(99, of: phase.frames),
                hitches: phase.hitches,
                hitchMilliseconds: phase.hitchMilliseconds
            )
        }
    }

    /// Records something the main thread did in the current turn, for the
    /// stall report. Cheap when the monitor isn't running.
    public func note(_ what: @autoclosure () -> String) {
        guard isRunning else { return }
        notes.append(what())
    }

    // MARK: Measuring

    private func turnBegan() {
        // A run loop entered inside a turn (a nested one) continues it.
        guard turnStart == nil else { return }
        turnStart = CACurrentMediaTime()
        notes.removeAll(keepingCapacity: true)
    }

    private func turnEnded() {
        guard let start = turnStart else { return }
        turnStart = nil
        let milliseconds = (CACurrentMediaTime() - start) * 1000
        guard let phase = phases.last else { return }
        phase.turns.append(milliseconds)
        onTurn?(.init(startTime: start, milliseconds: milliseconds, notes: notes))
        if milliseconds > threshold {
            let stall = Stall(phase: phase.name, milliseconds: milliseconds, startTime: start - startTime, notes: notes)
            stalls.append(stall)
            log.error("Main thread stalled \(stall.description, privacy: .public)")
            onStall?(stall)
        }
        notes.removeAll(keepingCapacity: true)
    }

    fileprivate func frame(_ link: CADisplayLink) {
        defer { lastFrame = link.timestamp }
        guard let last = lastFrame, let phase = phases.last else { return }
        let interval = link.timestamp - last
        let period = link.targetTimestamp - link.timestamp
        phase.frames.append(interval * 1000)
        if period > 0, interval > period * 1.5 {
            phase.hitches += 1
            phase.hitchMilliseconds += (interval - period) * 1000
        }
    }

    static func percentile(_ percent: Double, of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((Double(sorted.count) * percent / 100).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}

/// The display link's target; the link retains it, so it isn't the monitor.
@MainActor
private final class FrameTarget: NSObject {
    static let shared = FrameTarget()

    @objc func frame(_ link: CADisplayLink) {
        MainThreadMonitor.shared.frame(link)
    }
}
#endif
