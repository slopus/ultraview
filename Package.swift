// swift-tools-version: 6.2

import PackageDescription

// One package serves three consumers:
//   - `swift build` / `swift test` on Linux and macOS: every target builds,
//     and everything that doesn't need UIKit is tested. UIKit code is wrapped
//     in `#if canImport(UIKit)` and compiles to nothing off Apple platforms.
//   - xtool: packages the `UltraViewDemo` library product as the demo app.
//   - XcodeGen (`project.yml`): the Xcode app target compiles
//     Sources/UltraViewDemo itself and links the `UltraView` product; the
//     test bundles compile the Tests/ directories.
//
// Module layers, bottom to top:
//   UltraLayout  Yoga flexbox behind a Swift API. Foundation only.
//   UltraCore    the node pipeline and the UltraNode, UltraTextNode and
//                UltraScrollNode components: measured, laid out and drawn
//                off the main thread, applied on it.
//   UltraList    the list and its own scroller, built on nodes.
//   UltraView    umbrella that re-exports the three above.

let package = Package(
    name: "UltraView",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "UltraView", targets: ["UltraView"]),
        // The demo app. xtool expects the app to be a library product.
        .library(name: "UltraViewDemo", targets: ["UltraViewDemo"]),
    ],
    dependencies: [
        // Imported as C (`internal import yoga` in UltraLayout only), so
        // nothing needs C++ interop.
        .package(url: "https://github.com/facebook/yoga.git", exact: "3.2.1"),
    ],
    targets: [
        .target(
            name: "UltraLayout",
            dependencies: [.product(name: "yoga", package: "yoga")]
        ),
        .target(
            name: "UltraCore",
            dependencies: ["UltraLayout"]
        ),
        .target(
            name: "UltraList",
            dependencies: ["UltraLayout", "UltraCore"]
        ),
        .target(
            name: "UltraView",
            dependencies: ["UltraLayout", "UltraCore", "UltraList"]
        ),
        .target(
            name: "UltraViewDemo",
            dependencies: ["UltraView"]
        ),
        .testTarget(
            name: "UltraLayoutTests",
            dependencies: ["UltraLayout"]
        ),
        .testTarget(
            name: "UltraCoreTests",
            dependencies: ["UltraCore", "UltraLayout"]
        ),
        .testTarget(
            name: "UltraListTests",
            dependencies: ["UltraList", "UltraLayout"]
        ),
        .testTarget(
            // Needs UIKit. Compiles to nothing on Linux; runs in the iOS
            // simulator through the XcodeGen project.
            name: "UltraViewUIKitTests",
            dependencies: ["UltraView"]
        ),
        .testTarget(
            // UI automation runs through the XcodeGen performance scheme.
            name: "UltraViewPerformanceTests",
            dependencies: ["UltraView"]
        ),
    ]
)
