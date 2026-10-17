import Foundation

public struct ListInsets: Sendable, Equatable, Codable {
    public var top: Double
    public var left: Double
    public var bottom: Double
    public var right: Double
    public init(top: Double = 0, left: Double = 0, bottom: Double = 0, right: Double = 0) {
        self.top = top; self.left = left; self.bottom = bottom; self.right = right
    }
}

public struct ListViewport: Sendable, Equatable {
    public var width: Double
    public var height: Double
    public var insets: ListInsets
    public var contentWidth: Double { max(0, width - insets.left - insets.right) }
    public var visibleHeight: Double { max(0, height - insets.top - insets.bottom) }
    public init(width: Double, height: Double, insets: ListInsets = .init()) {
        self.width = width; self.height = height; self.insets = insets
    }
}

public struct WindowRow: Sendable, Equatable {
    public var index: Int
    public var y: Double
    public var height: Double
    public var reservedTop: Double
    public var reservedBottom: Double
    public var maxY: Double { y + height }
    public var bandTop: Double { y - reservedTop }
    public var bandBottom: Double { maxY + reservedBottom }
    public init(index: Int, y: Double, height: Double, reservedTop: Double = 0, reservedBottom: Double = 0) {
        self.index = index; self.y = y; self.height = height
        self.reservedTop = reservedTop; self.reservedBottom = reservedBottom
    }
}

/// A settled contiguous slice. No frame changes as a function of scrolling.
public struct ListWindow: Sendable, Equatable {
    public var rows: [WindowRow]
    public var minY: Double { rows.first?.bandTop ?? 0 }
    public var maxY: Double { rows.last?.bandBottom ?? 0 }
    public var height: Double { maxY - minY }
    public var range: Range<Int> { (rows.first?.index ?? 0)..<((rows.last?.index).map { $0 + 1 } ?? 0) }
    public init(rows: [WindowRow] = []) { self.rows = rows }
    public mutating func translate(by delta: Double) { for index in rows.indices { rows[index].y += delta } }
    public func pinSlack(index: Int?, viewport: ListViewport) -> Double {
        guard range.lowerBound == 0, let index, let row = rows.first(where: { $0.index == index }) else { return 0 }
        let extensionHeight = max(0, row.height - viewport.visibleHeight / 2)
        return max(0, viewport.visibleHeight + extensionHeight - (row.maxY - minY))
    }
    public func edges(origin: Double, count: Int, viewport: ListViewport, pinnedIndex: Int? = nil) -> ScrollEdges {
        guard !rows.isEmpty else { return .init(minimum: 0, maximum: 0) }
        return .init(
            minimum: range.lowerBound == 0 ? origin - viewport.insets.top - pinSlack(index: pinnedIndex, viewport: viewport) : nil,
            maximum: range.upperBound == count ? origin + height + viewport.insets.bottom - viewport.height : nil
        )
    }

    /// Missing measurements terminate traversal and leave that edge open.
    public static func build(count: Int, anchor: Int, viewport: ListViewport, margin: Double = 160, pinnedIndex: Int? = nil, pinsLoadedTop: Bool = false, slackBaseline: Double? = nil, measure: (Int) -> (height: Double, top: Double, bottom: Double)?, resolveY: (Double) -> Double) -> ListWindow {
        guard anchor >= 0, anchor < count, viewport.contentWidth > 0, viewport.height > 0,
              let measured = measure(anchor) else { return .init() }
        func row(_ index: Int, _ y: Double, _ m: (height: Double, top: Double, bottom: Double)) -> WindowRow {
            precondition(m.height.isFinite && m.height >= 0 && m.top >= 0 && m.bottom >= 0)
            return WindowRow(index: index, y: y, height: m.height, reservedTop: m.top, reservedBottom: m.bottom)
        }
        var result = ListWindow(rows: [row(anchor, resolveY(measured.height), measured)])
        func prepend() -> Bool {
            guard let first = result.rows.first, first.index > 0, let m = measure(first.index - 1) else { return false }
            result.rows.insert(row(first.index - 1, first.bandTop - m.bottom - m.height, m), at: 0)
            return true
        }
        func append() -> Bool {
            guard let last = result.rows.last, last.index + 1 < count, let m = measure(last.index + 1) else { return false }
            result.rows.append(row(last.index + 1, last.bandBottom + m.top, m))
            return true
        }
        while result.minY > -margin { if !prepend() { break } }
        if result.range.lowerBound == 0, let pinnedIndex {
            while result.range.upperBound <= pinnedIndex && result.height < viewport.visibleHeight { if !append() { break } }
        }
        let slack = result.pinSlack(index: pinnedIndex, viewport: viewport)
        let top = viewport.insets.top + slack
        if pinsLoadedTop && result.range.lowerBound == 0 { result.translate(by: top - result.minY) }
        else {
            if let slackBaseline { result.translate(by: slack - slackBaseline) }
            if result.range.lowerBound == 0 && result.minY > top { result.translate(by: top - result.minY) }
        }
        while result.maxY < viewport.height + margin { if !append() { break } }
        let bottom = viewport.height - viewport.insets.bottom
        if result.range.upperBound == count, result.maxY < bottom {
            if result.range.lowerBound == 0 && result.height <= viewport.visibleHeight { result.translate(by: top - result.minY) }
            else {
                result.translate(by: bottom - result.maxY)
                while result.minY > -margin { if !prepend() { break } }
                if result.range.lowerBound == 0 && (result.height <= viewport.visibleHeight || result.minY > top) {
                    result.translate(by: top - result.minY)
                }
            }
        }
        return result
    }

    /// Rebalances in the old frame coordinate; the caller shifts the engine by the change in base.
    public mutating func rebalance(count: Int, offsetInFrameSpace: Double, viewportHeight: Double, margin: Double = 160, coveredOffsets: ClosedRange<Double>? = nil, maximumAdditionalRows: Int? = nil, measure: (Int) -> (height: Double, top: Double, bottom: Double)?) {
        let low = min(offsetInFrameSpace, coveredOffsets?.lowerBound ?? offsetInFrameSpace) - margin
        let high = max(offsetInFrameSpace, coveredOffsets?.upperBound ?? offsetInFrameSpace) + viewportHeight + margin
        var remaining = max(0, maximumAdditionalRows ?? Int.max)
        while rows.count > 1 && rows[0].bandBottom < low { rows.removeFirst() }
        while rows.count > 1 && rows.last!.bandTop > high { rows.removeLast() }
        while let first = rows.first, first.bandTop > low, first.index > 0 {
            guard remaining > 0 else { break }; remaining -= 1
            guard let m = measure(first.index - 1) else { break }
            rows.insert(.init(index: first.index - 1, y: first.bandTop - m.bottom - m.height, height: m.height, reservedTop: m.top, reservedBottom: m.bottom), at: 0)
        }
        while let last = rows.last, last.bandBottom < high, last.index + 1 < count {
            guard remaining > 0 else { break }; remaining -= 1
            guard let m = measure(last.index + 1) else { break }
            rows.append(.init(index: last.index + 1, y: last.bandBottom + m.top, height: m.height, reservedTop: m.top, reservedBottom: m.bottom))
        }
    }
}