#if canImport(UIKit)
import XCTest
import UIKit
import UltraView
@testable import UltraList
#if canImport(UltraViewDemoApp)
@testable import UltraViewDemoApp
#else
@testable import UltraViewDemo
#endif

@MainActor
final class KeyboardReturnMomentumRuntimeTests: XCTestCase {
    func testReturningKeyboardPreservesReleasedMomentumInEveryEngine() async throws {
        for mode in ScrollEngineMode.allCases {
            let fixture = try await ReturnFixture(mode: mode)
            defer { fixture.close() }
            let list = fixture.list
            fixture.controller.applyDrivenKeyboard(.init(height: 58, transition: .immediate, phase: .tracking))
            list.beginMomentum(velocity: 600)
            XCTAssertTrue(list.isDecelerating, "\(mode)")
            XCTAssertFalse(list.isTracking || list.isDragging, "\(mode)")
            list.engine.sync()
            let offset = list.currentScrollOffset
            fixture.controller.applyDrivenKeyboard(.init(height: 252,
                transition: KeyboardDismissalMotion.releaseTransition(dismisses: false), phase: .returning))
            let computedShift = list.currentScrollOffset - offset
            XCTAssertEqual(list.currentScrollOffset, offset, accuracy: 3,
                           "\(mode): keyboard return must not shift a released coast")
            let correction = viewportCorrectionFrom(list)
            XCTAssertEqual(correction, 0, accuracy: 3, "\(mode)")
            CATransaction.flush()
            var samples: [CGFloat] = []
            for _ in 0..<26 {
                try await Task.sleep(for: .milliseconds(16))
                let row = try XCTUnwrap(fixture.row.layer.presentation())
                let window = try XCTUnwrap(fixture.window.layer.presentation())
                samples.append(row.convert(row.bounds, to: window).midY)
            }
            let increments = zip(samples.dropFirst(), samples).map { $0 - $1 }.filter { abs($0) > 0.15 }
            let travel = try XCTUnwrap(samples.last) - XCTUnwrap(samples.first)
            XCTAssertGreaterThan(abs(travel), 20, "\(mode): coast must render")
            XCTAssertFalse(increments.contains { $0 > 0 } && increments.contains { $0 < 0 },
                           "\(mode): return reversed the row's rendered travel: \(increments)")
            print("KEYBOARD_RETURN_COAST mode=\(mode) computedShift=\(computedShift) initialCorrection=\(correction) travel=\(travel) increments=\(increments)")
        }
    }

    func testStationaryKeyboardReturnStillCompensatesInEveryEngine() async throws {
        for mode in ScrollEngineMode.allCases {
            let fixture = try await ReturnFixture(mode: mode)
            defer { fixture.close() }
            let list = fixture.list
            fixture.controller.applyDrivenKeyboard(.init(height: 58, transition: .immediate, phase: .tracking))
            list.haltScrolling()
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(35))
            let offset = list.currentScrollOffset, inset = list.viewportInsets.top
            let rowY = fixture.row.layer.convert(fixture.row.layer.bounds, to: fixture.window.layer).minY
            let gap = fixture.row.layer.convert(fixture.row.layer.bounds, to: fixture.window.layer).maxY
                - fixture.bar.layer.convert(fixture.bar.layer.bounds, to: fixture.window.layer).minY
            fixture.window.layer.speed = 0; fixture.window.layer.timeOffset = 100
            fixture.controller.applyDrivenKeyboard(.init(height: 252,
                transition: KeyboardDismissalMotion.releaseTransition(dismisses: false), phase: .returning))
            let delta = list.viewportInsets.top - inset
            XCTAssertGreaterThan(delta, 100, "\(mode)")
            let rowShift = fixture.row.layer.convert(fixture.row.layer.bounds, to: fixture.window.layer).minY - rowY
            XCTAssertEqual(rowShift, -delta, accuracy: 0.5, "\(mode)")
            let correction = viewportCorrectionFrom(list)
            XCTAssertEqual(correction, delta, accuracy: 0.5, "\(mode)")
            print("KEYBOARD_RETURN_STATIONARY mode=\(mode) insetDelta=\(delta) offsetDelta=\(list.currentScrollOffset - offset) rowShift=\(rowShift) correction=\(correction)")
            for progress in [0.0, 0.25, 0.5, 1.001] {
                fixture.window.layer.timeOffset = 100 + 0.25 * progress
                CATransaction.flush()
                try await Task.sleep(for: .milliseconds(35))
                let root = try XCTUnwrap(fixture.window.layer.presentation())
                let row = try XCTUnwrap(fixture.row.layer.presentation())
                let bar = try XCTUnwrap(fixture.bar.layer.presentation())
                XCTAssertEqual(row.convert(row.bounds, to: root).maxY - bar.convert(bar.bounds, to: root).minY,
                               gap, accuracy: 0.75, "\(mode)/\(progress)")
            }
        }
    }

    func testKeyboardScreenFramesResolveInsideOffsetWindowsInEveryEngine() async throws {
        for mode in ScrollEngineMode.allCases {
            for system in [false, true] {
                let fixture = try await ReturnFixture(mode: mode, system: system, nested: true)
                defer { fixture.close() }
                let scene = try XCTUnwrap(fixture.window.windowScene)
                for originY in [115.0, 251.0] {
                    fixture.window.frame = .init(x: 37, y: originY, width: 320, height: 430)
                    fixture.layoutNestedController()
                    let windowFrame = CGRect(x: 0, y: 280, width: 320, height: 150)
                    let screenFrame = fixture.window.convert(windowFrame, to: scene.screen.coordinateSpace)
                    let expected = fixture.controller.view.convert(windowFrame, from: fixture.window)
                    let driver = KeyboardDismissalController(scrollView: fixture.list, coordinateView: fixture.controller.view,
                        accessoryHeight: { 44 }, restingHeight: { 0 }, hasInput: { true }, lookupHost: { _ in nil }, update: { _ in })
                    XCTAssertEqual(try XCTUnwrap(driver.resolvedKeyboardFrame(screenFrame)), expected,
                                   "\(mode)/system=\(system)/y=\(originY)")
                    driver.invalidate()
                    NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
                        userInfo: [UIResponder.keyboardFrameBeginUserInfoKey: screenFrame,
                                   UIResponder.keyboardFrameEndUserInfoKey: screenFrame,
                                   UIResponder.keyboardAnimationDurationUserInfoKey: 0.0,
                                   UIResponder.keyboardAnimationCurveUserInfoKey: UInt(7)])
                    let guideEquivalentHeight = fixture.controller.view.bounds.maxY - expected.minY
                    XCTAssertEqual(fixture.list.viewportInsets.top,
                        max(guideEquivalentHeight, fixture.controller.view.safeAreaInsets.bottom) + fixture.bar.bounds.height + 8,
                        accuracy: 0.5, "\(mode)/system=\(system)/y=\(originY)")
                    XCTAssertEqual(fixture.bar.frame.maxY, expected.minY - 8, accuracy: 0.5)
                    print("KEYBOARD_OFFSET_WINDOW mode=\(mode) system=\(system) windowY=\(originY) expectedTop=\(expected.minY) composerBottom=\(fixture.bar.frame.maxY) inset=\(fixture.list.viewportInsets.top)")
                }
            }
        }
    }
}

