#if canImport(UIKit)
import UIKit
import Testing
import UltraCore
import UltraLayout
@testable import UltraList

@MainActor
@Suite(.serialized) struct NodeRowOwnershipTests {
    private func rows(_ count: Int) -> [NodeRow] {
        (0..<count).map { index in
            NodeRow(identity: "node-\(index)") {
                UltraNode(style: { var style = Style(); style.height = 60; return style }())
            }
        }
    }
    private func mounted(_ rows: [NodeRow]) -> (UIWindow, UltraListView) {
        let window = makeWindow()
        window.frame = .init(x: 0, y: 0, width: 320, height: 480)
        let controller = UIViewController(); window.rootViewController = controller; window.isHidden = false
        let list = UltraListView(); list.frame = controller.view.bounds
        controller.view.addSubview(list); list.layoutIfNeeded()
        list.applyChanges(items: rows, transition: .none)
        return (window, list)
    }
    @Test func jumpingBackIntoALiveCarouselReusesThePreparedHost() async throws {
        let (window, list) = mounted(rows(200)); defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        list.scrollTo(.init(index: 150), transition: .none)
        try await Task.sleep(for: .milliseconds(250))
        list.scrollTo(.init(index: 0), transition: .none)
        try await Task.sleep(for: .milliseconds(150))
        list.scrollTo(.init(index: 150), transition: .easeInOut(1.2))
        list.scrollTo(.init(index: 0), transition: .easeInOut(1.2))
        list.scrollTo(.init(index: 150), transition: .none)
        try await Task.sleep(for: .milliseconds(100))
        #expect(list.loadedIndexRange.contains(150))
        #expect(!list.loadedItemViews.isEmpty)
    }
    @Test func reinsertingTheSameNodeDuringItsExitKeepsOneLiveHost() async throws {
        let items = rows(20)
        let (window, list) = mounted(items); defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        list.applyChanges(items: Array(items.dropFirst()), transition: .easeInOut(0.5))
        list.applyChanges(items: items, transition: .easeInOut(0.5))
        try await Task.sleep(for: .milliseconds(100))
        #expect(list.items.first?.identity == "node-0")
        #expect(list.loadedItemView(at: 0)?.isDisplayReady == true)
    }
    @Test func freshRowInstancesPrepareTheirOwnContentOnACachedHeight() async throws {
        let (window, list) = mounted(rows(100)); defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        list.applyChanges(items: rows(100), transition: .none)
        list.scrollTo(.init(index: 50), transition: .none)
        for _ in 0..<100 where list.loadedItemView(at: 50)?.isDisplayReady != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(list.loadedItemView(at: 50)?.isDisplayReady == true)
    }
}
#endif