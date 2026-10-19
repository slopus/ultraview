#if canImport(UIKit)
import XCTest
import UIKit
import UltraView
@testable import UltraList

@MainActor
final class KeyboardDeinitRuntimeTests: XCTestCase {
    func testMainQueueReleaseRemovesAttachmentsAndRestoresTheOwnedHost() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for mode in ScrollEngineMode.allCases {
            for phase in ReleasePhase.allCases {
                let oldKey = scene.windows.first { $0.isKeyWindow }
                let window = UIWindow(windowScene: scene), keyboardWindow = UIWindow(windowScene: scene)
                let controller = UIViewController(), keyboardController = UIViewController()
                window.frame = scene.effectiveGeometry.coordinateSpace.bounds
                keyboardWindow.frame = window.frame
                window.rootViewController = controller; keyboardWindow.rootViewController = keyboardController
                window.makeKeyAndVisible(); keyboardWindow.isHidden = false
                defer {
                    window.isHidden = true; keyboardWindow.isHidden = true
                    window.rootViewController = nil; keyboardWindow.rootViewController = nil
                    oldKey?.makeKeyAndVisible()
                }
                let coordinate = try XCTUnwrap(controller.view), keyboardRoot = try XCTUnwrap(keyboardController.view)
                let list = UltraListView(engineMode: mode)
                list.frame = coordinate.bounds; coordinate.addSubview(list)
                list.applyChanges(items: []); window.layoutIfNeeded(); keyboardWindow.layoutIfNeeded()
                let height = min(300, window.bounds.height * 0.45), top = window.bounds.maxY - height
                let host = UIView(frame: .init(x: 0, y: top, width: window.bounds.width, height: height))
                keyboardRoot.addSubview(host)
                let originalRecognizers = Set((window.gestureRecognizers ?? []).map(ObjectIdentifier.init))
                let originalViews = Set(window.subviews.map(ObjectIdentifier.init))
                let log = ReleaseLog(), holder = DriverHolder()
                holder.value = KeyboardDismissalController(scrollView: list, coordinateView: coordinate,
                    accessoryHeight: { 52 }, restingHeight: { 0 }, hasInput: { true },
                    lookupHost: { _ in log.lookups += 1; return .init(window: keyboardWindow, view: host) },
                    update: { _ in log.updates += 1 })
                holder.value?.refresh()
                let recognizers = (window.gestureRecognizers ?? []).filter { !originalRecognizers.contains(ObjectIdentifier($0)) }
                let views = window.subviews.filter { !originalViews.contains(ObjectIdentifier($0)) }
                XCTAssertEqual(recognizers.count, 1, "\(mode)/\(phase)")
                XCTAssertEqual(views.count, 1, "\(mode)/\(phase)")
                let recognizer = try XCTUnwrap(recognizers.first), commitView = try XCTUnwrap(views.first)
                if phase != .idle {
                    XCTAssertTrue(try XCTUnwrap(holder.value).begin(y: top - 92, time: 0, touchedView: list))
                    XCTAssertTrue(try XCTUnwrap(holder.value).move(y: top + 65, time: 0.1))
                    window.layoutIfNeeded(); CATransaction.flush()
                    try await Task.sleep(for: .milliseconds(35))
                    XCTAssertEqual(holder.value?.ownership, .tracking)
                    XCTAssertLessThan(host.layer.bounds.origin.y, 0)
                    if phase == .returning {
                        holder.value?.end(y: top + 65, time: 0.4)
                        window.layoutIfNeeded(); CATransaction.flush()
                        try await Task.sleep(for: .milliseconds(35))
                        XCTAssertEqual(holder.value?.ownership, .returning)
                        XCTAssertNotNil(host.layer.animation(forKey: "ultraview.keyboard.dismissal"))
                    }
                } else {
                    XCTAssertEqual(holder.value?.ownership, .idle)
                }
                holder.released = holder.value
                // UIKit releases controllers from plain main-queue callbacks too,
                // outside a Swift task. Exercise that lifetime explicitly.
                DispatchQueue.main.async { holder.value = nil }
                for _ in 0..<100 where holder.released != nil { try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertNil(holder.released, "\(mode)/\(phase)")
                XCTAssertNil(recognizer.view)
                XCTAssertNil(commitView.superview)
                XCTAssertEqual(host.layer.bounds.origin.y, 0)
                XCTAssertNil(host.layer.animation(forKey: "ultraview.keyboard.dismissal"))
                let lookups = log.lookups, updates = log.updates
                NotificationCenter.default.post(name: UIResponder.keyboardDidShowNotification, object: nil)
                window.setNeedsLayout(); window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(35))
                XCTAssertEqual(log.lookups, lookups, "A released observer must not refresh the host")
                XCTAssertEqual(log.updates, updates, "Detached input and layout callbacks must not update")
                print("KEYBOARD_DEINIT engine=\(mode) phase=\(phase) released=true recognizerDetached=true commitViewDetached=true hostRestored=true observerSilent=true")
                list.haltScrolling()
            }
        }
    }

    private enum ReleasePhase: CaseIterable { case idle, tracking, returning }
}

@MainActor private final class DriverHolder {
    var value: KeyboardDismissalController?
    weak var released: KeyboardDismissalController?
}

@MainActor private final class ReleaseLog {
    var lookups = 0
    var updates = 0
}
#endif