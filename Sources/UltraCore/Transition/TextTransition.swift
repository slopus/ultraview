import Foundation
import UltraLayout

/// One laid-out line of a text node, in the node's view coordinates.
public struct TextLineBox: Sendable, Equatable {
    /// The line box: x from the glyphs' start to their end (trailing
    /// whitespace excluded), y from the line's top to its bottom.
    public var rect: CGRect
    /// UTF-16 range of the source string on this line.
    public var range: Range<Int>
    /// Identifies the line's characters and their styles.
    public var fingerprint: UInt64

    public init(rect: CGRect, range: Range<Int>, fingerprint: UInt64) {
        self.rect = rect
        self.range = range
        self.fingerprint = fingerprint
    }
}

/// What a text node's bitmap shows, line by line, as the main thread needs
/// it to animate a change of text.
public struct TextTransitionLines: Sendable, Equatable {
    public var string: String
    public var lines: [TextLineBox]
    /// Lines start at the same x, so a line's prefix stays where it was when
    /// the line grows or shrinks.
    public var isLeftAligned: Bool

    public init(string: String, lines: [TextLineBox], isLeftAligned: Bool) {
        self.string = string
        self.lines = lines
        self.isLeftAligned = isLeftAligned
    }

    /// The fingerprint `TextLineBox` uses: the line's UTF-16 units and the
    /// runs that style them, relative to the line's start.
    static func fingerprint(of range: Range<Int>, units: [UInt16], text: AttributedText, truncated: Bool) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(range.count)
        hasher.combine(truncated)
        let upper = min(range.upperBound, units.count)
        if range.lowerBound < upper {
            for unit in units[range.lowerBound..<upper] {
                hasher.combine(unit)
            }
        }
        for run in text.runs where run.range.overlaps(range) {
            hasher.combine(max(run.range.lowerBound, range.lowerBound) - range.lowerBound)
            hasher.combine(min(run.range.upperBound, range.upperBound) - range.lowerBound)
            hasher.combine(run.style)
            hasher.combine(run.link)
        }
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }
}

/// How a text node's bitmap goes from old text to new: which parts of the
/// new bitmap show at once, which fade in, and which parts of the old bitmap
/// fade out over it.
///
/// Lines that didn't change are stable. A line that kept its start and grew
/// or shrank keeps its common prefix stable (for left-aligned text); its
/// new tail fades in and its old tail fades out. Everything after the first
/// line that changed otherwise crossfades: the new lines fade in, the old
/// ones fade out. Appending to the end of a text therefore only fades in
/// the appended glyphs.
///
/// Regions are bands spanning far beyond the node horizontally, and the
/// first and last bands reach far above and below it, so glyphs that
/// overhang their line boxes are covered.
public struct TextTransitionPlan: Sendable, Equatable {
    public struct Reveal: Sendable, Equatable {
        /// New view coordinates.
        public var rect: CGRect
        /// The opacity the region starts at; it ends at 1.
        public var fromOpacity: CGFloat

        public init(rect: CGRect, fromOpacity: CGFloat) {
            self.rect = rect
            self.fromOpacity = fromOpacity
        }
    }

    /// New view coordinates: the new bitmap shows here at once.
    public var stable: [CGRect]
    /// New view coordinates: the new bitmap fades in here.
    public var reveals: [Reveal]
    /// Old view coordinates: the old bitmap fades out here.
    public var fadeOut: [CGRect]

    public init(stable: [CGRect], reveals: [Reveal], fadeOut: [CGRect]) {
        self.stable = stable
        self.reveals = reveals
        self.fadeOut = fadeOut
    }

    /// Nothing animates.
    public var isIdentity: Bool { reveals.isEmpty && fadeOut.isEmpty }

    /// How far regions reach beyond the node.
    public static let outset: CGFloat = 10_000

