import Foundation
import UltraLayout
import Testing
import UltraList

@Suite struct ListGeometryTests {
    let geometry = ListGeometry(itemExtents: [50, 100, 30, 70], spacing: 10)

    @Test func offsetsAccumulateExtentsAndSpacing() {
        #expect(geometry.itemOffsets == [0, 60, 170, 210])
        #expect(geometry.contentExtent == 280)
    }

    @Test(arguments: [
        (0.0, 50.0, 0..<1),
        (0.0, 61.0, 0..<2),
        (50.0, 10.0, 1..<1),
        (55.0, 200.0, 1..<4),
        (175.0, 10.0, 2..<3),
        (300.0, 100.0, 4..<4),
        (-100.0, 101.0, 0..<1),
    ] as [(CGFloat, CGFloat, Range<Int>)])
    func visibleRange(offset: CGFloat, length: CGFloat, expected: Range<Int>) {
        #expect(geometry.visibleRange(offset: offset, length: length) == expected)
    }

    @Test func emptyList() {
        let empty = ListGeometry(itemExtents: [])
        #expect(empty.contentExtent == 0)
        #expect(empty.visibleRange(offset: 0, length: 100) == 0..<0)
    }
}
