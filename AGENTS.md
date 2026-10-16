# UltraView

A Swift library for fast UI on iOS: nodes measured, laid out and rendered
off the main thread, flexbox layout through Yoga, and a virtualized list with
its own scroller. README.md explains what it is and how to use it.

## Rules

1. **References are not sources.** The projects listed under *Inspired by* in
   README.md are references only. Study how they work, then write our own
   design in our own words. Never copy or translate their code line by line,
   and never bring in their code, comments, file layout, license or notice
   text. Name them only in that README section: not in code, comments, docs,
   tests or commit messages.
2. **Dependencies come through SwiftPM only.** Nothing is vendored. Yoga is
   pinned to an exact release in Package.swift; bump it on purpose and update
   Package.resolved with it. The repo has no LICENSE yet; don't add one.
3. **Swift 6 language mode, strict concurrency, no warnings.** No class
   prefixes: module names are the namespace.
4. **iOS 26 and macOS 26 minimum** (`swift-tools-version: 6.2`). The tools
   version stays at 6.2 so Xcode 26 can read the manifest; don't raise it
   past what the oldest supported Xcode ships. The deployment target is set in
   Package.swift and project.yml; keep them equal. Node state may use the
   `Synchronization` module (`Mutex`, `Atomic`).
5. **The main thread only applies.** Measurement, layout, text layout and
   rendering run off the main thread and produce values (`LayoutResult` and
   whatever follows it). The main thread assigns frames, contents and
   layers, and does nothing that scales with content. Types that hold mutable
   state that crosses threads are `Sendable` through `Mutex`/`Atomic`, not
   `@unchecked Sendable` without a reason written next to it. A non-`Sendable`
   type (like `LayoutNode`) belongs to one task at a time.
6. **Everything that doesn't need UIKit is tested on Linux.** UIKit code is
   wrapped in `#if canImport(UIKit)`, so every target builds on Linux. Keep
   math (layout, scroll physics, virtualization) in UIKit-free files with
   exact-value tests.
7. **The Xcode project is generated** by XcodeGen from project.yml. Never
   commit `*.xcodeproj`, `.build/`, `xtool/`, `.bsp/` or `.context/`. Scratch
   files go in `.context/`.

## Layout

```
Sources/
  UltraLayout/    Yoga behind a Swift API. Foundation (+ CoreGraphics) only.
  UltraNode/      Node: the unit of measurement, layout and rendering.
  UltraList/      The list and its scroller (gestures, deceleration, bounce,
                  indicators), placing item nodes directly. No UIScrollView.
  UltraView/      Umbrella module; only `@_exported import`s.
  UltraViewDemo/  The demo app (an xtool library product; the XcodeGen app
                  target compiles the same directory).
Tests/
  UltraLayoutTests, UltraNodeTests, UltraListTests   run on Linux and in the
                                                     simulator
  UltraViewUIKitTests                                simulator only
App/Info.plist    the demo's Info.plist (xtool and Xcode)
```

Dependencies only point down: UltraLayout ← UltraNode ← UltraList ←
UltraView ← UltraViewDemo. A new test directory needs a `.testTarget` in
Package.swift and a target in project.yml (template `PackageTests`, plus the
`UltraViewDemo` scheme's test list).

## Yoga

- Only UltraLayout talks to Yoga, through `internal import yoga`. No Yoga
  type appears in a public API, so clients never see it.
- Yoga's public headers are plain C, so it is imported as a C module. Nothing
  enables C++ interop, and nothing should: it would spread to every client.
  Yoga's own sources are C++20 and compiled by SwiftPM/Xcode as part of the
  package.
- Import the module `yoga` (from `yoga/module.modulemap`), never `core` (the
  SwiftPM target name), whose generated module map covers Yoga's C++ headers.
- Yoga's enums import as Swift enums on Apple platforms (its headers use
  `NS_ENUM` when Objective-C is available) but as C structs on Linux. Convert
  through the raw value as `Sources/UltraLayout/Yoga.swift` does, and test
  each case's effect on frames.
- Our styles use Yoga's own defaults (column direction, `flexShrink` 0), not
  the web's.
- `import Foundation` doesn't bring CoreGraphics' Swift API with every SDK.
  UltraLayout re-exports CoreGraphics on Apple platforms; import UltraLayout
  in files that use `CGRect`/`CGFloat`.

## Building and testing

Linux (see `scripts/build.sh` for the environment variables):

```sh
scripts/build.sh test   # swift build + swift test, native build system
scripts/build.sh ios    # cross-build for arm64-apple-ios and -ios-simulator
scripts/build.sh app    # xtool dev build -> xtool/UltraViewDemo.app
```

- Always pass `--build-system native` to `swift build`/`swift test`; the
  default build system doesn't target iOS from Linux.
  xtool picks its own build system and works.
- Test targets don't cross-build for iOS on Linux (the Darwin SDK lacks
  Swift Testing's overlays); they build and run in Xcode.

macOS, in the repo:

```sh
xcodegen
xcodebuild test -project UltraView.xcodeproj -scheme UltraViewDemo \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```