    /// Plans the change from `old` to `new`. `inFlight` are regions of the
    /// old bitmap still fading in from an earlier change (in view
    /// coordinates, with their current opacity); where they fall on stable
    /// text they keep fading in from where they are instead of jumping to
    /// opaque.
    public static func plan(
        from old: TextTransitionLines,
        to new: TextTransitionLines,
        inFlight: [Reveal] = []
    ) -> TextTransitionPlan {
        let far = outset
        let oldLines = old.lines
        let newLines = new.lines

        func band(_ lines: [TextLineBox], from index: Int) -> CGFloat {
            index == 0 ? -far : lines[index].rect.minY
        }
        func bandEnd(_ lines: [TextLineBox], before index: Int) -> CGFloat {
            index >= lines.count ? far : lines[index].rect.minY
        }
        func rect(minX: CGFloat = -far, maxX: CGFloat = far, minY: CGFloat, maxY: CGFloat) -> CGRect? {
            guard maxY > minY, maxX > minX else { return nil }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        // Leading lines that didn't change at all.
        var same = 0
        while same < oldLines.count, same < newLines.count, Self.identical(oldLines[same], newLines[same]) {
            same += 1
        }
        if same == oldLines.count, same == newLines.count {
            return carry(inFlight, stable: [rect(minY: -far, maxY: far)!], reveals: [], fadeOut: [])
        }

        var stable: [CGRect] = []
        var reveals: [CGRect] = []
        var fadeOut: [CGRect] = []
        if same > 0, let top = rect(minY: -far, maxY: bandEnd(newLines, before: same)) {
            stable.append(top)
        }

        // The first changed line keeps its common prefix when one line
        // continues the other.
        var nextOld = same
        var nextNew = same
        if same < oldLines.count, same < newLines.count, old.isLeftAligned, new.isLeftAligned,
           let shorter = commonPrefix(oldLines[same], old.string, newLines[same], new.string) {
            let oldLine = oldLines[same]
            let newLine = newLines[same]
            let split = newLine.rect.minX + shorter
            let newTop = band(newLines, from: same)
            let newBottom = bandEnd(newLines, before: same + 1)
            let oldTop = band(oldLines, from: same)
            let oldBottom = bandEnd(oldLines, before: same + 1)
            if let prefix = rect(maxX: split, minY: newTop, maxY: newBottom) { stable.append(prefix) }
            if newLine.range.count > oldLine.range.count || newLine.rect.width > shorter + 0.001,
               let tail = rect(minX: split, minY: newTop, maxY: newBottom) {
                reveals.append(tail)
            }
            if oldLine.range.count > newLine.range.count || oldLine.rect.width > shorter + 0.001,
               let tail = rect(minX: oldLine.rect.minX + shorter, minY: oldTop, maxY: oldBottom) {
                fadeOut.append(tail)
            }
            nextOld += 1
            nextNew += 1
        }

        if nextNew < newLines.count, let rest = rect(minY: band(newLines, from: nextNew), maxY: far) {
            reveals.append(rest)
        }
        if nextOld < oldLines.count, let rest = rect(minY: band(oldLines, from: nextOld), maxY: far) {
            fadeOut.append(rest)
        }
        return carry(inFlight, stable: stable, reveals: reveals.map { Reveal(rect: $0, fromOpacity: 0) }, fadeOut: fadeOut)
    }

    /// Regions still fading in that land on stable text continue from their
    /// current opacity.
    private static func carry(_ inFlight: [Reveal], stable: [CGRect], reveals: [Reveal], fadeOut: [CGRect]) -> TextTransitionPlan {
        var stable = stable
        var reveals = reveals
        for flight in inFlight where flight.fromOpacity < 0.999 {
            for region in stable {
                let overlap = region.intersection(flight.rect)
                guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }
                reveals.append(Reveal(rect: overlap, fromOpacity: max(0, flight.fromOpacity)))
            }
            stable = stable.flatMap { $0.subtracting(flight.rect) }
        }
        return TextTransitionPlan(stable: stable, reveals: reveals, fadeOut: fadeOut)
    }

    static func identical(_ old: TextLineBox, _ new: TextLineBox) -> Bool {
        old.fingerprint == new.fingerprint && old.range.count == new.range.count
            && abs(old.rect.minX - new.rect.minX) < 0.01 && abs(old.rect.minY - new.rect.minY) < 0.01
            && abs(old.rect.width - new.rect.width) < 0.01 && abs(old.rect.height - new.rect.height) < 0.01
    }

    /// When one line continues the other (same start, same top, and the
    /// shorter one's characters begin the longer one), the shorter line's
    /// glyph width; otherwise `nil`. Reads only the two lines' characters.
    static func commonPrefix(_ old: TextLineBox, _ oldString: String, _ new: TextLineBox, _ newString: String) -> CGFloat? {
        guard old.range.lowerBound == new.range.lowerBound,
              abs(old.rect.minX - new.rect.minX) < 0.01, abs(old.rect.minY - new.rect.minY) < 0.01,
              abs(old.rect.height - new.rect.height) < 0.01 else { return nil }
        let count = min(old.range.count, new.range.count)
        guard count > 0, let a = slice(oldString, from: old.range.lowerBound, count: count),
              let b = slice(newString, from: new.range.lowerBound, count: count), a.elementsEqual(b) else { return nil }
        return old.range.count <= new.range.count ? old.rect.width : new.rect.width
    }

    private static func slice(_ string: String, from offset: Int, count: Int) -> Substring.UTF16View? {
        let units = string.utf16
        guard offset >= 0, count >= 0, offset + count <= units.count else { return nil }
        let start = units.index(units.startIndex, offsetBy: offset)
        let end = units.index(start, offsetBy: count)
        return units[start..<end]
    }
}

extension CGRect {
    /// The parts of `self` outside `other`: up to four rectangles.
    func subtracting(_ other: CGRect) -> [CGRect] {
        let overlap = intersection(other)
        guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return [self] }
        var pieces: [CGRect] = []
        if overlap.minY > minY { pieces.append(CGRect(x: minX, y: minY, width: width, height: overlap.minY - minY)) }
        if overlap.maxY < maxY { pieces.append(CGRect(x: minX, y: overlap.maxY, width: width, height: maxY - overlap.maxY)) }
        if overlap.minX > minX { pieces.append(CGRect(x: minX, y: overlap.minY, width: overlap.minX - minX, height: overlap.height)) }
        if overlap.maxX < maxX { pieces.append(CGRect(x: overlap.maxX, y: overlap.minY, width: maxX - overlap.maxX, height: overlap.height)) }
        return pieces
    }
}
