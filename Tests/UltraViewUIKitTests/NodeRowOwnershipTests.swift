#if canImport(UIKit)
import UIKit
import Testing
import Synchronization
import UltraCore
import UltraLayout
@testable import UltraList

@MainActor
@Suite(.serialized) struct NodeRowOwnershipTests {
    private struct WeakRoot { weak var value: UltraNode? }
    private final class Roots: Sendable {
        private let state = Mutex<[WeakRoot]>([])
        func record(_ root: UltraNode) { state.withLock { $0.append(.init(value: root)) } }
        var liveCount: Int { state.withLock { $0.filter { $0.value != nil }.count } }
        var createdCount: Int { state.withLock { $0.count } }
    }
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
    @Test func freshRowInstancesReuseListOwnedPreparedContent() async throws {
        let (window, list) = mounted(rows(100)); defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        list.applyChanges(items: rows(100), transition: .none)
        list.scrollTo(.init(index: 50), transition: .none)
        for _ in 0..<100 where list.loadedItemView(at: 50)?.isDisplayReady != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(list.loadedItemView(at: 50)?.isDisplayReady == true)
    }
    @Test func twoListsPrepareIndependentRootsEvenWithTheSameRowModels() async throws {
        let models = rows(100)
        let (firstWindow, first) = mounted(models)
        let (secondWindow, second) = mounted(models)
        defer { firstWindow.isHidden = true; secondWindow.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        let firstHost = try #require(first.loadedItemView(at: 0)?.subviews.compactMap { $0 as? NodeHostView }.first)
        let secondHost = try #require(second.loadedItemView(at: 0)?.subviews.compactMap { $0 as? NodeHostView }.first)
        #expect(firstHost.rootNode !== secondHost.rootNode)
        #expect(firstHost.hasContent && secondHost.hasContent)
    }
    @Test func listOwnedPreparationsSurviveFreshModelsAndRemainBoundedAcrossJumps() async throws {
        let roots = Roots()
        func models() -> [NodeRow] {
            (0..<2_000).map { index in
                NodeRow(identity: "node-\(index)") {
                    let root = UltraNode(style: { var style = Style(); style.height = 60; return style }())
                    roots.record(root); return root
                }
            }
        }
        let originalModels = models()
        let (window, list) = mounted(originalModels); defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(350))
        let before = roots.createdCount
        list.applyChanges(items: models(), transition: .none)
        try await Task.sleep(for: .milliseconds(100))
        #expect(roots.createdCount == before)
        for index in stride(from: 40, through: 800, by: 40) {
            list.scrollTo(.init(index: index), transition: .none)
            for _ in 0..<100 where list.loadedItemView(at: index)?.isDisplayReady != true {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(list.loadedItemView(at: index)?.isDisplayReady == true)
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(list.retainedPreparationCount <= 220)
        #expect(roots.liveCount <= list.retainedPreparationCount + 24)
        list.scrollTo(.init(index: 0), transition: .none)
        for _ in 0..<100 where list.loadedItemView(at: 0)?.isDisplayReady != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(list.loadedItemView(at: 0)?.isDisplayReady == true)
        for index in stride(from: 200, through: 1_800, by: 160) {
            list.scrollTo(.init(index: index), transition: .easeInOut(5))
            for _ in 0..<100 where list.loadedItemView(at: index)?.isDisplayReady != true {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(list.loadedItemView(at: index)?.isDisplayReady == true)
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(list.retainedPreparationCount <= 300)
        #expect(roots.liveCount <= list.retainedPreparationCount + 24)
        list.applyChanges(items: [], transition: .none)
        try await Task.sleep(for: .milliseconds(100))
        #expect(list.retainedPreparationCount == 0)
        #expect(roots.liveCount == 0)
        #expect(!originalModels.isEmpty)
    }
}
#endif