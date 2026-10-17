#if canImport(UIKit)
import UIKit
import UltraView

/// Flexbox in a scroll node: rows that grow, every `justifyContent` value,
/// wrapping chips, borders and corners per side, a shadowed card with an
/// absolutely positioned badge, and a button that changes on press.
enum LayoutScreen {
    static func make() -> UltraNode {
        UltraScrollNode(
            style: styled { $0.flex = 1 },
            contentContainerStyle: styled {
                $0.padding = 16
                $0.gap = 20
            },
            children: [
                header(),
                section("Rows that grow", tiles()),
                section("justifyContent", justifyRows()),
                section("flexWrap", chips()),
                section("Borders, corners, shadow", card()),
                section("Press", button()),
            ]
        )
    }

    private static func header() -> UltraNode {
        UltraNode(style: styled { $0.gap = 4 }, children: [
            UltraTextNode("Layout", textStyle: TextStyle(color: Palette.label, fontSize: 34, fontWeight: .bold)),
            UltraTextNode(spans: [
                TextSpan("Every frame here comes from Yoga, computed "),
                TextSpan("off the main thread", style: TextStyle(fontWeight: .semibold, fontStyle: .italic)),
                TextSpan("; the main thread only applies it."),
            ], textStyle: TextStyle(color: Palette.secondaryLabel, fontSize: 15, lineHeight: 20)),
        ])
    }

    private static func section(_ title: String, _ content: UltraNode) -> UltraNode {
        UltraNode(style: styled { $0.gap = 8 }, children: [
            UltraTextNode(title, textStyle: TextStyle(
                color: Palette.secondaryLabel,
                fontSize: 13,
                fontWeight: .semibold,
                letterSpacing: 0.5,
                textTransform: .uppercase
            )),
            content,
        ])
    }

    private static func tiles() -> UltraNode {
        let colors: [Color] = [.pink, .orange, .teal]
        return UltraNode(
            style: styled {
                $0.flexDirection = .row
                $0.gap = 12
                $0.height = 88
            },
            children: colors.enumerated().map { index, color in
                UltraNode(
                    style: styled {
                        $0.flexGrow = CGFloat(index + 1)
                        $0.justifyContent = .center
                        $0.alignItems = .center
                        $0.backgroundColor = color
                        $0.borderRadius = 16
                    },
                    children: [
                        UltraTextNode(
                            "flexGrow \(index + 1)",
                            textStyle: TextStyle(color: .white, fontSize: 13, fontWeight: .bold)
                        ),
                    ]
                )
            }
        )
    }

    private static func justifyRows() -> UltraNode {
        let values: [(String, LayoutStyle.Justify)] = [
            ("flexStart", .flexStart),
            ("center", .center),
            ("flexEnd", .flexEnd),
            ("spaceBetween", .spaceBetween),
            ("spaceAround", .spaceAround),
            ("spaceEvenly", .spaceEvenly),
        ]
        return UltraNode(
            style: styled {
                $0.gap = 6
                $0.padding = 12
                $0.backgroundColor = Palette.card
                $0.borderRadius = 14
            },
            children: values.map { name, justify in
                UltraNode(
                    style: styled {
                        $0.flexDirection = .row
                        $0.alignItems = .center
                        $0.gap = 8
                    },
                    children: [
                        UltraTextNode(
                            name,
                            style: styled { $0.width = 96 },
                            textStyle: TextStyle(color: Palette.secondaryLabel, fontSize: 12, fontFamily: "Menlo")
                        ),
                        UltraNode(
                            style: styled {
                                $0.flex = 1
                                $0.flexDirection = .row
                                $0.justifyContent = justify
                                $0.height = 22
                                $0.alignItems = .center
                                $0.backgroundColor = Palette.background
                                $0.borderRadius = 11
                            },
                            children: [Color.indigo, .purple, .blue].map { color in
                                UltraNode(style: styled {
                                    $0.width = 16
                                    $0.height = 16
                                    $0.borderRadius = 8
                                    $0.backgroundColor = color
                                })
                            }
                        ),
                    ]
                )
            }
        )
    }

