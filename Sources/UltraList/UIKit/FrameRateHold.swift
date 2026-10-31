#if canImport(UIKit)
import UIKit
import QuartzCore

/// Keeps the display at its highest refresh rate while it is held. A finger
/// moving content asks for every frame the screen can show, but bounds
/// written from touch handlers request no rate of their own: on a
/// variable-rate display the screen stays where the rest of the app leaves
/// it, often 60 Hz, and touches arrive coalesced at that rate. Animations
/// do ask, but the display reaches their rate a frame or two after they
/// start. A display link whose callback does nothing is the public way to
/// ask for the full rate from the transaction that starts the motion.
@MainActor
final class FrameRateHold {
    private var link: CADisplayLink?
    private let target = HoldTarget()
    private(set) var isHeld = false
    /// Whether a hold without an end runs; it lasts until `release()`.
    private var isOpen = false
    /// When the timed hold ends, in media time; 0 without one.
    private var deadline = 0.0

    isolated deinit { link?.invalidate() }

    /// Holds until `release()`.
    func hold(maximumFramesPerSecond: Float) {
        isOpen = true
        start(maximumFramesPerSecond)
    }

    /// Holds until `deadline`, in media time, or until a later timed hold
    /// or an open one ends.
    func hold(maximumFramesPerSecond: Float, until deadline: Double) {
        let now = CACurrentMediaTime()
        guard deadline > now else { return }
        start(maximumFramesPerSecond)
        guard deadline > self.deadline else { return }
        self.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + (deadline - now)) { [weak self] in self?.expire() }
    }

    /// Ends the open hold; a timed one still runs to its end.
    func release() {
        isOpen = false
        if CACurrentMediaTime() < deadline - 1e-3 { return }
        stop()
    }

    private func expire() {
        guard !isOpen, CACurrentMediaTime() >= deadline - 1e-3 else { return }
        stop()
    }

    private func start(_ maximumFramesPerSecond: Float) {
        guard !isHeld else { return }
        isHeld = true
        let fps = max(60, maximumFramesPerSecond)
        let range = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
        if let link {
            link.preferredFrameRateRange = range
            link.isPaused = false
            return
        }
        let link = CADisplayLink(target: target, selector: #selector(HoldTarget.frame(_:)))
        link.preferredFrameRateRange = range
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stop() {
        deadline = 0
        guard isHeld else { return }
        isHeld = false
        link?.isPaused = true
    }

    func invalidate() {
        isHeld = false; isOpen = false; deadline = 0
        link?.invalidate(); link = nil
    }

    private final class HoldTarget: NSObject {
        @objc func frame(_ link: CADisplayLink) {}
    }
}
#endif
