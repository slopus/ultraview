#if canImport(UIKit)
import UIKit
import Testing
@testable import UltraList

@MainActor
private struct HeaderRow: ListRow {
    var identity: String
    var revision: UInt64 = 0
    var header: String?
    var attachments: [String: any ListAttachment] { header.map { ["header": TestHeader(title: $0)] } ?? [:] }
    func makeView() -> ListRowView { HeaderRowView() }
}
@MainActor
private final class HeaderRowView: ListRowView {
    override func update(width: Double, transition: ListTransition) -> Double { 60 }
}
@MainActor
private struct TestHeader: ListAttachment {
    var title: String
    var edge: BoundaryEdge { .top }
    var reservesSpace: Bool { true }
    func makeView() -> ListAttachmentView { HeaderView() }
    func combines(with other: any ListAttachment) -> Bool { (other as? TestHeader)?.title == title }
}
@MainActor
private final class HeaderView: ListAttachmentView {
    override func update(width: Double, transition: ListTransition) -> Double { 30 }
}

@MainActor
@Suite(.serialized) struct ListAttachmentIntegrationTests {
    private func list(_ rows: [HeaderRow]) -> UltraListView {
        let list = UltraListView()
        list.frame = .init(x: 0, y: 0, width: 320, height: 400); list.layoutIfNeeded()
        list.applyChanges(items: rows)
        return list
    }
    @Test func reservationPrecedesTheFirstRowAndClippingAddsNone() {
        let list = list((0..<100).map { HeaderRow(identity: String($0), header: "same") })
        #expect(list.settledFrame(at: 0)?.minY == 30)
        #expect(list.loadedAttachmentViews.count == 1)
        list.scrollTo(.init(index: 50), transition: .immediate)
        #expect(list.settledFrame(at: 50)?.minY == 0)
        #expect(list.settledWindow.rows.allSatisfy { $0.reservedTop == 0 })
    }
    @Test func unchangedParkedHeaderDoesNotAcquireASecondViewportDisplacement() {
        let rows = (0..<100).map { HeaderRow(identity: String($0), header: "same") }
        let list = list(rows)
        list.scrollTo(.init(index: 10), transition: .immediate)
        let header = list.loadedAttachmentViews[0]
        for _ in 0..<8 {
            list.applyChanges(items: rows, transition: .easeInOut(1))
            #expect(header.layer.animation(forKey: "ultraview.list.positionY") == nil)
        }
        list.scrollTo(.init(index: 9), transition: .easeInOut(1))
        let animation = header.layer.animation(forKey: "ultraview.list.positionY") as? CABasicAnimation
        let from = (animation?.fromValue as? NSNumber)?.doubleValue ?? 0
        #expect(abs(from) < 100)
    }
    @Test func genuinelyRemovedKeyFadesAndReleasesItsView() async {
        let rows = (0..<20).map { HeaderRow(identity: String($0), header: "same") }
        let list = autoreleasepool { list(rows) }
        weak var departed = list.loadedAttachmentViews[0]
        var next = rows
        for index in next.indices { next[index].header = nil; next[index].revision += 1 }
        autoreleasepool { list.applyChanges(items: next, transition: .easeInOut(0.03)) }
        #expect(list.loadedAttachmentViews.isEmpty)
        #expect(departed != nil)
        try? await Task.sleep(for: .milliseconds(120))
        #expect(departed == nil)
    }
    @Test func emptyCollectionReleasesAttachmentsImmediately() {
        let list = autoreleasepool { list([HeaderRow(identity: "a", header: "only")]) }
        weak var attachment = list.loadedAttachmentViews.first
        autoreleasepool { list.applyChanges(items: []) }
        #expect(attachment == nil)
        #expect(list.loadedAttachmentViews.isEmpty)
    }
}
#endif