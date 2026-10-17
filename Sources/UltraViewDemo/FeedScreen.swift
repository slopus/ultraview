#if canImport(UIKit)
import UIKit
import UltraView

/// A long feed in one scroll node: a row of stories in a horizontal scroll
/// node, then cards whose text nests bold, italic, colored, underlined and
/// pressable spans. Only cards near the viewport get views and bitmaps.
enum FeedScreen {
    /// The feed's root. Its cards are built on a background thread and added
    /// when ready, so building a thousand of them never holds up launch.
    static func make(cardCount: Int) -> UltraNode {
        let root = UltraNode(style: styled { $0.flex = 1 })
        Task.detached(priority: .userInitiated) {
            root.setChildren([feed(cardCount: cardCount)])
        }
        return root
    }

    static func feed(cardCount: Int) -> UltraScrollNode {
        let feed = UltraScrollNode(
            style: styled { $0.flex = 1 },
            contentContainerStyle: styled {
                $0.paddingHorizontal = 12
                $0.paddingVertical = 12
                $0.gap = 12
            }
        )
        feed.setChildren([stories()] + (0..<cardCount).map(card))
        return feed
    }

    private static let names = [
        "Ada", "Grace", "Linus", "Barbara", "Ken", "Margaret", "Dennis", "Frances",
        "Edsger", "Radia", "Donald", "Hedy", "Alan", "Katherine", "Niklaus", "Sophie",
    ]
    private static let colors: [Color] = [.indigo, .pink, .orange, .teal, .purple, .blue, .green, .red]
    private static let topics = ["#layout", "#text", "#scrolling", "#threads", "#yoga", "#bitmaps"]
    private static let sentences = [
        "Measured off the main thread, drawn into a bitmap, applied in one transaction.",
        "Nested spans inherit the style around them and add their own.",
        "A pass coalesces every change made since the last one.",
        "Cards far from the viewport give their bitmaps back.",
        "The main thread assigns frames and contents and nothing else.",
        "Yoga lays out the whole feed; Core Text measures each paragraph once per width.",
    ]

    private static func stories() -> UltraNode {
        UltraScrollNode(
            style: styled { $0.marginHorizontal = -12 },
            contentContainerStyle: styled {
                $0.paddingHorizontal = 12
                $0.gap = 12
            },
            horizontal: true,
            children: (0..<names.count).map { index in
                UltraNode(style: styled {
                    $0.alignItems = .center
                    $0.gap = 4
                    $0.width = 64
                }, children: [
                    UltraNode(
                        style: styled {
                            $0.width = 60
                            $0.height = 60
                            $0.borderRadius = 30
                            $0.borderWidth = 3
                            $0.borderColor = colors[index % colors.count]
                            $0.padding = 3
                        },
                        children: [avatar(index, size: 48)]
                    ),
                    UltraTextNode(
                        names[index],
                        textStyle: TextStyle(color: Palette.secondaryLabel, fontSize: 11),
                        numberOfLines: 1
                    ),
                ])
            }
        ).with { $0.showsHorizontalScrollIndicator = false }
    }

    private static func avatar(_ index: Int, size: CGFloat) -> UltraNode {
        UltraNode(
            style: styled {
                $0.width = .points(size)
                $0.height = .points(size)
                $0.borderRadius = size / 2
                $0.backgroundColor = colors[index % colors.count]
                $0.justifyContent = .center
                $0.alignItems = .center
            },
            children: [
                UltraTextNode(
                    String(names[index % names.count].prefix(1)),
                    textStyle: TextStyle(color: .white, fontSize: size * 0.42, fontWeight: .bold)
                ),
            ]
        )
    }

    private static func card(_ index: Int) -> UltraNode {
        let name = names[index % names.count]
        let topic = topics[index % topics.count]
        let sentence = sentences[index % sentences.count]
        let color = colors[(index / 3) % colors.count]

        var body: [TextSpan] = [
            TextSpan(sentence + " "),
            TextSpan("Post \(index + 1)", style: TextStyle(fontWeight: .bold)),
            TextSpan(" mentions "),
            TextSpan(topic, style: TextStyle(color: color, fontWeight: .semibold), onPress: {}),
            TextSpan(" and "),
            TextSpan("@\(names[(index + 5) % names.count].lowercased())", style: TextStyle(
                color: .blue,
                textDecorationLine: .underline
            ), onPress: {}),
            TextSpan("."),
        ]
        if index % 2 == 0 {
            body.append(TextSpan(" Nested: ", children: [
                TextSpan("italic ", style: TextStyle(fontStyle: .italic), children: [
                    TextSpan("and bold", style: TextStyle(fontWeight: .bold)),
                ]),
                TextSpan(", "),
                TextSpan("struck", style: TextStyle(color: Palette.secondaryLabel, textDecorationLine: .lineThrough)),
                TextSpan(", "),
                TextSpan("highlighted", style: TextStyle(backgroundColor: Color(hex: 0xFFE58A))),
            ]))
        }
        if index % 3 == 0 {
            body.append(TextSpan(" " + sentences[(index + 2) % sentences.count]))
        }

        let likes = UltraTextNode(
            "♡ \(index * 7 % 97)",
            textStyle: TextStyle(color: Palette.secondaryLabel, fontSize: 13, fontWeight: .medium)
        )
        let liked = LikeState(count: index * 7 % 97)
        likes.style = styled { $0.hitSlop = Insets(all: 8) }
        likes.onPress = { [weak likes] in
            liked.isLiked.toggle()
            let count = liked.count + (liked.isLiked ? 1 : 0)
            likes?.text = "\(liked.isLiked ? "♥" : "♡") \(count)"
            likes?.textStyle.color = liked.isLiked ? .pink : Palette.secondaryLabel
        }

        let card = UltraNode(
            style: styled {
                $0.flexDirection = .row
                $0.gap = 12
                $0.padding = 14
                $0.backgroundColor = Palette.card
                $0.borderRadius = 16
            },
            children: [
                avatar(index, size: 40),
                UltraNode(style: styled {
                    $0.flex = 1
                    $0.gap = 6
                }, children: [
                    UltraTextNode(
                        spans: [
                            TextSpan(name, style: TextStyle(color: Palette.label, fontWeight: .semibold)),
                            TextSpan("  @\(name.lowercased()) · \(index % 23 + 1)h"),
                        ],
                        textStyle: TextStyle(color: Palette.secondaryLabel, fontSize: 15),
                        numberOfLines: 1
                    ),
                    UltraTextNode(
                        spans: body,
                        textStyle: TextStyle(color: Palette.label, fontSize: 15, lineHeight: 20)
                    ),
                    UltraNode(style: styled {
                        $0.flexDirection = .row
                        $0.gap = 24
                        $0.marginTop = 2
                    }, children: [
                        UltraTextNode(
                            "↩ \(index % 9)",
                            textStyle: TextStyle(color: Palette.secondaryLabel, fontSize: 13, fontWeight: .medium)
                        ),
                        likes,
                    ]),
                ]),
            ]
        )
        card.debugName = "card \(index)"
        return card
    }
}

@MainActor
private final class LikeState {
    let count: Int
    var isLiked = false

    nonisolated init(count: Int) {
        self.count = count
    }
}

extension UltraNode {
    /// Configures the node in place and returns it, for building trees.
    func with(_ body: (Self) -> Void) -> Self {
        body(self)
        return self
    }
}
#endif
