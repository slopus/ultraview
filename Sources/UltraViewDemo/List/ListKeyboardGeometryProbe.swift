#if canImport(UIKit)
import UIKit
import QuartzCore
import UltraView

/// Opt-in measurements for the keyboard interaction tests.
@MainActor
final class ListKeyboardGeometryProbe: NSObject {
    private weak var owner: UIView?
    private weak var composer: UIView?
    private weak var list: UltraListView?
    private let marker = UIView(), report = UILabel()
    private var link: CADisplayLink?
    private var maximumComposerGap = 0.0, maximumRestingRowGap = 0.0
    private var samples = 0, movingSamples = 0, dragSamples = 0, rowAnimationSamples = 0
    private var previousKeyboardY: Double?
    private var dragMinimum = Double.infinity, dragMaximum = -Double.infinity
    private var ended = 0, cancelled = 0, releaseGeneration = 0
    private var previousPassCount: UInt64?
    private var keyboardPasses: UInt64 = 0
    private var minimumViewportHeight = Double.infinity, maximumViewportHeight = -Double.infinity
    private var releaseVelocity = 0.0, coast = 0.0
    private var insetDurations: [Double] = []
    private var stoppedReleases = 0, keyboardSpringSamples = 0
    private var keyboardSpringCorrect = true
    private var worstRowState: [String: Double] = [:]

    init(owner: UIView, composer: UIView, list: UltraListView) {
        self.owner = owner; self.composer = composer; self.list = list
        super.init()
        marker.translatesAutoresizingMaskIntoConstraints = false; owner.addSubview(marker)
        NSLayoutConstraint.activate([
            marker.topAnchor.constraint(equalTo: owner.keyboardLayoutGuide.topAnchor),
            marker.leadingAnchor.constraint(equalTo: owner.leadingAnchor),
            marker.widthAnchor.constraint(equalToConstant: 1), marker.heightAnchor.constraint(equalToConstant: 1),
        ])
        report.frame = .init(x: 0, y: 0, width: 1, height: 1)
        report.text = " "; report.accessibilityLabel = "Keyboard geometry probe"
        report.accessibilityIdentifier = "keyboardGeometry"; report.isAccessibilityElement = true
        owner.addSubview(report)
        list.onScrollInput = { [weak self] event in self?.input(event) }
    }
    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(sample))
        link.add(to: .main, forMode: .common); self.link = link
    }
    func stop() { link?.invalidate(); link = nil }
    func recordInsetUpdate(milliseconds: Double) {
        insetDurations.append(milliseconds)
        if insetDurations.count > 512 { insetDurations.removeFirst() }
    }
    func recordStoppedRelease() { stoppedReleases += 1 }
    private func position() -> Double {
        guard let list, let first = list.loadedIndexRange.first, let frame = list.settledFrame(at: first) else { return 0 }
        let prefix = list.items.prefix(first).reduce(0.0) { total, item in total + ((item as? DemoListRow)?.height ?? 0) }
        return prefix - frame.minY + list.viewportInsets.top
    }
    private func input(_ event: GestureRecording.Event) {
        if event.phase == .cancelled { cancelled += 1 }
        guard event.phase == .ended else { return }
        ended += 1; releaseVelocity = event.velocity.y; coast = 0
        releaseGeneration += 1
        let generation = releaseGeneration, released = position()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, releaseGeneration == generation else { return }
            coast = abs(position() - released)
        }
    }
    @objc private func sample() {
        guard let owner, let composer, let list, owner.window != nil else { return }
        let keyboardY = (marker.layer.presentation() ?? marker.layer).frame.minY
        let destination = owner.layer.presentation() ?? owner.layer
        let composerLayer = composer.layer.presentation() ?? composer.layer
        let bar = composerLayer.convert(composerLayer.bounds, to: destination)
        let moving = previousKeyboardY.map { abs($0 - keyboardY) > 0.01 } ?? false
        previousKeyboardY = keyboardY; samples += 1
        if moving { movingSamples += 1 }
        if moving, !list.isTracking, let animation = list.contentView.layer.animation(forKey: "ultraview.list.viewportOffset") {
            keyboardSpringSamples += 1
            if let spring = animation as? CASpringAnimation {
                keyboardSpringCorrect = keyboardSpringCorrect && abs(spring.stiffness - 555.027) < 0.001 && abs(spring.damping - 47.118) < 0.001 && spring.mass == 1
            } else { keyboardSpringCorrect = false }
        }
        if moving, let previousPassCount { keyboardPasses += list.appliedPassCount - previousPassCount }
        previousPassCount = list.appliedPassCount
        minimumViewportHeight = min(minimumViewportHeight, list.bounds.height)
        maximumViewportHeight = max(maximumViewportHeight, list.bounds.height)
        maximumComposerGap = max(maximumComposerGap, abs(bar.maxY + 8 - keyboardY))
        if list.isTracking {
            dragSamples += 1; dragMinimum = min(dragMinimum, keyboardY); dragMaximum = max(dragMaximum, keyboardY)
            if list.loadedItemViews.contains(where: { $0.layer.animation(forKey: "ultraview.list.positionY") != nil }) { rowAnimationSamples += 1 }
        } else if !list.isScrollFlightActive, let frame = list.settledFrame(at: 0), abs(frame.minY - list.viewportInsets.top) < 0.5,
                  let row = list.loadedItemView(at: 0) {
            let layer = row.layer.presentation() ?? row.layer
            let rect = layer.convert(layer.bounds, to: owner.layer.presentation() ?? owner.layer)
            let gap = abs(rect.maxY - bar.minY)
            if gap > maximumRestingRowGap {
                maximumRestingRowGap = gap
                worstRowState = ["row": rect.maxY, "bar": bar.minY, "keyboard": keyboardY,
                    "offset": list.currentScrollOffset, "inset": list.viewportInsets.top,
                    "presentedOffset": list.contentView.layer.presentation().map { Double($0.bounds.minY) } ?? 0]
            }
        }
        let document: [String: Any] = [
            "samples": samples, "movingSamples": movingSamples, "dragSamples": dragSamples,
            "composerGap": maximumComposerGap, "rowGap": maximumRestingRowGap,
            "dragKeyboardTravel": dragMinimum.isFinite ? dragMaximum - dragMinimum : 0,
            "rowAnimationSamples": rowAnimationSamples, "ended": ended, "cancelled": cancelled,
            "releaseVelocity": releaseVelocity, "coast": coast, "keyboardY": keyboardY,
            "flightActive": list.isScrollFlightActive,
            "keyboardPasses": keyboardPasses, "viewportHeightChange": maximumViewportHeight - minimumViewportHeight,
            "stoppedReleases": stoppedReleases, "keyboardSpringSamples": keyboardSpringSamples, "keyboardSpringCorrect": keyboardSpringCorrect,
            "insetP99": insetDurations.isEmpty ? 0 : insetDurations.sorted()[Int(Double(insetDurations.count - 1) * 0.99)],
            "worstRowState": worstRowState,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]) {
            report.accessibilityValue = String(decoding: data, as: UTF8.self)
        }
    }
}
#endif