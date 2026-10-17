import Foundation
internal import yoga

// Yoga's enums import differently per platform. On Apple platforms its
// headers declare them with NS_ENUM, so Swift sees `YGAlign.center`; elsewhere
// they are plain C enums and Swift sees `YGAlignCenter`. Converting through
// the raw value works on both. The values are the declaration order in
// yoga/YGEnums.h; UltraLayoutTests checks each case's effect on frames.

func yogaEnum<T: RawRepresentable>(_ rawValue: Int32) -> T where T.RawValue: BinaryInteger {
    guard let value = T(rawValue: T.RawValue(rawValue)) else {
        preconditionFailure("\(T.self) has no raw value \(rawValue)")
    }
    return value
}

func rawYogaValue<T: RawRepresentable>(_ value: T) -> Int where T.RawValue: BinaryInteger {
    Int(value.rawValue)
}

enum Yoga {
    static let gutterColumn: YGGutter = yogaEnum(0)
    static let gutterRow: YGGutter = yogaEnum(1)
    static let gutterAll: YGGutter = yogaEnum(2)

    static let edgeLeft: YGEdge = yogaEnum(0)
    static let edgeTop: YGEdge = yogaEnum(1)
    static let edgeRight: YGEdge = yogaEnum(2)
    static let edgeBottom: YGEdge = yogaEnum(3)
    static let edgeStart: YGEdge = yogaEnum(4)
    static let edgeEnd: YGEdge = yogaEnum(5)
    static let edgeHorizontal: YGEdge = yogaEnum(6)
    static let edgeVertical: YGEdge = yogaEnum(7)
    static let edgeAll: YGEdge = yogaEnum(8)

    static let nodeTypeDefault: YGNodeType = yogaEnum(0)
    static let nodeTypeText: YGNodeType = yogaEnum(1)

    static let errataNone: YGErrata = yogaEnum(0)
    static let errataAll: YGErrata = yogaEnum(2_147_483_647)

    /// `nil` and NaN both mean "undefined" to Yoga.
    static func float(_ value: CGFloat?) -> Float {
        value.map(Float.init) ?? .nan
    }
}

extension LayoutStyle.Direction {
    var yoga: YGDirection {
        switch self {
        case .inherit: yogaEnum(0)
        case .leftToRight: yogaEnum(1)
        case .rightToLeft: yogaEnum(2)
        }
    }
}

extension LayoutStyle.FlexDirection {
    var yoga: YGFlexDirection {
        switch self {
        case .column: yogaEnum(0)
        case .columnReverse: yogaEnum(1)
        case .row: yogaEnum(2)
        case .rowReverse: yogaEnum(3)
        }
    }
}

extension LayoutStyle.Justify {
    var yoga: YGJustify {
        switch self {
        case .flexStart: yogaEnum(0)
        case .center: yogaEnum(1)
        case .flexEnd: yogaEnum(2)
        case .spaceBetween: yogaEnum(3)
        case .spaceAround: yogaEnum(4)
        case .spaceEvenly: yogaEnum(5)
        }
    }
}

extension LayoutStyle.Align {
    var yoga: YGAlign {
        switch self {
        case .auto: yogaEnum(0)
        case .flexStart: yogaEnum(1)
        case .center: yogaEnum(2)
        case .flexEnd: yogaEnum(3)
        case .stretch: yogaEnum(4)
        case .baseline: yogaEnum(5)
        case .spaceBetween: yogaEnum(6)
        case .spaceAround: yogaEnum(7)
        case .spaceEvenly: yogaEnum(8)
        }
    }
}

extension LayoutStyle.Wrap {
    var yoga: YGWrap {
        switch self {
        case .noWrap: yogaEnum(0)
        case .wrap: yogaEnum(1)
        case .wrapReverse: yogaEnum(2)
        }
    }
}

extension LayoutStyle.PositionType {
    var yoga: YGPositionType {
        switch self {
        case .static: yogaEnum(0)
        case .relative: yogaEnum(1)
        case .absolute: yogaEnum(2)
        }
    }
}

extension LayoutStyle.Display {
    var yoga: YGDisplay {
        switch self {
        case .flex: yogaEnum(0)
        case .none: yogaEnum(1)
        case .contents: yogaEnum(2)
        }
    }
}

extension LayoutStyle.Overflow {
    var yoga: YGOverflow {
        switch self {
        case .visible: yogaEnum(0)
        case .hidden: yogaEnum(1)
        case .scroll: yogaEnum(2)
        }
    }
}

extension LayoutStyle.BoxSizing {
    var yoga: YGBoxSizing {
        switch self {
        case .borderBox: yogaEnum(0)
        case .contentBox: yogaEnum(1)
        }
    }
}

extension MeasureMode {
    init(yoga mode: YGMeasureMode) {
        switch rawYogaValue(mode) {
        case 1: self = .exactly
        case 2: self = .atMost
        default: self = .undefined
        }
    }
}

extension Edges {
    /// The edges that are set, paired with Yoga's edge constants. Unset
    /// edges are included as `nil` so a value can be cleared.
    var yogaEdges: [(YGEdge, Value?)] {
        [
            (Yoga.edgeLeft, left),
            (Yoga.edgeTop, top),
            (Yoga.edgeRight, right),
            (Yoga.edgeBottom, bottom),
            (Yoga.edgeStart, start),
            (Yoga.edgeEnd, end),
            (Yoga.edgeHorizontal, horizontal),
            (Yoga.edgeVertical, vertical),
            (Yoga.edgeAll, all),
        ]
    }
}
