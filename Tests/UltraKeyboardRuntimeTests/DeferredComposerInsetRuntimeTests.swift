#if canImport(UIKit)
import XCTest
import UIKit
import UltraView
#if canImport(UltraViewDemoApp)
@testable import UltraViewDemoApp
#else
@testable import UltraViewDemo
#endif

@MainActor
final class DeferredComposerInsetRuntimeTests: XCTestCase {
    func testAQueuedInsetCannotOverwriteANewerUpdateAfterThePassEnds() async throws {
        for mode in ScrollEngineMode.allCases { try await checkQueuedInset(mode: mode) }
    }

    private func checkQueuedInset(mode: ScrollEngineMode) async throws {
        let controller = ListChatController(mode: mode)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let oldKey = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer {
            controller.keyboardDismissal?.invalidate(); controller.list.haltScrolling()
            window.isHidden = true; window.rootViewController = nil; oldKey?.makeKeyAndVisible()
        }
        controller.view.layoutIfNeeded()
        let list = controller.list
        for _ in 0..<150 where list.loadedIndexRange.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        list.scrollTo(.init(index: 25), transition: .none)
        for _ in 0..<150 where !list.loadedIndexRange.contains(25) { try await Task.sleep(for: .milliseconds(20)) }
        let bar = try XCTUnwrap(controller.view.subviews.first { $0.accessibilityIdentifier == "composerBar" })
        window.layer.speed = 0; window.layer.timeOffset = 100
        var queued = false
        list.onUserScrollDelta = { _, _ in
            list.onUserScrollDelta = nil; queued = true
            controller.keyboardFrameChanged(height: 150, duration: 0.4, curve: 7)
        }
        list.handleScroll(list.currentScrollOffset)
        XCTAssertTrue(queued)
        // This arrives in the same turn, before the main-queue drain scheduled
        // by handleScroll's defer. It is the newest keyboard state.
        controller.keyboardFrameChanged(height: 300, duration: 0.4, curve: 7)
        let latestInset = list.viewportInsets.top, latestBar = bar.frame
        XCTAssertGreaterThan(latestInset, 300)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(list.viewportInsets.top, latestInset,
                       "\(mode): stale inset \(list.viewportInsets.top) replaced newest \(latestInset)")
        XCTAssertEqual(bar.frame, latestBar,
                       "\(mode): stale accessory \(bar.frame) replaced newest \(latestBar)")
    }

    func testAnInsetReenteredDuringAKeyframedPassWaitsForItsOwnViewportClock() async throws {
        for mode in ScrollEngineMode.allCases { try await checkReenteredInset(mode: mode) }
    }

    private func checkReenteredInset(mode: ScrollEngineMode) async throws {
        let controller = ListChatController(mode: mode)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let oldKey = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer {
            controller.keyboardDismissal?.invalidate(); controller.list.haltScrolling()
            window.isHidden = true; window.rootViewController = nil; oldKey?.makeKeyAndVisible()
        }
        controller.view.layoutIfNeeded()
        let list = controller.list
        for _ in 0..<150 where list.loadedIndexRange.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        list.scrollTo(.init(index: 25), transition: .none)
        for _ in 0..<150 where !list.loadedIndexRange.contains(25) { try await Task.sleep(for: .milliseconds(20)) }
        let row = try XCTUnwrap(list.loadedItemView(at: 25))
        let bar = try XCTUnwrap(controller.view.subviews.first { $0.accessibilityIdentifier == "composerBar" })
        try await Task.sleep(for: .milliseconds(50))
        window.layer.speed = 0; window.layer.timeOffset = 100
        controller.keyboardFrameChanged(height: 252, duration: 1, curve: 7, fullHeight: 335,
                                        physicalBeginHeight: -83, physicalEndHeight: 252)
        XCTAssertTrue(list.contentView.layer.animation(forKey: "ultraview.list.viewportOffset") is CAKeyframeAnimation)
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(40))
        window.layer.timeOffset = 100.15; CATransaction.flush()
        try await Task.sleep(for: .milliseconds(40))
        let priorBar = try XCTUnwrap(bar.layer.presentation())
        let priorRow = try XCTUnwrap(row.layer.presentation())
        let destination = try XCTUnwrap(window.layer.presentation())
        let oldY = priorBar.position.y
        let relative = priorRow.convert(priorRow.bounds, to: destination).maxY
            - priorBar.convert(priorBar.bounds, to: destination).minY
        let priorModelY = bar.frame.midY
        var reentered = false
        list.onUserScrollDelta = { _, _ in
            list.onUserScrollDelta = nil
            reentered = true
            controller.keyboardFrameChanged(height: 150, duration: 0.4, curve: 7, fullHeight: 335)
            XCTAssertEqual(bar.frame.midY, priorModelY, "\(mode): the accessory must wait with the deferred inset")
        }
        list.handleScroll(list.currentScrollOffset)
        XCTAssertTrue(reentered)
        try await Task.sleep(for: .milliseconds(60))
        CATransaction.flush()
        let animation = try XCTUnwrap(composerMotion(bar.layer))
        let first = (animation as? CABasicAnimation)?.fromValue as? Double
            ?? ((animation as? CAKeyframeAnimation)?.values?.first as? Double)
        let initial = try XCTUnwrap(first)
        XCTAssertEqual(initial, oldY - bar.frame.midY, accuracy: 0.5,
                       "\(mode): raw viewport keyframes must not become accessory values")
        for phase in [0.0, 0.1, 0.25, 0.5, 0.8, 1] {
            window.layer.timeOffset = 100.15 + 0.4 * phase; CATransaction.flush()
            try await Task.sleep(for: .milliseconds(35))
            let root = try XCTUnwrap(window.layer.presentation())
            let shownBar = try XCTUnwrap(bar.layer.presentation()), shownRow = try XCTUnwrap(row.layer.presentation())
            let gap = shownRow.convert(shownRow.bounds, to: root).maxY - shownBar.convert(shownBar.bounds, to: root).minY
            XCTAssertEqual(gap, relative, accuracy: 0.5, "\(mode)/\(phase): deferred inset and accessory must share one clock")
        }
    }
}

@MainActor
private func composerMotion(_ layer: CALayer) -> CAPropertyAnimation? {
    layer.animationKeys()?.compactMap { layer.animation(forKey: $0) as? CAPropertyAnimation }
        .first { $0.keyPath == "position.y" }
}
#endif