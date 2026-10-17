# UltraView

A Swift library for fast UI on iOS. Views are described as a tree of nodes
that are measured, laid out and rendered off the main thread; the main thread
only applies finished results. Layout is flexbox, computed by
[Yoga](https://github.com/facebook/yoga). The components provide boxes, styled
text and scrolling. A virtualized list measures a nearby window and plays
momentum through Core Animation, with its own gestures and scroll physics.

| Module        | What it is                                                                 |
| ------------- | -------------------------------------------------------------------------- |
| `UltraLayout` | Yoga flexbox behind a Swift API. Foundation only, tested on Linux.         |
| `UltraCore`   | The node pipeline and the `UltraNode`, `UltraTextNode` and `UltraScrollNode` components. |
| `UltraList`   | A virtualized list, scroll physics, animation tracks and floating attachments. Pure behavior is tested on Linux. |
| `UltraView`   | Umbrella: `import UltraView` re-exports the three above.                   |

Requires iOS 26 and Swift 6.2 (Xcode 26).

## Using it

```swift
.package(url: "https://github.com/slopus/ultraview.git", branch: "main")
// target dependency:
.product(name: "UltraView", package: "ultraview")
```

```swift
import UltraView

var card = Style()
card.flexDirection = .row
card.gap = 12
card.padding = 16
card.backgroundColor = .white
card.borderRadius = 12

let title = UltraTextNode(spans: [
    TextSpan("Hello, ", style: TextStyle(fontWeight: .bold)),
    TextSpan("world", style: TextStyle(color: .blue), onPress: { print("pressed") }),
], textStyle: TextStyle(fontSize: 17), numberOfLines: 2)
title.style.flex = 1

var fill = Style()
fill.flex = 1
let root = UltraScrollNode(style: fill, children: [
    UltraNode(style: card, children: [title]),
])

// Main thread: show it.
let host = NodeHostView(rootNode: root)
view.addSubview(host)

// Any thread, any time later: change it.
title.text = "Updated from a background queue"
```

- `UltraNode` is a flexbox box: every Yoga property, background, per-side
  border widths and colors, per-corner radii, opacity, transform, shadow,
  `pointerEvents`, `hitSlop`, accessibility, and `onPress`, `onLongPress`,
  `onPressIn`, `onPressOut`. Children: `addChild`, `insertChild`,
  `removeChild`, `setChildren`.
- `UltraTextNode` is styled text: nested `TextSpan`s that inherit their
  parent's `TextStyle`, `numberOfLines` with `ellipsizeMode` (head, middle,
  tail, clip), Dynamic Type with `allowFontScaling` and
  `maxFontSizeMultiplier`, and pressable spans.
- `UltraScrollNode` is a `UIScrollView` whose content is laid out by Yoga:
  `contentContainerStyle`, `horizontal`, `contentInset`, indicators, paging,
  `bounces`, `scrollEnabled`, `keyboardDismissMode`, `onScroll`,
  `scrollTo(x:y:animated:)` and `scrollToEnd`. Only children near the
  viewport keep views and bitmaps.

Styles default to Yoga's: column direction, `flexShrink` 0, `alignContent`
flex-start.

### Lists

`UltraListView` accepts rows with stable string identities. Plain view rows
implement `ListRow`, returning a `ListRowView` whose `update(width:transition:)`
returns its height. `NodeRow` prepares node trees asynchronously; an unmeasured
row leaves the loaded edge open until its measurement is ready.

```swift
let list = UltraListView() // .keyframe momentum; .stepped and .uiKit also available
list.frame = view.bounds
view.addSubview(list)
list.applyChanges(items: rows)
list.applyChanges(items: updatedRows,
                  anchorMode: .preserveVisibleContent,
                  transition: .easeInOut(0.3))
list.scrollTo(.init(index: 500), transition: .smoothDeceleration())
```

Node rows create their trees off main and use the list's display and text environment:

```swift
let rows = (0..<10_000).map { index in
    NodeRow(identity: String(index)) {
        UltraTextNode("Row \(index)", textStyle: TextStyle(fontSize: 17))
    }
}
list.applyChanges(items: rows)
```