@MainActor
private func viewportCorrectionFrom(_ list: UltraListView) -> Double {
    let animation = list.contentView.layer.animation(forKey: "ultraview.list.viewportOffset")
    if let basic = animation as? CABasicAnimation { return (basic.fromValue as? NSNumber)?.doubleValue ?? 0 }
    if let keyframes = animation as? CAKeyframeAnimation { return (keyframes.values?.first as? NSNumber)?.doubleValue ?? 0 }
    return 0
}

@MainActor
private final class ReturnFixture {
    let controller: ListChatController
    let window: UIWindow
    let wrapper: UIViewController?
    let bar: UIView
    let row: UIView
    var list: UltraListView { controller.list }
    private let arguments: [String: Any]

    init(mode: ScrollEngineMode, system: Bool = false, nested: Bool = false) async throws {
        let defaults = UserDefaults.standard
        arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var configured = arguments; configured["listSystemKeyboardDismissal"] = system ? "YES" : "NO"
        defaults.setVolatileDomain(configured, forName: UserDefaults.argumentDomain)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = ListChatController(mode: mode)
        self.window = window; self.controller = controller
        if nested {
            let parent = UIViewController(); wrapper = parent
            window.rootViewController = parent
            parent.loadViewIfNeeded(); parent.addChild(controller)
            parent.view.addSubview(controller.view); controller.didMove(toParent: parent)
        } else {
            wrapper = nil; window.rootViewController = controller
        }
        window.isHidden = false
        controller.loadViewIfNeeded()
        window.layoutIfNeeded()
        if nested { controller.view.frame = .init(x: 11, y: 29, width: 298, height: 370) }
        controller.view.layoutIfNeeded()
        for _ in 0..<150 where controller.list.loadedIndexRange.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        controller.list.scrollTo(.init(index: 25), transition: .none)
        for _ in 0..<150 where !controller.list.loadedIndexRange.contains(25) { try await Task.sleep(for: .milliseconds(20)) }
        row = try XCTUnwrap(controller.list.loadedItemView(at: 25))
        bar = try XCTUnwrap(controller.view.subviews.first { $0.accessibilityIdentifier == "composerBar" })
    }

    func layoutNestedController() {
        window.layoutIfNeeded()
        controller.view.frame = .init(x: 11, y: 29, width: 298, height: 370)
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
    }

    func close() {
        list.haltScrolling(); controller.keyboardDismissal?.invalidate()
        window.layer.speed = 1; window.layer.timeOffset = 0
        window.isHidden = true; window.rootViewController = nil
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }
}
#endif