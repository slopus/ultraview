#if canImport(UIKit)
import Testing
import UIKit
import UltraView
@testable import UltraViewDemo

@MainActor
@Suite(.serialized) struct DeferredComposerInsetTests {
    @Test(arguments: ScrollEngineMode.allCases)
    func anInsetReenteredDuringAKeyframedPassWaitsForItsOwnViewportClock(mode: ScrollEngineMode) async throws {
        let controller = ListChatController(mode: mode)
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        } else { window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844)) }
        window.rootViewController = controller; window.isHidden = false
        defer { controller.list.haltScrolling(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let list = controller.list
        for _ in 0..<150 where list.loadedIndexRange.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        list.scrollTo(.init(index: 25), transition: .none)
        for _ in 0..<150 where !list.loadedIndexRange.contains(25) { try await Task.sleep(for: .milliseconds(20)) }
        let row = try #require(list.loadedItemView(at: 25))
        let bar = try #require(controller.view.subviews.first { $0.accessibilityIdentifier == "composerBar" })
        try await Task.sleep(for: .milliseconds(50))
        window.layer.speed = 0; window.layer.timeOffset = 100
        controller.keyboardFrameChanged(height: 252, duration: 1, curve: 7, fullHeight: 335,
                                        physicalBeginHeight: -83, physicalEndHeight: 252)
        #expect(list.contentView.layer.animation(forKey: "ultraview.list.viewportOffset") is CAKeyframeAnimation)
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(40))
        window.layer.timeOffset = 100.15; CATransaction.flush()
        try await Task.sleep(for: .milliseconds(40))
        let priorBar = try #require(bar.layer.presentation())
        let priorRow = try #require(row.layer.presentation())
        let destination = try #require(window.layer.presentation())
        let oldY = priorBar.position.y
        let relative = priorRow.convert(priorRow.bounds, to: destination).maxY
            - priorBar.convert(priorBar.bounds, to: destination).minY
        let priorModelY = bar.frame.midY
        var reentered = false
        list.onUserScrollDelta = { _, _ in
            list.onUserScrollDelta = nil
            reentered = true
            controller.keyboardFrameChanged(height: 150, duration: 0.4, curve: 7, fullHeight: 335)
            #expect(bar.frame.midY == priorModelY, "\(mode): the accessory must wait with the deferred inset")
        }
        list.handleScroll(list.currentScrollOffset)
        #expect(reentered)
        try await Task.sleep(for: .milliseconds(60))
        CATransaction.flush()
        let animation = try #require(bar.layer.animation(forKey: "ultraview.chat.composerPosition") as? CAPropertyAnimation)
        let first = (animation as? CABasicAnimation)?.fromValue as? Double
            ?? ((animation as? CAKeyframeAnimation)?.values?.first as? Double)
        let initial = try #require(first)
        #expect(abs(initial - (oldY - bar.frame.midY)) < 0.5,
                "\(mode): composer initial \(initial), expected \(oldY - bar.frame.midY); raw viewport keyframes must not become accessory values")
        for phase in [0.0, 0.1, 0.25, 0.5, 0.8, 1] {
            window.layer.timeOffset = 100.15 + 0.4 * phase; CATransaction.flush()
            try await Task.sleep(for: .milliseconds(35))
            let root = try #require(window.layer.presentation())
            let shownBar = try #require(bar.layer.presentation()), shownRow = try #require(row.layer.presentation())
            let gap = shownRow.convert(shownRow.bounds, to: root).maxY - shownBar.convert(shownBar.bounds, to: root).minY
            #expect(abs(gap - relative) < 0.5, "\(mode)/\(phase): deferred inset and accessory must share one clock")
        }
    }
}
#endif