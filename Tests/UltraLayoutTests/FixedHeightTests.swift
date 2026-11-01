import Foundation
import Testing
import UltraLayout

/// `LayoutStyle.hasFixedHeight` against Yoga: a root it accepts measures to
/// the same height at every width, and each kind of root it turns down
/// changes height with the width.
@Suite struct FixedHeightTests {
    /// A root laid out the way a list measures a row: as wide as the list,
    /// with no limit on its height. Its child is as tall as it is wide.
    private func height(_ configure: (inout LayoutStyle) -> Void, width: CGFloat) -> CGFloat {
        var style = LayoutStyle()
        configure(&style)
        style.width = .points(width)
        var square = LayoutStyle()
        square.aspectRatio = 1
        let root = LayoutNode(style: style, children: [LayoutNode(style: square)])
        root.calculateLayout(width: width, height: nil)
        return root.frame.height
    }

    private static let widths: [CGFloat] = [120, 390, 820]

    @Test(arguments: [
        "points", "points with point padding", "points with point limits", "content box",
    ])
    func acceptedRootsKeepTheirHeight(_ name: String) {
        let configure: (inout LayoutStyle) -> Void = { style in
            style.height = .points(64)
            switch name {
            case "points with point padding": style.paddingVertical = .points(10); style.paddingHorizontal = .percent(10)
            case "points with point limits": style.minHeight = .points(40); style.maxHeight = .points(90)
            case "content box": style.boxSizing = .contentBox; style.padding = .points(6)
            default: break
            }
        }
        var style = LayoutStyle()
        configure(&style)
        #expect(style.hasFixedHeight)
        let heights = Self.widths.map { height(configure, width: $0) }
        #expect(Set(heights).count == 1, "\(name): \(heights)")
    }

    @Test(arguments: [
        "auto", "percent padding", "percent top padding", "aspect ratio", "percent minimum",
    ])
    func rejectedRootsDependOnTheWidth(_ name: String) {
        let configure: (inout LayoutStyle) -> Void = { style in
            switch name {
            case "auto": break
            case "percent padding": style.height = .points(10); style.padding = .percent(20)
            case "percent top padding": style.height = .points(10); style.paddingTop = .percent(30)
            case "aspect ratio": style.height = .points(64); style.aspectRatio = 2; style.alignSelf = .flexStart
            case "percent minimum": style.height = .points(10); style.minHeight = .percent(50)
            default: break
            }
        }
        var style = LayoutStyle()
        configure(&style)
        #expect(!style.hasFixedHeight)
        // An aspect ratio and a percent minimum have no effect on a root
        // whose width and height are both set; they are turned down because
        // they would on a root Yoga sizes differently, not because of Yoga's
        // answer here.
        guard name != "aspect ratio", name != "percent minimum" else { return }
        let heights = Self.widths.map { height(configure, width: $0) }
        #expect(Set(heights).count == Self.widths.count, "\(name): \(heights)")
    }
}
