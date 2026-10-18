#if canImport(UIKit)
import UIKit
import QuartzCore
import Testing
import UltraList

private enum AccessoryCurve: CaseIterable, Equatable {
    case basic, spring, sampled
    var transition: ListTransition {
        switch self {
        case .basic: .easeInOut(1)
        case .spring: .spring(1, damping: 22)
        case .sampled: .init(duration: 1, viewportCurve: .init(progress: [0, 0.1, 0.8, 1]))
        }
    }
}

private enum EmptyAccessoryMotion: CaseIterable, Equatable {
    case show, returning, dismissing
    var transition: ListTransition {
        self == .returning ? .init(duration: 1, curve: .bezier(0.380, 0.700, 0.125, 1)) : .keyboard(1)
    }
}

@MainActor
private struct AccessoryRow: ListRow {
    let identity: String
    func makeView() -> ListRowView { AccessoryRowView() }
    func apply(to view: ListRowView, transition: ListTransition) {}
}

@MainActor
private final class AccessoryRowView: ListRowView {
    override func update(width: Double, transition: ListTransition) -> Double { 60 }
}

@MainActor
private final class AccessoryFixture {
    let window = makeWindow()
    let list: UltraListView
    let accessory = UIView(frame: .init(x: 0, y: 400, width: 300, height: 40))
    init(mode: ScrollEngineMode, empty: Bool = false) async throws {
        list = UltraListView(engineMode: mode)
        window.frame = .init(x: 0, y: 0, width: 390, height: 700)
        list.frame = window.bounds
        window.addSubview(list); window.addSubview(accessory); window.isHidden = false
        list.layoutIfNeeded()
        list.applyChanges(items: empty ? [] : (0..<80).map { AccessoryRow(identity: "row-\($0)") }, newInsets: .init(top: 32), transition: .none)
        if !empty { list.scrollTo(.init(index: 20), transition: .none) }
        try await flush()
        window.layer.speed = 0; window.layer.timeOffset = 100
        try await flush()
    }
    func close() {
        list.applyViewportMotion(to: accessory.layer, keyPath: "position.y", displacement: 0)
        list.applyViewportMotion(to: accessory.layer, keyPath: "bounds.size.height", displacement: 0)
        list.haltScrolling(); window.isHidden = true
    }
    func apply(inset: Double, y: CGFloat, height: CGFloat = 40, transition: ListTransition) {
        let presented = accessory.layer.presentation() ?? accessory.layer
        let oldY = presented.position.y, oldHeight = presented.bounds.height
        CATransaction.begin(); CATransaction.setDisableActions(true)
        list.applyChanges(newInsets: .init(top: inset), transition: transition)
        accessory.frame = .init(x: 0, y: y, width: 300, height: height)
        list.applyViewportMotion(to: accessory.layer, keyPath: "position.y", displacement: Double(oldY - accessory.layer.position.y))
        list.applyViewportMotion(to: accessory.layer, keyPath: "bounds.size.height", displacement: Double(oldHeight - height))
        CATransaction.commit()
    }
    func sample(_ elapsed: Double) async throws {
        try await flush()
        window.layer.timeOffset = 100 + elapsed
        try await flush()
    }
    func motion(_ keyPath: String) -> CAPropertyAnimation? {
        accessory.layer.animationKeys()?.compactMap { accessory.layer.animation(forKey: $0) as? CAPropertyAnimation }
            .first { $0.keyPath == keyPath }
    }
    func flush() async throws {
        CATransaction.flush(); try await Task.sleep(for: .milliseconds(35))
    }
}