    private static func chips() -> UltraNode {
        let words = ["Yoga", "flexbox", "Core Text", "bitmaps", "off main", "commits", "generations", "ranges", "Swift 6", "Mutex"]
        return UltraNode(
            style: styled {
                $0.flexDirection = .row
                $0.flexWrap = .wrap
                $0.gap = 8
            },
            children: words.map { word in
                UltraTextNode(
                    word,
                    style: styled {
                        $0.paddingHorizontal = 12
                        $0.paddingVertical = 6
                        $0.borderWidth = 1
                        $0.borderColor = Palette.accent
                        $0.borderRadius = 14
                    },
                    textStyle: TextStyle(color: Palette.accent, fontSize: 14, fontWeight: .medium)
                )
            }
        )
    }

    private static func card() -> UltraNode {
        UltraNode(
            style: styled {
                $0.flexDirection = .row
                $0.gap = 12
                $0.padding = 16
                $0.backgroundColor = Palette.card
                $0.borderTopLeftRadius = 24
                $0.borderBottomRightRadius = 24
                $0.borderTopRightRadius = 6
                $0.borderBottomLeftRadius = 6
                $0.shadowColor = .black
                $0.shadowOpacity = 0.15
                $0.shadowRadius = 10
                $0.shadowOffset = CGSize(width: 0, height: 4)
            },
            children: [
                UltraNode(style: styled {
                    $0.width = 64
                    $0.aspectRatio = 1
                    $0.backgroundColor = Color(hex: 0xFFF4D6)
                    $0.borderTopWidth = 4
                    $0.borderTopColor = .orange
                    $0.borderLeftWidth = 4
                    $0.borderLeftColor = .pink
                    $0.borderBottomWidth = 4
                    $0.borderBottomColor = .teal
                    $0.borderRightWidth = 4
                    $0.borderRightColor = .indigo
                    $0.borderRadius = 12
                }),
                UltraTextNode(
                    spans: [
                        TextSpan("Per-side borders", style: TextStyle(fontWeight: .bold)),
                        TextSpan(" are drawn into the node's bitmap off the main thread. Uniform ones become layer borders. The badge is "),
                        TextSpan("position: absolute", style: TextStyle(fontFamily: "Menlo", backgroundColor: Color(hex: 0xEEF0FF))),
                        TextSpan("."),
                    ],
                    style: styled { $0.flex = 1 },
                    textStyle: TextStyle(color: Palette.label, fontSize: 14, lineHeight: 19)
                ),
                UltraTextNode(
                    "NEW",
                    style: styled {
                        $0.position = .absolute
                        $0.top = -8
                        $0.right = 12
                        $0.paddingHorizontal = 8
                        $0.paddingVertical = 2
                        $0.backgroundColor = .red
                        $0.borderRadius = 9
                        $0.transform = [.rotate(degrees: 6)]
                    },
                    textStyle: TextStyle(color: .white, fontSize: 11, fontWeight: .heavy)
                ),
            ]
        )
    }

    private static func button() -> UltraNode {
        let colors: [Color] = [.indigo, .pink, .teal, .orange]
        let label = UltraTextNode(
            "Pressed 0 times",
            textStyle: TextStyle(color: .white, fontSize: 17, fontWeight: .semibold, textAlign: .center)
        )
        let button = UltraNode(
            style: styled {
                $0.paddingVertical = 14
                $0.backgroundColor = colors[0]
                $0.borderRadius = 14
            },
            children: [label]
        )
        button.pressedOpacity = 0.6
        button.accessibility = Accessibility(label: "Counter", role: .button)
        let presses = PressCount()
        button.onPress = { [weak button, weak label] in
            presses.value += 1
            let count = presses.value
            label?.text = "Pressed \(count) time\(count == 1 ? "" : "s")"
            button?.updateStyle { $0.backgroundColor = colors[count % colors.count] }
        }
        return button
    }
}

@MainActor
private final class PressCount {
    var value = 0

    nonisolated init() {}
}
#endif
