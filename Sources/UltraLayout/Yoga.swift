import Foundation
internal import yoga

// Yoga's enums import differently per platform. On Apple platforms its
// headers declare them with NS_ENUM, so Swift sees `YGAlign.center`; elsewhere
// they are plain C enums and Swift sees `YGAlignCenter`. Converting through
// the raw value works on both. The values are the declaration order in
// yoga/YGEnums.h; UltraLayoutTests checks each case's effect on frames.

private func yogaEnum<T: RawRepresentable>(_ rawValue: Int32) -> T where T.RawValue: BinaryInteger {
    guard let value = T(rawValue: T.RawValue(rawValue)) else {
        preconditionFailure("\(T.self) has no raw value \(rawValue)")
    }
    return value
}

enum Yoga {
    static let gutterAll: YGGutter = yogaEnum(2)

    static let edgeLeft: YGEdge = yogaEnum(0)
    static let edgeTop: YGEdge = yogaEnum(1)
    static let edgeRight: YGEdge = yogaEnum(2)
    static let edgeBottom: YGEdge = yogaEnum(3)
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
        }
    }
}

extension LayoutInsets {
    var yogaEdges: [(YGEdge, CGFloat)] {
        [(Yoga.edgeTop, top), (Yoga.edgeLeft, left), (Yoga.edgeBottom, bottom), (Yoga.edgeRight, right)]
    }
}
