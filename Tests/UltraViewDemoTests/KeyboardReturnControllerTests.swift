#if canImport(UIKit)
import Testing
import UIKit
import UltraView
@testable import UltraList
@testable import UltraViewDemo

@MainActor
@Suite(.serialized) struct KeyboardReturnControllerTests {
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
        controller.keyboardFrameChanged(height: 252, duration: 0, curve: 7)
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
        controller.keyboardFrameChanged(height: 252, duration: 0.3833333333333333, curve: 7)
        controller.keyboardDragEnded(height: 252)
        #expect(list.viewportInsets.top == 304)
        let returnedRow = try #require(list.settledFrame(at: 25)).minY
        #expect(abs(returnedRow - releaseRow - (fingerStillDown ? 0 : 70)) < 0.5)
        if !fingerStillDown {
            let animation = try #require(list.contentView.layer.animation(forKey: "ultraview.list.viewportOffset"))
            #expect(abs(animation.duration - 0.3833333333333333) < 1e-8)
        }
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
            if flying { list.beginMomentum(velocity: velocity) } else { list.haltScrolling() }
            let releaseRow = try #require(list.settledFrame(at: 25)).minY
            let releaseOffset = list.currentScrollOffset
            let flight = list.engine.activeFlight
            controller.keyboardDragEnded(height: 230)
            if order == .guideOnly || order == .guideBeforeEnd { controller.keyboardGuideChanged(height: 300) }
            else { controller.keyboardFrameChanged(height: 300, duration: 0.25, curve: 7) }
            if order == .duplicateAfterEnd { controller.keyboardFrameChanged(height: 300, duration: 0.25, curve: 7) }
            #expect(abs(list.viewportInsets.top - initialInset) < 1e-8)
            let returnedRow = try #require(list.settledFrame(at: 25)).minY
            #expect(abs(returnedRow - releaseRow - 70) < 0.5,
                    "\(mode)/\(order)/flying=\(flying): return must invert only the tracked inset")
            #expect(list.isDecelerating == flying)
            let animation = try #require(list.contentView.layer.animation(forKey: "ultraview.list.viewportOffset"))
            let duration = order == .trackingNotificationAfterReturn || order == .guideBeforeEnd ? 0.35 : 0.25
            #expect(abs(animation.duration - duration) < 1e-8)
            if let flight, let returned = list.engine.activeFlight {
                let before = flight.offset(at: flight.beginTime + 0.05) - releaseOffset
                let after = returned.offset(at: flight.beginTime + 0.05) - list.currentScrollOffset
                #expect(abs(after - before) < 0.5)
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