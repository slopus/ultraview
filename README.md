# UltraView

A Swift library for fast UI on iOS. Views are described as a tree of nodes
that are measured, laid out and rendered off the main thread; the main thread
only applies finished results. Layout is flexbox, computed by
[Yoga](https://github.com/facebook/yoga). On top of nodes sits a virtualized
list with its own scroller instead of `UIScrollView`.

This is the bootstrap: the package, build setup, tests and a demo app work,
but the modules hold placeholders.

| Module        | What it is                                                         |
| ------------- | ------------------------------------------------------------------ |
| `UltraLayout` | Yoga flexbox behind a Swift API. Foundation only, tested on Linux. |
| `UltraNode`   | Nodes: measured and laid out off the main thread.                  |
| `UltraList`   | The list and its scroller. The math is tested on Linux.            |
| `UltraView`   | Umbrella: `import UltraView` re-exports the three above.           |

Requires iOS 26 and Swift 6.2 (Xcode 26).

## Using it

```swift
.package(url: "https://github.com/slopus/ultraview.git", branch: "main")
// target dependency:
.product(name: "UltraView", package: "ultraview")
```

```swift
import UltraView

var row = LayoutStyle()
row.flexDirection = .row
row.gap = 8
var tile = LayoutStyle()
tile.flexGrow = 1
let tree = Node(style: row, children: [Node(style: tile), Node(style: tile)])

// Any thread:
let result = tree.layout(width: 320, height: 100)
// Main thread, with views that mirror the tree:
result.apply(to: containerView)
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

From the command line:

```sh
xcodebuild test -project UltraView.xcodeproj -scheme UltraViewDemo \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## Inspired by

- [Texture](https://github.com/TextureGroup/Texture) (formerly
  AsyncDisplayKit): node-based UI with measurement, layout and rendering off
  the main thread.
- The `ListView` in [Telegram-iOS](https://github.com/TelegramMessenger/Telegram-iOS)'s
  Display module: a virtualized list that positions its item nodes itself.

UltraView contains no code from either project.
