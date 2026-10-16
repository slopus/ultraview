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
//   UltraNode    nodes: measured and laid out off the main thread.
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
            name: "UltraNode",
            dependencies: ["UltraLayout"]
        ),
        .target(
            name: "UltraList",
            dependencies: ["UltraLayout", "UltraNode"]
        ),
        .target(
            name: "UltraView",
            dependencies: ["UltraLayout", "UltraNode", "UltraList"]
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
            name: "UltraNodeTests",
            dependencies: ["UltraNode"]
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
    ]
)
