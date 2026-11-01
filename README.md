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
list.defaultTransition = .spring(0.4, damping: 24)
list.applyChanges(items: rows)
list.applyChanges(items: updatedRows,
                  anchorMode: .preserveVisibleContent,
                  transition: .easeInOut(0.3))
list.scrollTo(.init(index: 500), transition: .smoothDeceleration())
list.applyChanges(items: rows, transition: .none) // explicit immediate update
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

Once nearby asynchronous measurements are ready, the list publishes settled geometry.
Insertions, deletions, moves and height changes use `defaultTransition` unless
the update supplies its own transition. Linear, easing, custom Bézier and
damped spring curves compile to Core Animation layer animations.
Use `settledFrame(at:)` for
destinations and `presentedFrame(at:)` for animated positions. Floating or
reserving headers implement `ListAttachment`. When the list's width changes
(rotation, split view columns, window resizing), visible rows are laid out and
drawn at the new width in the same frame; rows whose root has a fixed height in
points keep their places and are only redrawn. See [the list design](Docs/UltraList.md)
for threading, measurement, animation and host behavior.

On iPhone, set `CADisableMinimumFrameDurationOnPhone` to `YES` in the host app's
Info.plist to allow app-driven Core Animation and display links above 60 Hz.
The demo enables it. The display and system determine the achieved frame rate.

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
turn their commit arrives; creating and removing views off screen is spread
over frames within `mountBudget`. A host outside a window keeps its views
and bitmaps. `prepare(size:)` starts layout and drawing before it first
appears; once prepared, the content is available on entering the window.
If preparation hasn't finished, the host displays its last committed content
until the new commit arrives (`keepsContentOutsideWindow = false` gives the
memory back instead). Showing a host never waits for preparation.

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

The `UltraViewPerformance` scheme runs a separate Release UI test covering
first appearances, repeated and rapid tab switches, a fast pass through the
feed in both directions, jumps, stress, rotation, and background/return. It
attaches the full JSON report and requires zero main-thread layout, text
measurement or drawing. Run it with `xcodebuild test -project
UltraView.xcodeproj -scheme UltraViewPerformance -destination '<destination>'`.

For a device without UI automation, launch the Release demo with `-perfRun
YES` and capture its console output. `python3 scripts/check-performance.py
<console.log>` checks the result; add `--simulator` for simulator output.
The device regression budgets in milliseconds are 200 for launch, 50 for
first Feed, 33.33 for repeated switches and feed jumps, 25 for rapid switches,
66.67 for rotation, 50 for background, 200 for return, and 16.67 for the
other phases.
The simulator budget is 200 for launch/return and 50 for other phases. Both
checks also require all three node hosts to report at most 50 ms applying a
commit. Launch and return include synchronous system scene work: an observed
91 ms simulator return turn contained no library commit application, while
reported host application peaked at 4.6 ms across that run. This observation
does not identify which system call occupied that turn. These limits allow
headroom over measured results; they do not establish a one-frame guarantee.
Every overrun of 16.67 ms is printed. `--one-frame` checks the stricter benchmark, which
currently fails on startup, rotation and some tab switches, and can fail on
foreground restoration. It includes lifecycle phases on both platforms. Use
`--require-background` when checking a run driven through background/return.

The demo has four tabs: Layout (flexbox, borders, text, presses), Feed
(1,000 cards in a scroll node) and Stress (background threads changing
nodes, with the main thread's cost per commit on screen), and Lists (streaming
chat, a 10,000-row feed, three engine modes and a public gesture recorder).
Launch with `-screen lists -listScreen chat`, `feed`, `compare` or `record` for
the list demos, or `resize` for the Width screen: fixed-height cards and a
chat beside a sliding sidebar, with rotation and a dragged width
(`-resizeScenario YES` plays them, `-resizeSlow <n>` slows them down). The
other tabs accept `-screen layout`, `feed` or `stress`.

From the command line:

```sh
xcodebuild test -project UltraView.xcodeproj -scheme UltraViewDemo \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## Proofs

`Proofs/` contains machine-checked Lean proofs about models of scheduling,
commit merging, rendering and selected work bounds, and of the list's frames,
item diffs and animation timing, under explicit hypotheses.
These proofs do not establish correctness or global optimality of the whole
Swift implementation. `Proofs/MAPPING.md` records the historical model mapping
and the current coverage gaps.

```sh
scripts/proofs.sh   # lake build, and fails on sorry or extra axioms
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

No code from Texture or React Native is copied or translated; UltraView is
written independently from their published designs and observed behavior.
Telegram-iOS is the exception: Steve Korshakov has personal permission to use
its code in UltraView (recorded 2026-10-31), so parts of the list may be
adapted from it. Each commit that does so names the Telegram-iOS path it
adapts.
