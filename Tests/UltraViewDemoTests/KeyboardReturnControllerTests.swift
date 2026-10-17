#if canImport(UIKit)
import Testing
import UIKit
import UltraView
@testable import UltraList
@testable import UltraViewDemo

private enum KeyboardMotion: CaseIterable {
    case show, hide, cancelledDismissal, interruptedShow
}
private enum KeyboardRetouch: CaseIterable {
    case notification, guide, anotherDrag
}
private enum KeyboardHideCompletion: CaseIterable {
    case zeroDuration, hiddenFrame, didHide
}

@MainActor
@Suite(.serialized) struct KeyboardReturnControllerTests {
    @Test(arguments: ScrollEngineMode.allCases, KeyboardMotion.allCases)
    private func composerAndRowsShareEveryRenderedReturnFrame(mode: ScrollEngineMode, motion: KeyboardMotion) async throws {
        let controller = ListChatController(mode: mode), window = makeWindow()
        window.rootViewController = controller; window.isHidden = false
        defer { controller.list.haltScrolling(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let list = controller.list
        for _ in 0..<150 where list.loadedIndexRange.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        list.scrollTo(.init(index: 25), transition: .none)
        for _ in 0..<150 where !list.loadedIndexRange.contains(25) { try await Task.sleep(for: .milliseconds(20)) }
        let row = try #require(list.loadedItemView(at: 25))
        let bar = try #require(controller.view.subviews.first { $0.accessibilityIdentifier == "composerBar" })
        if motion == .hide || motion == .cancelledDismissal { controller.keyboardFrameChanged(height: 252, duration: 0, curve: 7, fullHeight: 335) }
        try await Task.sleep(for: .milliseconds(50))
        window.layer.speed = 0; window.layer.timeOffset = 100
        var startTime = 100.0
        if motion == .interruptedShow {
            controller.keyboardFrameChanged(height: 252, duration: 0.3833333333333333, curve: 7)
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(35))
            startTime += 0.1; window.layer.timeOffset = startTime
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(35))
        }
        if motion == .cancelledDismissal {
            controller.keyboardDragBegan(height: 252)
            controller.keyboardTrackingLayout(inset: 224, height: 172, inputIsTracking: true, animationDuration: 0)
            controller.keyboardTrackingLayout(inset: 234, height: 182, inputIsTracking: true, animationDuration: 0)
        }
        let rowAtRelease = motion == .interruptedShow ? try #require(row.layer.presentation()) : row.layer
        let barAtRelease = motion == .interruptedShow ? try #require(bar.layer.presentation()) : bar.layer
        let releaseWindow = motion == .interruptedShow ? try #require(window.layer.presentation()) : window.layer
        let releaseRow = rowAtRelease.convert(rowAtRelease.bounds, to: releaseWindow)
        let releaseBar = barAtRelease.convert(barAtRelease.bounds, to: releaseWindow)
        let relative = releaseRow.maxY - releaseBar.minY
        if motion == .cancelledDismissal {
            controller.keyboardTrackingLayout(inset: 304, height: 252, inputIsTracking: false, animationDuration: 0)
            #expect(abs(bar.layer.convert(bar.layer.bounds, to: window.layer).minY - releaseBar.minY) < 0.5)
        }
        controller.keyboardFrameChanged(height: motion == .hide || motion == .interruptedShow ? 0 : 252, duration: 0.3833333333333333, curve: 7, fullHeight: 335)
        if motion == .cancelledDismissal { controller.keyboardDragEnded(height: 252) }
        let animation = try #require(list.contentView.layer.animation(forKey: "ultraview.list.viewportOffset"))
        let duration = animation.duration / Double(animation.speed)
        for frame in 0...24 {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            window.layer.timeOffset = startTime + duration * Double(frame) / 24
            CATransaction.commit(); CATransaction.flush()
            try await Task.sleep(for: .milliseconds(35))
            let destination = try #require(window.layer.presentation())
            let rowLayer = try #require(row.layer.presentation()), barLayer = try #require(bar.layer.presentation())
            let shownRow = rowLayer.convert(rowLayer.bounds, to: destination)
            let shownBar = barLayer.convert(barLayer.bounds, to: destination)
            #expect(abs((shownRow.maxY - shownBar.minY) - relative) < 0.5,
                    "\(mode)/\(motion) frame \(frame): row and composer must share the return clock")
        }
    }

    @Test(arguments: ScrollEngineMode.allCases, [false, true])
    func destinationLayoutBetweenFingerLiftAndDragEndKeepsTheTrackedInset(mode: ScrollEngineMode, fingerStillDown: Bool) async throws {
        let controller = ListChatController(mode: mode)
        let window = makeWindow()
        window.rootViewController = controller; window.isHidden = false
        defer { controller.list.haltScrolling(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let list = controller.list
        for _ in 0..<150 where list.loadedIndexRange.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!list.loadedIndexRange.isEmpty)
        list.scrollTo(.init(index: 25), transition: .none)
        for _ in 0..<150 where !list.loadedIndexRange.contains(25) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(list.loadedIndexRange.contains(25))
        controller.keyboardFrameChanged(height: 252, duration: 0, curve: 7, fullHeight: 335)
        #expect(list.viewportInsets.top == 304)
        controller.keyboardDragBegan(height: 252)
        for height in [244.6666666667, 172, 179.6666666667, 182] {
            controller.keyboardTrackingLayout(inset: height + 52, height: height, inputIsTracking: true, animationDuration: 0)
        }
        let releaseRow = try #require(list.settledFrame(at: 25)).minY
        #expect(list.viewportInsets.top == 234)
        // Recorded order: destination layout, return notification, drag end.
        // The guide already names its target while the drag callback is pending.
        controller.keyboardTrackingLayout(inset: 304, height: 252, inputIsTracking: fingerStillDown, animationDuration: 0)
        #expect(list.viewportInsets.top == (fingerStillDown ? 304 : 234))
        controller.keyboardFrameChanged(height: 252, duration: 0.3833333333333333, curve: 7, fullHeight: 335)
        controller.keyboardDragEnded(height: 252)
        #expect(list.viewportInsets.top == 304)
        let returnedRow = try #require(list.settledFrame(at: 25)).minY
        #expect(abs(returnedRow - releaseRow - (fingerStillDown ? 0 : 70)) < 0.5)
        if !fingerStillDown {
            let animation = try #require(list.contentView.layer.animation(forKey: "ultraview.list.viewportOffset"))
            #expect(abs(animation.duration - 0.3833333333333333 * 70 / 335) < 1e-8)
        }
    }

    @Test(arguments: ScrollEngineMode.allCases, KeyboardRetouch.allCases)
    private func anotherTouchCannotDiscardAnUnresolvedReturn(mode: ScrollEngineMode, retouch: KeyboardRetouch) async throws {
        let controller = ListChatController(mode: mode), window = makeWindow()
        window.rootViewController = controller; window.isHidden = false
        defer { controller.list.haltScrolling(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let list = controller.list
        for _ in 0..<150 where list.loadedIndexRange.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        list.scrollTo(.init(index: 25), transition: .none)
        for _ in 0..<150 where !list.loadedIndexRange.contains(25) { try await Task.sleep(for: .milliseconds(20)) }
        controller.keyboardFrameChanged(height: 300, duration: 0, curve: 7)
        controller.keyboardDragBegan(height: 300)
        controller.keyboardDragChanged(inset: 282, height: 230)
        controller.keyboardDragEnded(height: 230)
        list.onScrollInput?(.init(time: CACurrentMediaTime(), phase: .touchDown))
        if retouch == .anotherDrag {
            controller.keyboardDragBegan(height: 230)
            controller.keyboardDragChanged(inset: 262, height: 210)
            controller.keyboardDragEnded(height: 210)
        }
        let release = try #require(list.settledFrame(at: 25)).minY
        let displacement = retouch == .anotherDrag ? 90.0 : 70.0
        if retouch == .guide {
            controller.keyboardTrackingLayout(inset: 352, height: 300, inputIsTracking: false, animationDuration: 0)
            try await Task.sleep(for: .milliseconds(1))
        } else {
            controller.keyboardFrameChanged(height: 300, duration: 0.25, curve: 7, tracking: retouch == .notification)
        }
        #expect(list.viewportInsets.top == 352)
        let returned = try #require(list.settledFrame(at: 25)).minY
        #expect(abs(returned - release - displacement) < 0.5)
        controller.keyboardFrameChanged(height: 300, duration: 0.25, curve: 7, tracking: false)
        #expect(abs(try #require(list.settledFrame(at: 25)).minY - returned) < 0.5)
    }

    @Test(arguments: ScrollEngineMode.allCases)
    func aHiddenKeyboardUsesTheCurrentSafeAreaAfterRotation(mode: ScrollEngineMode) async throws {
        let controller = ListChatController(mode: mode), window = makeWindow()
        window.rootViewController = controller; window.isHidden = false
        defer { controller.list.haltScrolling(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        for _ in 0..<150 where controller.list.loadedIndexRange.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let bar = try #require(controller.view.subviews.first { $0.accessibilityIdentifier == "composerBar" })
        controller.additionalSafeAreaInsets.bottom = 34
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        controller.keyboardFrameChanged(height: 300, duration: 0, curve: 7, fullHeight: 335)
        controller.keyboardFrameChanged(height: 0, duration: 0, curve: 7, fullHeight: 335)
        #expect(abs(bar.frame.maxY + 8 + controller.view.safeAreaInsets.bottom - controller.view.bounds.maxY) < 0.5)
        controller.additionalSafeAreaInsets.bottom = 0
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        #expect(abs(bar.frame.maxY + 8 + controller.view.safeAreaInsets.bottom - controller.view.bounds.maxY) < 0.5)
        #expect(abs(controller.list.viewportInsets.top - bar.bounds.height - 8 - controller.view.safeAreaInsets.bottom) < 0.5)
    }

    @Test(arguments: ScrollEngineMode.allCases, KeyboardHideCompletion.allCases)
    private func anAlreadyHiddenFrameFinishesTheComposerHide(mode: ScrollEngineMode, completion: KeyboardHideCompletion) async throws {
        let controller = ListChatController(mode: mode), window = makeWindow()
        window.rootViewController = controller; window.isHidden = false
        defer { controller.list.haltScrolling(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        for _ in 0..<150 where controller.list.loadedIndexRange.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let bar = try #require(controller.view.subviews.first { $0.accessibilityIdentifier == "composerBar" })
        controller.keyboardFrameChanged(height: 252, duration: 0, curve: 7, fullHeight: 335)
        controller.keyboardDragBegan(height: 252)
        controller.keyboardDragChanged(inset: 154, height: 102)
        controller.keyboardFrameChanged(height: 0, duration: 0.177, curve: 7, fullHeight: 335)
        controller.keyboardDragEnded(height: 0)
        #expect(bar.layer.animation(forKey: "ultraview.chat.composerPosition") != nil)
        try await Task.sleep(for: .milliseconds(23))
        let releaseOffset = controller.list.currentScrollOffset
        switch completion {
        case .zeroDuration:
            controller.keyboardFrameChanged(height: 0, duration: 0, curve: 7, fullHeight: 233)
        case .hiddenFrame:
            let frame = CGRect(x: 0, y: window.bounds.maxY, width: window.bounds.width, height: 233)
            NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil, userInfo: [
                UIResponder.keyboardFrameBeginUserInfoKey: frame, UIResponder.keyboardFrameEndUserInfoKey: frame,
                UIResponder.keyboardAnimationDurationUserInfoKey: 0.3833333333333333,
                UIResponder.keyboardAnimationCurveUserInfoKey: 7,
            ])
        case .didHide:
            NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        }
        #expect(bar.layer.animation(forKey: "ultraview.chat.composerPosition") == nil)
        #expect(controller.list.contentView.layer.animation(forKey: "ultraview.list.viewportOffset") == nil)
        #expect(abs(bar.frame.maxY + 8 + controller.view.safeAreaInsets.bottom - controller.view.bounds.maxY) < 0.5)
        #expect(abs(controller.list.currentScrollOffset - releaseOffset) < 0.5)
        CATransaction.flush(); try await Task.sleep(for: .milliseconds(35))
        let shown = try #require(bar.layer.presentation()), destination = try #require(controller.view.layer.presentation())
        #expect(abs(shown.convert(shown.bounds, to: destination).maxY - bar.frame.maxY) < 0.5)
    }

    @Test(arguments: ScrollEngineMode.allCases, KeyboardReturnOrder.allCases)
    func notificationOrderDoesNotLoseOrRepeatTheReturn(mode: ScrollEngineMode, order: KeyboardReturnOrder) async throws {
        for velocity in [0.0, -600, 600] {
            let flying = velocity != 0
            let controller = ListChatController(mode: mode)
            let window = makeWindow()
            window.rootViewController = controller; window.isHidden = false
            defer { controller.list.haltScrolling(); window.isHidden = true; window.rootViewController = nil }
            controller.view.layoutIfNeeded()
            let list = controller.list
            for _ in 0..<150 where list.loadedIndexRange.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
            #expect(!list.loadedIndexRange.isEmpty)
            list.scrollTo(.init(index: 25), transition: .none)
            for _ in 0..<150 where !list.loadedIndexRange.contains(25) { try await Task.sleep(for: .milliseconds(20)) }
            #expect(list.loadedIndexRange.contains(25))
            controller.keyboardFrameChanged(height: 300, duration: 0, curve: 7)
            let initialInset = list.viewportInsets.top
            let start = try #require(list.settledFrame(at: 25)).minY
            let time = CACurrentMediaTime()
            list.receiveScrollInput(.init(time: time, phase: .began))
            controller.keyboardDragBegan(height: 300)
            controller.keyboardDragChanged(inset: initialInset - 80, height: 220)
            list.receiveScrollInput(.init(time: time + 0.1, phase: .changed, translation: .init(y: -80)))
            if order == .beforeLastMovement { controller.keyboardFrameChanged(height: 300, duration: 0.25, curve: 7) }
            controller.keyboardDragChanged(inset: initialInset - 70, height: 230)
            list.receiveScrollInput(.init(time: time + 0.2, phase: .changed, translation: .init(y: -70)))
            controller.keyboardDragChanged(inset: initialInset - 69.75, height: 230.25)
            #expect(abs(list.viewportInsets.top - initialInset + 70) < 1e-8)
            let trackedRow = try #require(list.settledFrame(at: 25)).minY
            #expect(abs(trackedRow - start + 70) < 0.5, "No inset compensation while tracking")
            if order == .beforeEnd || order == .duplicateBeforeEnd || order == .targetLayoutBeforeEnd {
                controller.keyboardFrameChanged(height: 300, duration: 0.25, curve: 7)
                if order == .duplicateBeforeEnd { controller.keyboardFrameChanged(height: 300, duration: 0.25, curve: 7) }
                if order == .targetLayoutBeforeEnd { controller.keyboardDragChanged(inset: initialInset, height: 300) }
            }
            if order == .guideBeforeEnd {
                UIView.animate(withDuration: 0.35) { #expect(!controller.keyboardGuideChanged(height: 300)) }
                controller.keyboardDragChanged(inset: initialInset, height: 300)
            }
            if order == .trackingNotificationAfterReturn {
                controller.keyboardFrameChanged(height: 300, duration: 0.35, curve: 7)
                controller.keyboardFrameChanged(height: 230, duration: 0, curve: 7)
            }
            var observedFlight: ScrollFlight?
            let flightChanged = list.engine.onFlightChanged
            list.engine.onFlightChanged = { value in observedFlight = value; flightChanged?(value) }
            if flying { list.beginMomentum(velocity: velocity) } else { list.haltScrolling() }
            let releaseRow = try #require(list.settledFrame(at: 25)).minY
            let releaseOffset = list.currentScrollOffset
            let flight = list.engine.activeFlight
            let releasePrediction = observedFlight
            controller.keyboardDragEnded(height: 230)
            if order == .guideOnly || order == .guideBeforeEnd { controller.keyboardGuideChanged(height: 300) }
            else { controller.keyboardFrameChanged(height: 300, duration: 0.25, curve: 7) }
            if order == .duplicateAfterEnd {
                let beforeDuplicate = try #require(list.settledFrame(at: 25)).minY
                controller.keyboardFrameChanged(height: 300, duration: 0.25, curve: 7)
                if !flying { #expect(abs(try #require(list.settledFrame(at: 25)).minY - beforeDuplicate) < 0.5) }
            }
            if order == .guideOnly { try await Task.sleep(for: .milliseconds(1)) }
            #expect(abs(list.viewportInsets.top - initialInset) < 1e-8)
            let returnedRow = try #require(list.settledFrame(at: 25)).minY
            #expect(list.isDecelerating == flying)
            let animation = try #require(list.contentView.layer.animation(forKey: "ultraview.list.viewportOffset") as? CABasicAnimation)
            #expect(abs((animation.fromValue as? Double ?? 0) - 70) < 0.5,
                    "\(mode)/\(order)/flying=\(flying): return must invert only the tracked inset")
            if !flying { #expect(abs(returnedRow - releaseRow - 70) < 0.5) }
            let duration = order == .trackingNotificationAfterReturn || order == .guideBeforeEnd ? 0.35 : 0.25
            #expect(abs(animation.duration - duration * 70 / 300) < 1e-8)
            if let flight, let returned = list.engine.activeFlight {
                let time = flight.beginTime + 0.05
                let translation = returned.offset(at: time) - flight.offset(at: time)
                let actualMotion = translation - (list.currentScrollOffset - releaseOffset)
                #expect(abs(returnedRow - releaseRow - actualMotion - 70) < 0.5)
                // Compare the flight at fixed times: resolving on the next turn
                // can legitimately advance its sampled model offset.
                let before = flight.offset(at: time + 0.05) - flight.offset(at: time)
                let after = returned.offset(at: time + 0.05) - returned.offset(at: time)
                #expect(abs(after - before) < 1e-6)
            }
            if mode == .uiKit, flying {
                let prediction = try #require(releasePrediction)
                let expected = prediction.coveredOffsets(at: CACurrentMediaTime(), horizon: 0.05)
                let actual = try #require(list.engine.coveredOffsets(horizon: 0.05))
                #expect(actual.upperBound - actual.lowerBound > 10)
                #expect(abs((actual.upperBound - actual.lowerBound) - (expected.upperBound - expected.lowerBound)) < 0.5,
                        "The release keeps the existing 600 pt/s flight's deceleration")
            }
        }
    }

    private func makeWindow() -> UIWindow {
        // These tests run without an app or a window scene.
        let window = (UIWindow.self as NSObject.Type).init() as! UIWindow
        window.frame = .init(x: 0, y: 0, width: 402, height: 604)
        return window
    }
}
#endif