@MainActor
@Suite(.serialized) struct ViewportMotionTests {
    @Test(arguments: ScrollEngineMode.allCases, AccessoryCurve.allCases)
    private func scalarPositionAndSizeShareTheViewportCurve(mode: ScrollEngineMode, curve: AccessoryCurve) async throws {
        let fixture = try await AccessoryFixture(mode: mode)
        defer { fixture.close() }
        let layer = fixture.accessory.layer, initialY = layer.position.y, initialHeight = layer.bounds.height
        fixture.apply(inset: 152, y: 280, height: 64, transition: curve.transition)
        let position = try #require(fixture.motion("position.y"))
        let targetY = layer.position.y, targetHeight = layer.bounds.height
        let template = try #require(fixture.list.contentView.layer.animation(forKey: "ultraview.list.viewportOffset") as? CAPropertyAnimation)
        let initial = try #require((template as? CABasicAnimation)?.fromValue as? Double
            ?? ((template as? CAKeyframeAnimation)?.values?.first as? Double))
        #expect(abs(initial) > 1)
        #expect(position.isAdditive)
        #expect(fixture.motion("bounds.size.height")?.isAdditive == true)
        #expect((fixture.motion("position.y") is CASpringAnimation) == (curve == .spring))
        #expect((fixture.motion("position.y") is CAKeyframeAnimation) == (curve == .sampled))
        for elapsed in [0.0, 0.1, 0.25, 0.5, 0.8] {
            try await fixture.sample(elapsed)
            let shown = try #require(layer.presentation())
            let source = try #require(fixture.list.contentView.layer.presentation())
            let residual = Double(source.bounds.origin.y - fixture.list.contentView.layer.bounds.origin.y) / initial
            #expect(abs(Double(shown.position.y - targetY) - Double(initialY - targetY) * residual) <= 0.5)
            #expect(abs(Double(shown.bounds.height - targetHeight) - Double(initialHeight - targetHeight) * residual) <= 0.5)
        }
    }

    @Test(arguments: ScrollEngineMode.allCases, [false, true])
    func aRegrabDuringReleaseUsesThePresentedPositionWithoutANextFrameJump(mode: ScrollEngineMode, dismisses: Bool) async throws {
        let fixture = try await AccessoryFixture(mode: mode)
        defer { fixture.close() }
        fixture.apply(inset: dismisses ? 152 : 212, y: dismisses ? 280 : 220, transition: .easeInOut(1))
        _ = try #require(fixture.motion("position.y"))
        try await fixture.sample(0.3)
        let layer = fixture.accessory.layer, shown = try #require(layer.presentation())
        let presentedY = shown.position.y
        #expect(abs(presentedY - layer.position.y) > 10, "The regrab must interrupt a visible residual")
        // Tracking takes over at the sampled finger position and removes the old flight.
        fixture.apply(inset: fixture.list.viewportInsets.top - 17, y: presentedY - layer.bounds.height / 2, transition: .none)
        #expect(fixture.motion("position.y") == nil)
        try await fixture.sample(0.3 + 1.0 / 60)
        #expect(abs(try #require(layer.presentation()).position.y - presentedY) <= 0.5)
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func aShowInterruptingAHideReplacesTheFlightFromPresentation(mode: ScrollEngineMode) async throws {
        let fixture = try await AccessoryFixture(mode: mode)
        defer { fixture.close() }
        fixture.apply(inset: 152, y: 280, transition: .none)
        try await fixture.flush()
        fixture.apply(inset: 32, y: 400, transition: .easeInOut(1))
        _ = try #require(fixture.motion("position.y"))
        try await fixture.sample(0.25)
        let shownY = try #require(fixture.accessory.layer.presentation()).position.y
        fixture.apply(inset: 212, y: 220, transition: .keyboard(1))
        try await fixture.sample(0.25)
        #expect(abs(try #require(fixture.accessory.layer.presentation()).position.y - shownY) <= 0.5)
        #expect(fixture.accessory.layer.animationKeys()?.count == 1)
        try await fixture.sample(0.25 + 1.0 / 60)
        #expect(try #require(fixture.accessory.layer.presentation()).position.y < shownY)
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func rotationReplacesBothPositionAndSizeFromPresentation(mode: ScrollEngineMode) async throws {
        let fixture = try await AccessoryFixture(mode: mode)
        defer { fixture.close() }
        fixture.apply(inset: 152, y: 280, height: 64, transition: .easeInOut(1))
        _ = try #require(fixture.motion("position.y"))
        try await fixture.sample(0.25)
        let shown = try #require(fixture.accessory.layer.presentation())
        let oldY = shown.position.y, oldHeight = shown.bounds.height
        fixture.list.frame.size = .init(width: 700, height: 390); fixture.list.layoutIfNeeded()
        fixture.apply(inset: 100, y: 210, height: 48, transition: .easeInOut(1))
        try await fixture.sample(0.25)
        let resumed = try #require(fixture.accessory.layer.presentation())
        #expect(abs(resumed.position.y - oldY) <= 0.5)
        #expect(abs(resumed.bounds.height - oldHeight) <= 0.5)
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func repeatedCallsUseTheCommittedClockAndDoNotStack(mode: ScrollEngineMode) async throws {
        let fixture = try await AccessoryFixture(mode: mode)
        defer { fixture.close() }
        fixture.apply(inset: 152, y: 280, transition: .easeInOut(1))
        try await fixture.sample(0.25)
        let animation = try #require(fixture.motion("position.y"))
        let shown = try #require(fixture.accessory.layer.presentation()).position.y
        let displacement = try #require((animation as? CABasicAnimation)?.fromValue as? Double)
        fixture.list.applyViewportMotion(to: fixture.accessory.layer, keyPath: "position.y", displacement: displacement)
        fixture.list.applyViewportMotion(to: fixture.accessory.layer, keyPath: "position.y", displacement: displacement)
        let repeated = try #require(fixture.motion("position.y"))
        #expect(repeated.beginTime == animation.beginTime)
        #expect(repeated.duration == animation.duration && repeated.speed == animation.speed)
        #expect(fixture.accessory.layer.animationKeys()?.count == 1)
        try await fixture.sample(0.25)
        #expect(abs(try #require(fixture.accessory.layer.presentation()).position.y - shown) <= 0.5)
    }

    @Test(arguments: ScrollEngineMode.allCases, [0.0, 0.25, 0.5])
    func aZeroOrSubpixelDisplacementRemovesOnlyThatProperty(mode: ScrollEngineMode, displacement: Double) async throws {
        let fixture = try await AccessoryFixture(mode: mode)
        defer { fixture.close() }
        fixture.apply(inset: 152, y: 280, height: 64, transition: .easeInOut(1))
        _ = try #require(fixture.motion("bounds.size.height"))
        fixture.list.applyViewportMotion(to: fixture.accessory.layer, keyPath: "position.y", displacement: displacement)
        #expect(fixture.motion("position.y") == nil)
        #expect(fixture.motion("bounds.size.height") != nil)
    }

    @Test(arguments: ScrollEngineMode.allCases, [0.0, 0.25])
    func aNoopInsetSnapsEvenWhenAnOlderTemplateIsStillRunning(mode: ScrollEngineMode, change: Double) async throws {
        let fixture = try await AccessoryFixture(mode: mode)
        defer { fixture.close() }
        fixture.apply(inset: 152, y: 280, transition: .easeInOut(1))
        fixture.apply(inset: 152 + change, y: 260, transition: .easeInOut(1))
        #expect(fixture.motion("position.y") == nil)
        try await fixture.sample(1.0 / 60)
        #expect(abs(try #require(fixture.accessory.layer.presentation()).position.y - fixture.accessory.layer.position.y) <= 0.5)
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func anImmediateInsetDoesNotMirrorAnUnrelatedTargetFlight(mode: ScrollEngineMode) async throws {
        let fixture = try await AccessoryFixture(mode: mode)
        defer { fixture.close() }
        fixture.list.scrollTo(.init(index: 40), transition: .easeInOut(1))
        try await fixture.sample(0.1)
        fixture.apply(inset: 152, y: 280, transition: .none)
        #expect(fixture.list.contentView.layer.animation(forKey: "ultraview.list.viewportOffset") != nil,
                "The target's own flight must survive the immediate inset")
        #expect(fixture.motion("position.y") == nil)
        try await fixture.sample(0.1 + 1.0 / 60)
        #expect(abs(try #require(fixture.accessory.layer.presentation()).position.y - fixture.accessory.layer.position.y) <= 0.5)
    }

    @Test(arguments: ScrollEngineMode.allCases, [false, true])
    func aStationaryViewportStillSuppliesTheAccessoryClock(mode: ScrollEngineMode, sampled: Bool) async throws {
        let fixture = try await AccessoryFixture(mode: mode)
        defer { fixture.close() }
        let layer = fixture.accessory.layer, shownY = layer.position.y
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fixture.list.applyChanges(newInsets: .init(top: 152), compensatesInsetChange: false,
                                  transition: sampled ? AccessoryCurve.sampled.transition : .easeInOut(1))
        fixture.accessory.frame.origin.y = 280
        fixture.list.applyViewportMotion(to: layer, keyPath: "position.y", displacement: Double(shownY - layer.position.y))
        CATransaction.commit()
        _ = try #require(fixture.motion("position.y"))
        try await fixture.sample(0.25)
        let progress = sampled ? 0.075 : ListCurve.easeInOut.value(at: 0.25)
        let expected = Double(layer.position.y) + Double(shownY - layer.position.y) * (1 - progress)
        #expect(abs(Double(try #require(layer.presentation()).position.y) - expected) <= 0.5)
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func aCommittedTemplateConvertsIntoTheAccessoryLayerTimebase(mode: ScrollEngineMode) async throws {
        let fixture = try await AccessoryFixture(mode: mode)
        defer { fixture.close() }
        let layer = fixture.accessory.layer
        layer.timeOffset = 7
        fixture.list.applyChanges(newInsets: .init(top: 152), transition: .easeInOut(1))
        try await fixture.flush()
        fixture.list.applyViewportMotion(to: layer, keyPath: "position.y", displacement: 120)
        let template = try #require(fixture.list.contentView.layer.animation(forKey: "ultraview.list.viewportOffset"))
        let animation = try #require(fixture.motion("position.y"))
        #expect(animation.beginTime == layer.convertTime(template.beginTime, from: fixture.list.contentView.layer))
        try await fixture.sample(0.25)
        #expect(abs(Double(try #require(layer.presentation()).position.y - layer.position.y) - 120 * (1 - ListCurve.easeInOut.value(at: 0.25))) <= 0.5)
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func anUnlaidOutListOrImmediateInsetSnapsToTheModel(mode: ScrollEngineMode) async throws {
        let fixture = try await AccessoryFixture(mode: mode)
        defer { fixture.close() }
        fixture.list.applyViewportMotion(to: fixture.accessory.layer, keyPath: "position.y", displacement: 120)
        #expect(fixture.motion("position.y") == nil)
        let unlaidOut = UltraListView(engineMode: mode)
        unlaidOut.applyChanges(newInsets: .init(top: 200), transition: .easeInOut(1))
        unlaidOut.applyViewportMotion(to: fixture.accessory.layer, keyPath: "position.y", displacement: 120)
        #expect(fixture.motion("position.y") == nil)
    }

    @Test(arguments: ScrollEngineMode.allCases, AccessoryCurve.allCases)
    private func aMissingViewportTemplateUsesTheLatestInsetTransition(mode: ScrollEngineMode, curve: AccessoryCurve) async throws {
        for scale in [1.0, 2] {
            let fixture = try await AccessoryFixture(mode: mode)
            defer { fixture.close() }
            fixture.list.animationDurationScale = scale
            let layer = fixture.accessory.layer, initialY = layer.position.y
            CATransaction.begin(); CATransaction.setDisableActions(true)
            fixture.list.applyChanges(newInsets: .init(top: 152), transition: curve.transition)
            fixture.list.finishViewportTransition()
            fixture.accessory.frame.origin.y = 280
            let displacement = Double(initialY - layer.position.y)
            fixture.list.applyViewportMotion(to: layer, keyPath: "position.y", displacement: displacement)
            CATransaction.commit()
            let animation = try #require(fixture.motion("position.y"))
            #expect(fixture.list.contentView.layer.animation(forKey: "ultraview.list.viewportOffset") == nil)
            #expect(animation is CAKeyframeAnimation && animation.isAdditive)
            #expect(abs(animation.duration / Double(animation.speed) - scale) < 1e-6)
            try await fixture.sample(0.25 * scale)
            let transition = curve.transition
            let progress = transition.viewportCurve?.value(at: 0.25) ?? transition.curve.value(at: 0.25, duration: 1)
            #expect(abs(Double(try #require(layer.presentation()).position.y - layer.position.y) - displacement * (1 - progress)) <= 0.5)
        }
    }

    @Test(arguments: ScrollEngineMode.allCases, EmptyAccessoryMotion.allCases)
    private func anEmptyListAnimatesShowReturnAndDismiss(mode: ScrollEngineMode, motion: EmptyAccessoryMotion) async throws {
        for retainedFlight in [false, true] {
            let fixture = try await AccessoryFixture(mode: mode, empty: !retainedFlight)
            defer { fixture.close() }
            if retainedFlight {
                fixture.list.applyChanges(newInsets: .init(top: 62), transition: .easeInOut(3))
                fixture.list.applyChanges(items: [], transition: .none)
            }
            if motion != .show {
                fixture.apply(inset: 152, y: 280, transition: .none)
                try await fixture.flush()
            }
            let initialY = fixture.accessory.layer.position.y
            fixture.apply(inset: motion == .dismissing ? 32 : 212, y: motion == .dismissing ? 400 : 220, transition: motion.transition)
            let animation = try #require(fixture.motion("position.y"))
            #expect(fixture.list.items.isEmpty && fixture.list.loadedIndexRange.isEmpty)
            #expect(animation is CAKeyframeAnimation)
            #expect(animation.duration == motion.transition.duration)
            let targetY = fixture.accessory.layer.position.y
            try await fixture.sample(0.25)
            let expected = Double(initialY - targetY) * (1 - motion.transition.curve.value(at: 0.25, duration: 1))
            #expect(abs(Double(try #require(fixture.accessory.layer.presentation()).position.y - targetY) - expected) <= 0.5)
        }
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func anEmptyListRegrabStartsAtThePresentedPosition(mode: ScrollEngineMode) async throws {
        let fixture = try await AccessoryFixture(mode: mode, empty: true)
        defer { fixture.close() }
        fixture.apply(inset: 152, y: 280, transition: .easeInOut(1))
        _ = try #require(fixture.motion("position.y"))
        try await fixture.sample(0.3)
        let layer = fixture.accessory.layer, shownY = try #require(layer.presentation()).position.y
        #expect(abs(shownY - layer.position.y) > 10)
        fixture.apply(inset: 125, y: shownY - layer.bounds.height / 2, transition: .none)
        try await fixture.sample(0.3 + 1.0 / 60)
        #expect(fixture.motion("position.y") == nil)
        #expect(abs(try #require(layer.presentation()).position.y - shownY) <= 0.5)
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func anEmptyListRepeatKeepsItsCommittedFallbackClock(mode: ScrollEngineMode) async throws {
        let fixture = try await AccessoryFixture(mode: mode, empty: true)
        defer { fixture.close() }
        fixture.apply(inset: 152, y: 280, transition: .easeInOut(1))
        let initial = try #require(fixture.motion("position.y") as? CAKeyframeAnimation)
        let displacement = try #require(initial.values?.first as? Double)
        fixture.list.applyViewportMotion(to: fixture.accessory.layer, keyPath: "position.y", displacement: displacement)
        try await fixture.sample(0.25)
        let animation = try #require(fixture.motion("position.y"))
        let shownY = try #require(fixture.accessory.layer.presentation()).position.y
        fixture.list.applyViewportMotion(to: fixture.accessory.layer, keyPath: "position.y", displacement: displacement)
        #expect(fixture.motion("position.y")?.beginTime == animation.beginTime)
        #expect(fixture.accessory.layer.animationKeys()?.count == 1)
        try await fixture.sample(0.25)
        #expect(abs(try #require(fixture.accessory.layer.presentation()).position.y - shownY) <= 0.5)
    }
}
#endif