#if canImport(UIKit)
import UIKit
import QuartzCore
import UltraView
import os

/// Opt-in measurements for the keyboard interaction tests.
@MainActor
final class ListKeyboardGeometryProbe: NSObject {
    private weak var owner: UIView?
    private weak var composer: UIView?
    private weak var list: UltraListView?
    private let marker: UIView
    private let report = UILabel()
    private var link: CADisplayLink?
    private var maximumTrackingComposerGap = 0.0, maximumRestingRowGap = 0.0
    private var trackingComposerSamples = 0
    private var inputIsDragging = false
    private var samples = 0, movingSamples = 0, dragSamples = 0, rowAnimationSamples = 0
    private var previousKeyboardY: Double?
    private var dragMinimum = Double.infinity, dragMaximum = -Double.infinity
    private var ended = 0, cancelled = 0, releaseGeneration = 0
    private var previousPassCount: UInt64?
    private var keyboardPasses: UInt64 = 0
    private var minimumViewportHeight = Double.infinity, maximumViewportHeight = -Double.infinity
    private var releaseVelocity = 0.0, coast = 0.0
    private var insetDurations: [Double] = []
    private var keyboardSpringSamples = 0
    private var trackingViewportAnimations = 0
    private let followsComposerMotion: () -> Bool
    private weak var handoffRow: ListRowView?
    private var handoffRowPositions: [String: Double] = [:]
    private var previousHandoff: (row: Double, composer: Double, time: Double)?
    private var envelopeOrigin: (row: Double, composer: Double, time: Double)?
    private var handoffUntil = 0.0, handoffSpeed = 0.0, maximumHandoffExcess = 0.0
    private var maximumEnvelopeExcess = 0.0, maximumDetachedAnimation = 0.0
    private var keyboardHideTime = 0.0
    private var releasePosition = 0.0
    private var handoffSamples: [[String: Double]] = []
    private var handoffTurns: [MainThreadMonitor.Turn] = []
    private var catchUps: [[String: Double]] = []
    private var previousHandoffMotion = Double.infinity, lastPublish = 0.0
    private var recentSpeeds: [Double] = []
    private var keyboardSpringCorrect = true
    private var keyboardTransition: ListTransition?
    private var worstRowState: [String: Double] = [:]
    /// Drags begun with the keyboard down and up, and of each those that
    /// found the hidden system keyboard input installed.
    private var keyboardInputDrags = ["down": 0, "up": 0, "downWithInput": 0, "upWithInput": 0]
    private let signposter = OSSignposter(subsystem: "dev.ultraview.keyboarddrag", category: "PointsOfInterest")

