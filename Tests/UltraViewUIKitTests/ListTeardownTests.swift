#if canImport(UIKit)
import UIKit
import XCTest
@testable import UltraList

/// A list freed where a host frees it: by the autorelease pool drained after
/// a main-actor job of an async test. On an iOS 26 device an isolated deinit
/// in the list's frame-rate holds crashed the runtime there ("pointer being
/// freed was not allocated"); the simulator didn't show it.
final class ListTeardownTests: XCTestCase {
    @MainActor func testAListFreedAtTheEndOfAnAsyncTestTearsDown() async throws {
        let window = makeWindow()
        window.frame = .init(x: 0, y: 0, width: 320, height: 400); window.isHidden = false
        defer { window.isHidden = true }
        weak var freed: UltraListView?
        do {
            let list = UltraListView()
            list.frame = window.bounds; window.addSubview(list)
            list.bottomGravity = .init()
            list.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            list.removeFromSuperview()
            freed = list
            _ = Unmanaged.passRetained(list).autorelease()
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(freed)
    }

    @MainActor func testAHeldFrameRateHoldFreedAtTheEndOfAnAsyncTestStopsItsLink() async throws {
        weak var freed: FrameRateHold?
        do {
            let hold = FrameRateHold()
            hold.hold(maximumFramesPerSecond: 120)
            try await Task.sleep(for: .milliseconds(30))
            freed = hold
            _ = Unmanaged.passRetained(hold).autorelease()
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(freed)
    }
}
#endif