The list publishes settled geometry immediately. Use `settledFrame(at:)` for
destinations and `presentedFrame(at:)` for animated positions. Floating or
reserving headers implement `ListAttachment`. See [the list design](Docs/UltraList.md)
for threading, measurement, animation and host behavior.

### Threads

A change to a node, from any thread, records the new value and schedules a
pass. Changes made close together share one pass. The pass runs on a serial
background queue: it runs Yoga over the tree, measures text with Core Text
(as Yoga measure functions, keeping the layout for drawing), works out which
nodes are near the screen, and draws the changed ones into bitmaps on a
concurrent queue. It produces a commit: an immutable value listing only the
nodes whose frame, properties or bitmap changed, plus views to create or
remove. A newer pass supersedes a commit that hasn't been applied yet, and
drawing for a node that changed again is thrown away.

The main thread applies a commit in one Core Animation transaction: it
creates and removes views, assigns frames, layer properties and bitmaps,
and nothing else. Debug builds assert that no layout pass, text measurement
or drawing runs on it, and `Diagnostics` counts them by thread.

The main thread never waits for the pipeline. When a host's size, window or
appearance changes, it asks for a pass and keeps showing what it has until
that pass's commit arrives. Views for nodes on screen are created in the
turn their commit arrives; views prepared ahead of the screen are created a
few per frame, within `mountBudget`. A host outside a window keeps its views
and bitmaps, and `prepare(size:)` lays out and draws one before it first
appears, so it shows its content in its first frame in a window
(`keepsContentOutsideWindow = false` gives the memory back instead).

```swift
// Off the main thread: the height of a tree at a width. A host that later
// shows it at that width reuses the layout and the text measurements.
let size = await NodeMeasurement.measure(row, width: 390, environment: environment)
```

## Building on Linux

You need Swift 6.2 or newer, [xtool](https://xtool.sh) and its Darwin SDK
(`xtool setup`).

```sh
scripts/build.sh test   # swift build + swift test (everything but UIKit)
scripts/build.sh ios    # cross-build every target for iOS and the simulator
scripts/build.sh app    # xtool dev build -> xtool/UltraViewDemo.app
```

The script uses SwiftPM's `--build-system native`. Set `SWIFT` and
`SWIFT_SDKS_PATH` if `swift` or the Darwin SDK aren't where SwiftPM looks.

## Building on macOS

```sh
brew install xcodegen
xcodegen                       # writes UltraView.xcodeproj (not committed)
open UltraView.xcodeproj       # scheme UltraViewDemo: run the demo, ⌘U for tests
```

The Xcode app target is `UltraViewDemoApp`; the scheme remains `UltraViewDemo`.
The demo has four tabs: Layout (flexbox, borders, text, presses), Feed
(1,000 cards in a scroll node) and Stress (background threads changing
nodes, with the main thread's cost per commit on screen), and Lists (streaming
chat, a 10,000-row feed, three engine modes and a public gesture recorder).
Launch with `-screen lists -listScreen chat`, `feed`, `compare` or `record` for
the list demos. The other tabs accept `-screen layout`, `feed` or `stress`.

From the command line:

```sh
xcodebuild test -project UltraView.xcodeproj -scheme UltraViewDemo \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## Clean-room reimplementation

UltraView is a clean-room reimplementation of ideas from three projects:

- [Texture](https://github.com/TextureGroup/Texture), formerly
  AsyncDisplayKit: a node tree whose measurement, layout, text layout and
  rendering run off the main thread, with the main thread only applying
  precomputed results.
- Telegram-iOS's core list,
  [`submodules/TelegramUI/Components/CoreList`](https://github.com/TelegramMessenger/Telegram-iOS/tree/master/submodules/TelegramUI/Components/CoreList):
  a virtualized list with its own scroll physics instead of `UIScrollView`.
- [React Native](https://github.com/facebook/react-native)'s layout and
  components: flexbox through Yoga, and the View, Text and ScrollView
  component and style model.

No code from these projects is copied or translated. UltraView is written
independently from their published designs and observed behavior, and
contains no code from any of them.