    init(owner: UIView, composer: UIView, list: UltraListView, keyboardEdge: UIView, followsComposer: @escaping () -> Bool = { true }) {
        self.owner = owner; self.composer = composer; self.list = list
        marker = keyboardEdge
        followsComposerMotion = followsComposer
        super.init()
        report.frame = .init(x: 0, y: 0, width: 1, height: 1)
        report.text = " "; report.accessibilityLabel = "Keyboard geometry probe"
        report.accessibilityIdentifier = "keyboardGeometry"; report.isAccessibilityElement = true
        owner.addSubview(report)
        let previousInput = list.onScrollInput
        list.onScrollInput = { [weak self] event in previousInput?(event); self?.input(event) }
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardHidden), name: UIResponder.keyboardDidHideNotification, object: nil)
        MainThreadMonitor.shared.onTurn = { [weak self] turn in
            guard let self, handoffUntil > CACurrentMediaTime() - 0.05 else { return }
            if handoffTurns.count < 2048 { handoffTurns.append(turn) }
        }
    }
    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(sample))
        link.add(to: .main, forMode: .common); self.link = link
    }
    func stop() { link?.invalidate(); link = nil; handoffUntil = 0; MainThreadMonitor.shared.onTurn = nil }
    @objc private func keyboardHidden() {
        keyboardHideTime = CACurrentMediaTime()
        if handoffUntil > CACurrentMediaTime() { handoffUntil = max(handoffUntil, CACurrentMediaTime() + 0.5) }
    }
    func recordInsetUpdate(milliseconds: Double) {
        insetDurations.append(milliseconds)
        if insetDurations.count > 512 { insetDurations.removeFirst() }
    }
    func recordKeyboardTransition(_ transition: ListTransition) { keyboardTransition = transition }
    /// Settled heights of rows seen loaded, for rows that don't declare one
    /// (the chat's bubbles are measured).
    private var seenHeights: [String: Double] = [:]
    private func rememberHeights() {
        guard let list else { return }
        for index in list.loadedIndexRange {
            if let height = list.settledFrame(at: index)?.height { seenHeights[list.items[index].identity] = Double(height) }
        }
    }
    private func position() -> Double {
        rememberHeights()
        guard let list, let first = list.loadedIndexRange.first, let frame = list.settledFrame(at: first) else { return 0 }
        let prefix = list.items.prefix(first).reduce(0.0) { total, item in
            total + ((item as? any ListProbeDeclaredHeight)?.declaredHeight ?? seenHeights[item.identity] ?? 0)
        }
        return prefix - frame.minY
    }
    private func input(_ event: GestureRecording.Event) {
        // Observe input phases independently of the controller's tracking guard.
        if event.phase == .began {
            inputIsDragging = true
            let keyboard = (marker.superview.map { Double($0.bounds.maxY - marker.frame.minY) } ?? 0) > Double(owner?.safeAreaInsets.bottom ?? 0) + 1 ? "up" : "down"
            keyboardInputDrags[keyboard, default: 0] += 1
            if list?.hasKeyboardInput == true { keyboardInputDrags[keyboard + "WithInput", default: 0] += 1 }
            signposter.emitEvent("touch-began", "\(keyboard, privacy: .public)")
        }
        if event.phase == .ended || event.phase == .cancelled { signposter.emitEvent("touch-ended") }
        if event.phase == .ended || event.phase == .cancelled { inputIsDragging = false }
        if event.phase == .began { recentSpeeds.removeAll(keepingCapacity: true); handoffUntil = 0; keyboardHideTime = 0 }
        if event.phase == .changed {
            recentSpeeds.append(abs(event.velocity.y))
            if recentSpeeds.count > 2 { recentSpeeds.removeFirst() }
        }
        if event.phase == .cancelled { cancelled += 1 }
        guard event.phase == .ended else { return }
        ended += 1; releaseVelocity = event.velocity.y; coast = 0
        handoffSamples.removeAll(keepingCapacity: true); maximumHandoffExcess = 0
        maximumEnvelopeExcess = 0; maximumDetachedAnimation = 0
        handoffTurns.removeAll(keepingCapacity: true); catchUps.removeAll(keepingCapacity: true)
        previousHandoffMotion = .infinity
        handoffRowPositions.removeAll(keepingCapacity: true)
        handoffSpeed = abs(releaseVelocity) < ReleaseDecision.minimumDecelerationSpeed ? 0 : max(abs(releaseVelocity), recentSpeeds.max() ?? 0)
        if let views = list?.loadedItemViews, !views.isEmpty { handoffRow = views[views.count / 2] }
        previousHandoff = nil; envelopeOrigin = nil; handoffUntil = CACurrentMediaTime() + 1
        releasePosition = position()
        recordHandoff()
        releaseGeneration += 1
        let generation = releaseGeneration, released = position()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, releaseGeneration == generation else { return }
            coast = abs(position() - released)
        }
    }
    private func recordHandoff() {
        guard handoffUntil > CACurrentMediaTime(), let list, let owner, let composer else { return }
        let views = list.loadedItemViews, rows = list.settledWindow.rows
        guard !views.isEmpty, views.count == rows.count else { return }
        let index = views.firstIndex { $0 === handoffRow } ?? views.count / 2
        let row = views[index]; handoffRow = row
        let origin = rows.compactMap { entry -> Double? in
            handoffRowPositions[list.items[entry.index].identity].map { $0 - entry.y }
        }.first ?? 0
        handoffRowPositions = Dictionary(uniqueKeysWithValues: rows.map { (list.items[$0.index].identity, $0.y + origin) })
        let time = CACurrentMediaTime()
        if let previousHandoff, time <= previousHandoff.time { return }
        let target = owner.layer.presentation() ?? owner.layer
        let rowLayer = row.layer.presentation() ?? row.layer, composerLayer = composer.layer.presentation() ?? composer.layer
        let rect = rowLayer.convert(rowLayer.bounds, to: target)
        let y = Double(rect.maxY) + rows[index].y + origin
        let bar = Double(composerLayer.convert(composerLayer.bounds, to: target).minY)
        if envelopeOrigin == nil {
            let modelRow = Double(row.layer.convert(row.layer.bounds, to: owner.layer).maxY) + rows[index].y + origin
            let modelBar = Double(composer.layer.convert(composer.layer.bounds, to: owner.layer).minY)
            envelopeOrigin = (modelRow, modelBar, time)
        }
        var excess = 0.0
        if let old = previousHandoff {
            let motion = abs((y - old.row) - (followsComposerMotion() ? bar - old.composer : 0))
            excess = max(0, motion - handoffSpeed * max(0, time - old.time))
            maximumHandoffExcess = max(maximumHandoffExcess, excess)
            if previousHandoffMotion <= 0.1 && motion > 1 || excess > 1 {
                catchUps.append(["time": time, "motion": motion, "seconds": time - old.time, "speedExcess": excess, "duplicateBefore": previousHandoffMotion <= 0.1 ? 1 : 0])
            }
            previousHandoffMotion = motion
        }
        if previousHandoff != nil, let start = envelopeOrigin {
            let displacement = abs((y - start.row) - (followsComposerMotion() ? bar - start.composer : 0))
            maximumEnvelopeExcess = max(maximumEnvelopeExcess, displacement - handoffSpeed * (time - start.time))
        }
        if !followsComposerMotion() {
            for (layer, key) in [(list.contentView.layer, "ultraview.list.viewportOffset")] + views.map({ ($0.layer, "ultraview.list.positionY") }) {
                guard let raw = layer.animation(forKey: key) else { continue }
                guard let animation = raw as? CAPropertyAnimation, animation.probeIsSupported else {
                    keyboardSpringCorrect = false; continue
                }
                let values = animation.probeScalarValues
                if let lower = values.min(), let upper = values.max() {
                    maximumDetachedAnimation = max(maximumDetachedAnimation, upper - lower)
                } else { keyboardSpringCorrect = false }
            }
        }
        previousHandoff = (y, bar, time)
        handoffSamples.append(["row": y, "rowMaxY": rect.maxY, "index": Double(rows[index].index), "composer": bar, "time": time, "coastSpeedBound": handoffSpeed, "excess": excess])
    }
    @objc private func sample() {
        guard let owner, let composer, let list, owner.window != nil else { return }
        let started = CACurrentMediaTime()
        defer { MainThreadMonitor.shared.note("keyboard probe sample \((CACurrentMediaTime() - started) * 1000) ms") }
        rememberHeights()
        let keyboardY = (marker.layer.presentation() ?? marker.layer).frame.minY
        let destination = owner.layer.presentation() ?? owner.layer
        let composerLayer = composer.layer.presentation() ?? composer.layer
        let bar = composerLayer.convert(composerLayer.bounds, to: destination)
        recordHandoff()
        let moving = previousKeyboardY.map { abs($0 - keyboardY) > 0.01 } ?? false
        previousKeyboardY = keyboardY; samples += 1
        if moving { movingSamples += 1 }
        if moving, !list.isTracking, let animation = list.contentView.layer.animation(forKey: "ultraview.list.viewportOffset") {
            keyboardSpringSamples += 1
            if let spring = animation as? CASpringAnimation {
                keyboardSpringCorrect = keyboardSpringCorrect && abs(spring.stiffness - 555.027) < 0.001 && abs(spring.damping - 47.118) < 0.001 && spring.mass == 1
            } else if let keyframes = animation as? CAKeyframeAnimation,
                      let transition = keyboardTransition, let curve = transition.viewportCurve,
                      let values = keyframes.values as? [Double], values.count == curve.progress.count,
                      let from = values.first, let to = values.last {
                let matches = zip(values, curve.progress).allSatisfy { abs($0 - (from + (to - from) * $1)) < 1e-6 }
                keyboardSpringCorrect = keyboardSpringCorrect && matches && keyframes.calculationMode == .linear
                    && keyframes.keyTimes == nil && keyframes.timingFunctions == nil
                    && abs(keyframes.duration / Double(keyframes.speed) - transition.duration * list.animationDurationScale) < 1e-6
            } else { keyboardSpringCorrect = false }
        }
        if moving, let previousPassCount { keyboardPasses += list.appliedPassCount - previousPassCount }
        previousPassCount = list.appliedPassCount
        minimumViewportHeight = min(minimumViewportHeight, list.bounds.height)
        maximumViewportHeight = max(maximumViewportHeight, list.bounds.height)
        // During a drag the guide supplies the physical finger position.
        // Pixel captures check the keyboard's separate animated surface.
        if inputIsDragging {
            if moving { trackingComposerSamples += 1 }
            maximumTrackingComposerGap = max(maximumTrackingComposerGap, abs(bar.maxY + 8 - keyboardY))
        }
        if list.isTracking {
            dragSamples += 1; dragMinimum = min(dragMinimum, keyboardY); dragMaximum = max(dragMaximum, keyboardY)
            if list.contentView.layer.animation(forKey: "ultraview.list.viewportOffset") != nil { trackingViewportAnimations += 1 }
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
        let newestGap = list.loadedItemView(at: 0).map { row -> Double in
            let layer = row.layer.presentation() ?? row.layer
            return abs(Double(layer.convert(layer.bounds, to: destination).maxY - bar.minY))
        } ?? -1
        guard started - lastPublish >= 0.1 else { return }
        lastPublish = started
        let catchUpEvents: [[String: Any]] = catchUps.map { event in
            var record: [String: Any] = event
            let time = event["time"] ?? 0
            record["turns"] = handoffTurns.filter { turn in
                turn.startTime <= time + 0.025 && turn.startTime + turn.milliseconds / 1000 >= time - 0.06
            }.map { ["time": $0.startTime, "milliseconds": $0.milliseconds, "notes": $0.notes] as [String: Any] }
            return record
        }
        let observedSeconds = handoffSamples.first.flatMap { first in handoffSamples.last.map { ($0["time"] ?? 0) - (first["time"] ?? 0) } } ?? 0
        var rowBottoms: [String: Double] = [:]
        var firstVisibleRow: String?
        for (entry, row) in zip(list.settledWindow.rows, list.loadedItemViews) {
            let layer = row.layer.presentation() ?? row.layer
            let rect = layer.convert(layer.bounds, to: destination)
            let identity = list.items[entry.index].identity
            rowBottoms[identity] = rect.maxY
            if firstVisibleRow == nil, rect.maxY > 0, rect.minY < bar.minY { firstVisibleRow = identity }
        }
        let document: [String: Any] = [
            "samples": samples, "movingSamples": movingSamples, "dragSamples": dragSamples,
            "trackingComposerGap": maximumTrackingComposerGap, "trackingComposerSamples": trackingComposerSamples,
            "rowGap": maximumRestingRowGap,
            "dragKeyboardTravel": dragMinimum.isFinite ? dragMaximum - dragMinimum : 0,
            "rowAnimationSamples": rowAnimationSamples, "ended": ended, "cancelled": cancelled,
            "releaseVelocity": releaseVelocity, "coast": coast, "keyboardY": keyboardY,
            "flightActive": list.isScrollFlightActive,
            "composerTop": bar.minY, "rowBottoms": rowBottoms, "firstVisibleRow": firstVisibleRow ?? "",
            "trackingViewportAnimations": trackingViewportAnimations,
            "keyboardPasses": keyboardPasses, "viewportHeightChange": maximumViewportHeight - minimumViewportHeight,
            "stoppedReleases": 0, "keyboardSpringSamples": keyboardSpringSamples, "keyboardSpringCorrect": keyboardSpringCorrect,
            "newestSnaps": 0, "newestGap": newestGap, "followsComposer": followsComposerMotion(),
            "firstIndex": list.loadedIndexRange.lowerBound,
            "handoffSamples": Array(handoffSamples.prefix(4)), "releaseFrames": handoffSamples, "handoffExcess": maximumHandoffExcess,
            "handoffEnvelopeExcess": maximumEnvelopeExcess, "detachedAnimationAmplitude": maximumDetachedAnimation,
            "catchUpEvents": catchUpEvents,
            "catchUpsPerSecond": observedSeconds > 0 ? Double(catchUps.filter { $0["duplicateBefore"] == 1 }.count) / observedSeconds : 0,
            "speedExcessEventsPerSecond": observedSeconds > 0 ? Double(catchUps.filter { ($0["speedExcess"] ?? 0) > 1 }.count) / observedSeconds : 0,
            "keyboardHideTime": keyboardHideTime,
            "releasePosition": releasePosition, "position": position(), "decelerating": list.isDecelerating,
            "composerLineHeight": composer.subviews.compactMap { ($0 as? UITextView)?.font?.lineHeight }.first ?? 0,
            "insetP99": insetDurations.isEmpty ? 0 : insetDurations.sorted()[Int(Double(insetDurations.count - 1) * 0.99)],
            "worstRowState": worstRowState, "keyboardInputDrags": keyboardInputDrags,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]) {
            report.accessibilityValue = String(decoding: data, as: UTF8.self)
        }
    }
}
#endif