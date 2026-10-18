#if canImport(UIKit)
import Testing
import UIKit
import UltraView
@testable import UltraList
@testable import UltraViewDemo

/// The chat lands its inset correction when the keyboard reports it has
/// hidden. A status bar tap made while the keyboard goes down keeps scrolling
/// through that report, and lands on the oldest loaded message.
@MainActor
@Suite(.serialized) struct ChatScrollToTopTests {
    @Test(arguments: ScrollEngineMode.allCases)
    func theKeyboardFinishingItsHideLeavesAScrollToTheTopRunning(mode: ScrollEngineMode) async throws {
        let controller = ListChatController(mode: mode), window = makeWindow()
        window.rootViewController = controller; window.isHidden = false
        defer { controller.list.haltScrolling(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let list = controller.list
        for _ in 0..<150 where list.loadedIndexRange.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        list.scrollTo(.init(index: 25), transition: .none)
        for _ in 0..<150 where !list.loadedIndexRange.contains(25) { try await Task.sleep(for: .milliseconds(20)) }
        controller.keyboardFrameChanged(height: 252, duration: 0, curve: 7, fullHeight: 335)
        try await Task.sleep(for: .milliseconds(50))
        var landings = 0
        list.didScrollToTop = { landings += 1 }
        // Stopped time: the keyboard starts down, and 0.2 s later the status
        // bar is tapped.
        window.layer.speed = 0; window.layer.timeOffset = 100
        controller.keyboardFrameChanged(height: 0, duration: 0.3833333333333333, curve: 7, fullHeight: 335,
                                        physicalBeginHeight: 252, physicalEndHeight: -83)
        window.layer.timeOffset = 100.2
        list.statusBarTapped()
        let oldest = list.items.count - 1
        for _ in 0..<150 where list.settledFrame(at: oldest) == nil { try await Task.sleep(for: .milliseconds(20)) }
        // The keyboard is down, and says so while the list still scrolls.
        window.layer.timeOffset = 100.39
        let before = try #require(list.presentedFrame(at: oldest))
        let settled = try #require(list.settledFrame(at: oldest))
        #expect(abs(before.minY - settled.minY) > 5, "\(mode): already at the top")
        controller.keyboardFrameChanged(height: 0, duration: 0, curve: 7, finishesHide: true)
        let after = try #require(list.presentedFrame(at: oldest))
        #expect(abs(after.minY - before.minY) < 0.5, "\(mode): jumped from \(before.minY) to \(after.minY)")
        #expect(list.contentView.layer.animation(forKey: "ultraview.list.viewportOffset") != nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(landings == 0, "\(mode): reported landing mid-scroll")
        // Upside down, the oldest message rests on the top of the list.
        window.layer.timeOffset = 102
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(100))
        let row = try #require(list.loadedItemView(at: oldest)?.layer.presentation())
        let destination = try #require(window.layer.presentation()), shownList = try #require(list.layer.presentation())
        let shown = row.convert(row.bounds, to: destination), top = shownList.convert(shownList.bounds, to: destination).minY
        #expect(abs(shown.minY - top) < 0.5, "\(mode): the oldest message rests at \(shown.minY), the list's top is \(top)")
        for _ in 0..<100 where landings == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(landings == 1)
    }

    private func makeWindow() -> UIWindow {
        // These tests run without an app or a window scene.
        let window = (UIWindow.self as NSObject.Type).init() as! UIWindow
        window.frame = .init(x: 0, y: 0, width: 402, height: 604)
        return window
    }
}
#endif
