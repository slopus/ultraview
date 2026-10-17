import Foundation
import UltraLayout

/// Prefix geometry for collections whose row heights are already known: where items sit along the scroll
/// axis and which of them a viewport shows. It imports no UIKit so the
/// virtualization math is tested on Linux.
public struct ListGeometry: Sendable, Equatable {
    /// Each item's offset from the start of the content, in item order.
    public private(set) var itemOffsets: [CGFloat] = []
    public private(set) var itemExtents: [CGFloat]
    public var spacing: CGFloat

    public init(itemExtents: [CGFloat], spacing: CGFloat = 0) {
        self.itemExtents = itemExtents
        self.spacing = spacing
        var offset: CGFloat = 0
        itemOffsets.reserveCapacity(itemExtents.count)
        for extent in itemExtents {
            itemOffsets.append(offset)
            offset += extent + spacing
        }
    }

    public var contentExtent: CGFloat {
        guard let lastOffset = itemOffsets.last, let lastExtent = itemExtents.last else { return 0 }
        return lastOffset + lastExtent
    }

    /// The indices of the items that intersect `offset ..< offset + length`.
    public func visibleRange(offset: CGFloat, length: CGFloat) -> Range<Int> {
        guard length > 0 else { return 0..<0 }
        let end = offset + length
        let first = firstIndex { itemOffsets[$0] + itemExtents[$0] > offset }
        let last = firstIndex { itemOffsets[$0] >= end }
        return first..<max(first, last)
    }

    /// The first index for which `predicate` holds; it must be monotonic.
    private func firstIndex(where predicate: (Int) -> Bool) -> Int {
        var low = 0
        var high = itemOffsets.count
        while low < high {
            let mid = (low + high) / 2
            if predicate(mid) {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low
    }
}
