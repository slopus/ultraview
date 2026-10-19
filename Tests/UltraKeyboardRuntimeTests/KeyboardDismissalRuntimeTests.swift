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
final class KeyboardDismissalRuntimeTests: XCTestCase {
    func testAnEmptyChatComposerAnimatesOnKeyboardShowAndHide() async throws {
        for mode in ScrollEngineMode.allCases {
            let fixture = try await Fixture(mode: mode)
            defer { fixture.close() }
            fixture.list.applyChanges(items: [], transition: .none)
            fixture.controller.keyboardFrameChanged(height: 0, duration: 0, curve: 7)
            CATransaction.flush(); try await Task.sleep(for: .milliseconds(50))
            fixture.window.layer.speed = 0; fixture.window.layer.timeOffset = 100
            for hiding in [false, true] {
                let layer = fixture.bar.layer
                let initialY = try XCTUnwrap(layer.presentation()).position.y
                let start = fixture.window.layer.timeOffset
                fixture.controller.keyboardFrameChanged(height: hiding ? 0 : 252, duration: 1, curve: 7, fullHeight: 335,
                                                        physicalBeginHeight: hiding ? 252 : 0, physicalEndHeight: hiding ? 0 : 252)
                let animation = try XCTUnwrap(composerMotion(layer))
                XCTAssertTrue(animation is CAKeyframeAnimation)
                XCTAssertEqual(animation.duration / Double(animation.speed), 1, accuracy: 1e-6)
                XCTAssertTrue(fixture.list.items.isEmpty && fixture.list.loadedIndexRange.isEmpty)
                let targetY = layer.position.y
                XCTAssertGreaterThan(abs(targetY - initialY), 100)
                CATransaction.flush(); try await Task.sleep(for: .milliseconds(35))
                fixture.window.layer.timeOffset = start + 0.25
                CATransaction.flush(); try await Task.sleep(for: .milliseconds(35))
                let shownY = try XCTUnwrap(layer.presentation()).position.y
                XCTAssertGreaterThan(abs(shownY - initialY), 1, "\(mode)/hide=\(hiding): empty-chat motion must render")
                XCTAssertEqual(shownY < initialY, !hiding)
                fixture.window.layer.timeOffset = start + 1.001
                CATransaction.flush(); try await Task.sleep(for: .milliseconds(35))
                XCTAssertEqual(try XCTUnwrap(layer.presentation()).position.y, targetY, accuracy: 0.5)
            }
        }
    }

    func testTheSystemArgumentSelectsTheInteractiveControlPath() {
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = original; arguments["listSystemKeyboardDismissal"] = "YES"
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        for mode in ScrollEngineMode.allCases {
            let controller = ListChatController(mode: mode)
            controller.loadViewIfNeeded()
            XCTAssertNil(controller.keyboardDismissal)
            XCTAssertEqual(controller.list.keyboardDismissMode, .interactive)
        }
    }

    func testKeyboardComposerAndRowsShareTheReleaseClock() async throws {
        for mode in ScrollEngineMode.allCases {
            for scale in [1.0, 2] {
                for dismisses in [false, true] {
                    let fixture = try await Fixture(mode: mode, scale: scale)
                    defer { fixture.close() }
                    let driver = fixture.driver, top = fixture.keyboardTop
                    XCTAssertTrue(driver.begin(y: top - fixture.accessory - 40, time: 0, touchedView: fixture.list))
                    driver.move(y: top + 65, time: 0.1)
                    CATransaction.flush(); try await Task.sleep(for: .milliseconds(35))
                    let row = try XCTUnwrap(fixture.list.loadedItemView(at: 25))
                    let relative = try fixture.rowGap(row)
                    let initialOffset = -fixture.host.layer.bounds.origin.y
                    let initialBottom = fixture.bar.frame.maxY
                    driver.end(y: top + 65, time: dismisses ? 0.11 : 0.4)
                    CATransaction.flush(); try await Task.sleep(for: .milliseconds(35))
                    let hostAnimation = try XCTUnwrap(fixture.host.layer.animation(forKey: "ultraview.keyboard.dismissal"))
                    let barAnimation = try XCTUnwrap(composerMotion(fixture.bar.layer))
                    let listAnimation = try XCTUnwrap(fixture.list.contentView.layer.animation(forKey: "ultraview.list.viewportOffset"))
                    let begin = fixture.host.layer.convertTime(hostAnimation.beginTime, to: nil)
                    XCTAssertEqual(fixture.bar.layer.convertTime(barAnimation.beginTime, to: nil), begin, accuracy: 0.000_001)
                    XCTAssertEqual(fixture.list.contentView.layer.convertTime(listAnimation.beginTime, to: nil), begin, accuracy: 0.000_001)
                    let duration = hostAnimation.duration / Double(hostAnimation.speed)
                    XCTAssertEqual(hostAnimation is CASpringAnimation, dismisses)
                    XCTAssertEqual(barAnimation.duration / Double(barAnimation.speed), duration, accuracy: 1e-9)
                    XCTAssertEqual(listAnimation.duration / Double(listAnimation.speed), duration, accuracy: 1e-9)
                    let appBegin = fixture.window.layer.convertTime(begin, from: nil)
                    let keyboardBegin = fixture.keyboardWindow.layer.convertTime(begin, from: nil)
                    let targetOffset = -fixture.host.layer.bounds.origin.y
                    let targetBottom = fixture.bar.frame.maxY
                    fixture.window.layer.speed = 0; fixture.keyboardWindow.layer.speed = 0
                    for phase in [0.0, 0.1, 0.25, 0.5, 0.8, 1] {
                        CATransaction.begin(); CATransaction.setDisableActions(true)
                        fixture.window.layer.timeOffset = appBegin + max(0.000_001, duration * phase)
                        fixture.keyboardWindow.layer.timeOffset = keyboardBegin + max(0.000_001, duration * phase)
                        CATransaction.commit(); CATransaction.flush()
                        try await Task.sleep(for: .milliseconds(35))
                        let shownHost = try XCTUnwrap(fixture.host.layer.presentation())
                        let shownBar = try XCTUnwrap(fixture.bar.layer.presentation())
                        let root = try XCTUnwrap(fixture.window.layer.presentation())
                        let barBottom = shownBar.convert(shownBar.bounds, to: root).maxY
                        let progress = (-shownHost.bounds.origin.y - initialOffset) / (targetOffset - initialOffset)
                        let expectedBottom = initialBottom + (targetBottom - initialBottom) * progress
                        let label = "\(mode)/scale=\(scale)/dismiss=\(dismisses)/phase=\(phase)"
                        XCTAssertEqual(barBottom, expectedBottom, accuracy: 0.5, label)
                        XCTAssertEqual(try fixture.rowGap(row), relative, accuracy: 0.5, label)
                    }
                }
            }
        }
    }

    func testRemovingTheHostAnimationStillResolvesTheRelease() async throws {
        for mode in ScrollEngineMode.allCases {
            let fixture = try await Fixture(mode: mode)
            defer { fixture.close() }
            let driver = fixture.driver, top = fixture.keyboardTop
            XCTAssertTrue(driver.begin(y: top - fixture.accessory - 40, time: 0, touchedView: fixture.list))
            driver.move(y: top + 65, time: 0.1)
            driver.end(y: top + 65, time: 0.4)
            XCTAssertTrue(driver.isDriving)
            CATransaction.flush(); try await Task.sleep(for: .milliseconds(20))
            fixture.host.layer.removeAllAnimations()
            CATransaction.flush(); try await Task.sleep(for: .milliseconds(80))
            XCTAssertFalse(driver.isDriving, "\(mode): an unfinished animation must release ownership")
            XCTAssertEqual(fixture.host.layer.bounds.origin.y, 0, accuracy: 0.5)
            XCTAssertNil(composerMotion(fixture.bar.layer))
            XCTAssertNil(fixture.list.contentView.layer.animation(forKey: "ultraview.list.viewportOffset"))
        }
    }

    func testALateHideCannotCollapseAFocusedVisibleKeyboard() async throws {
        for mode in ScrollEngineMode.allCases {
            let fixture = try await Fixture(mode: mode)
            defer { fixture.close() }
            let insets = fixture.list.viewportInsets, frame = fixture.bar.frame
            NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
            XCTAssertEqual(fixture.list.viewportInsets, insets)
            XCTAssertEqual(fixture.bar.frame, frame)
            XCTAssertFalse(fixture.driver.isDriving)
        }
    }

    func testFingerTrackingDoesNotAddTheComposerTravelToTheRows() async throws {
        for mode in ScrollEngineMode.allCases {
            let fixture = try await Fixture(mode: mode)
            defer { fixture.close() }
            let list = fixture.list, driver = fixture.driver
            let row = try XCTUnwrap(list.loadedItemView(at: 25))
            let before = row.convert(row.bounds, to: fixture.window).midY
            let start = fixture.keyboardTop - fixture.accessory - 40, travel = 120.0
            let first = list.contentView.convert(CGPoint(x: 0, y: start), from: fixture.window)
            let last = list.contentView.convert(CGPoint(x: 0, y: start + travel), from: fixture.window)
            let now = CACurrentMediaTime()
            list.receiveScrollInput(.init(time: now, phase: .touchDown))
            list.receiveScrollInput(.init(time: now, phase: .began))
            XCTAssertTrue(driver.begin(y: start, time: 0, touchedView: list))
            list.receiveScrollInput(.init(time: now + 0.1, phase: .changed, translation: .init(x: 0, y: Double(last.y - first.y))))
            driver.move(y: start + travel, time: 0.1)
            CATransaction.flush(); try await Task.sleep(for: .milliseconds(35))
            XCTAssertEqual(Double(row.convert(row.bounds, to: fixture.window).midY - before), travel, accuracy: 0.5, "\(mode)")
            driver.end(y: start + travel, time: 0.2, cancelled: true)
            list.receiveScrollInput(.init(time: now + 0.2, phase: .cancelled))
        }
    }

    func testSubpixelTrackingUpdatesTheComposerAtEachLayout() async throws {
        for mode in ScrollEngineMode.allCases {
            let fixture = try await Fixture(mode: mode)
            defer { fixture.close() }
            let top = fixture.keyboardTop
            XCTAssertTrue(fixture.driver.begin(y: top - fixture.accessory - 40, time: 0, touchedView: fixture.list))
            for step in 0...4 {
                fixture.driver.move(y: top + 65 + Double(step) * 0.125, time: 0.1 + Double(step) * 0.01)
                fixture.window.layoutIfNeeded()
                XCTAssertEqual(Double(fixture.bar.frame.maxY) + 8, top - Double(fixture.host.layer.bounds.origin.y), accuracy: 1e-6)
            }
        }
    }

    func testComposerGrowthDuringTrackingKeepsItsExactBottomAnchor() async throws {
        for mode in ScrollEngineMode.allCases {
            let fixture = try await Fixture(mode: mode)
            defer { fixture.close() }
            let driver = fixture.driver, top = fixture.keyboardTop
            XCTAssertTrue(driver.begin(y: top - fixture.accessory - 40, time: 0, touchedView: fixture.list))
            driver.move(y: top + 65.125, time: 0.1)
            fixture.window.layoutIfNeeded()
            let bottom = fixture.bar.frame.maxY, height = fixture.bar.bounds.height
            let composer = try XCTUnwrap((fixture.bar as? UIStackView)?.arrangedSubviews.compactMap { $0 as? UITextView }.first)
            composer.text = "One\nTwo\nThree"
            fixture.controller.view.setNeedsLayout()
            fixture.window.layoutIfNeeded(); fixture.controller.view.layoutIfNeeded()
            XCTAssertGreaterThan(fixture.bar.bounds.height, height + 10)
            XCTAssertEqual(fixture.bar.frame.maxY, bottom, accuracy: 1e-6,
                           "\(mode): growing the composer must preserve its exact bottom constraint")
        }
    }

    func testTrackingCoalescesUntilLayoutAndKeepsTheLatestAcceptedSample() async throws {
        for mode in ScrollEngineMode.allCases {
            let fixture = try await Fixture(mode: mode)
            defer { fixture.close() }
            let driver = fixture.driver, top = fixture.keyboardTop, before = fixture.bar.frame
            XCTAssertTrue(driver.begin(y: top - fixture.accessory - 40, time: 0, touchedView: fixture.list))
            driver.move(y: top + 50, time: 0.1)
            driver.move(y: top + 70, time: 0.11)
            XCTAssertEqual(fixture.host.layer.bounds.origin.y, 0)
            XCTAssertEqual(fixture.bar.frame, before)
            fixture.window.layoutIfNeeded()
            XCTAssertEqual(-fixture.host.layer.bounds.origin.y, 70 + fixture.accessory, accuracy: 1e-6)
            XCTAssertEqual(fixture.bar.frame.maxY + 8, top + 70 + fixture.accessory, accuracy: 1e-6)
        }
    }

    func testReleaseDropsAnUncommittedDragAndUsesTheCommittedPositionThreshold() async throws {
        for mode in ScrollEngineMode.allCases {
            let fixture = try await Fixture(mode: mode)
            defer { fixture.close() }
            let driver = fixture.driver, top = fixture.keyboardTop
            let end = fixture.window.bounds.maxY - fixture.accessory * 2
            XCTAssertTrue(driver.begin(y: top - fixture.accessory - 40, time: 0, touchedView: fixture.list))
            driver.move(y: end, time: 1)
            driver.end(y: end, time: 2)
            XCTAssertFalse(driver.dismissedInTouchSequence)
            XCTAssertEqual(fixture.host.layer.bounds.origin.y, 0)
            fixture.window.layoutIfNeeded()
            XCTAssertEqual(fixture.host.layer.bounds.origin.y, 0)
            XCTAssertEqual((fixture.host.layer.animation(forKey: "ultraview.keyboard.dismissal") as? CABasicAnimation)?.fromValue as? Double, 0)
        }
    }

    func testAnAncestorCanDeclineAndTheUpperComposerStripCanArm() async throws {
        for mode in ScrollEngineMode.allCases {
            let fixture = try await Fixture(mode: mode)
            defer { fixture.close() }
            let blocked = UIView(), child = UIView()
            fixture.list.addSubview(blocked); blocked.addSubview(child)
            fixture.driver.shouldBegin = { $0 !== blocked }
            let y = fixture.keyboardTop - fixture.accessory - 4
            XCTAssertFalse(fixture.driver.begin(y: y, time: 0, touchedView: child))
            fixture.driver.shouldBegin = nil
            XCTAssertTrue(fixture.driver.begin(y: y, time: 1, touchedView: child))
        }
    }

    func testAnUnmovedTapLeavesKeyboardNotificationsInControl() async throws {
        for mode in ScrollEngineMode.allCases {
            let fixture = try await Fixture(mode: mode)
            defer { fixture.close() }
            let y = fixture.keyboardTop - fixture.accessory - 40
            XCTAssertTrue(fixture.driver.begin(y: y, time: 0, touchedView: fixture.list))
            fixture.driver.end(y: y, time: 0.1)
            XCTAssertFalse(fixture.driver.isDriving)
            let hidden = CGRect(x: 0, y: fixture.window.bounds.maxY, width: fixture.window.bounds.width, height: 300)
            NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil, userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: hidden,
                UIResponder.keyboardAnimationDurationUserInfoKey: 0.2,
                UIResponder.keyboardAnimationCurveUserInfoKey: 7,
            ])
            XCTAssertNotNil(composerMotion(fixture.bar.layer))
        }
    }

    func testAnUnclaimedFlickDuringReturnStartsAtTheDisplayedOffset() async throws {
        for mode in ScrollEngineMode.allCases {
            let fixture = try await Fixture(mode: mode)
            defer { fixture.close() }
            let driver = fixture.driver, top = fixture.keyboardTop
            XCTAssertTrue(driver.begin(y: top - fixture.accessory - 40, time: 0, touchedView: fixture.list))
            driver.move(y: top + 65, time: 0.1)
            fixture.window.layoutIfNeeded()
            driver.end(y: top + 65, time: 0.4)
            fixture.window.layoutIfNeeded()
            CATransaction.flush(); try await Task.sleep(for: .milliseconds(35))
            let clock = fixture.keyboardWindow.layer.convertTime(CACurrentMediaTime(), from: nil)
            fixture.keyboardWindow.layer.speed = 0; fixture.keyboardWindow.layer.timeOffset = clock
            CATransaction.flush(); try await Task.sleep(for: .milliseconds(35))
            let shown = -(try XCTUnwrap(fixture.host.layer.presentation())).bounds.origin.y
            XCTAssertGreaterThan(shown, 1)
            XCTAssertTrue(driver.begin(y: top - fixture.accessory - 0.5, time: 1, touchedView: fixture.list))
            driver.end(y: top - fixture.accessory + 0.5, time: 1.001)
            XCTAssertTrue(driver.dismissedInTouchSequence)
            fixture.window.layoutIfNeeded()
            let animation = try XCTUnwrap(fixture.host.layer.animation(forKey: "ultraview.keyboard.dismissal") as? CASpringAnimation)
            let from = try XCTUnwrap(animation.fromValue as? Double)
            XCTAssertEqual(from, fixture.window.bounds.maxY - top - shown, accuracy: 0.5)
        }
    }

    func testAFastReleaseAboveTheShrunkenKeyboardReturnsIt() async throws {
        for mode in ScrollEngineMode.allCases {
            let fixture = try await Fixture(mode: mode)
            defer { fixture.close() }
            let driver = fixture.driver, top = fixture.keyboardTop, accessory = fixture.accessory
            XCTAssertTrue(driver.begin(y: top - accessory - 1, time: 0, touchedView: fixture.list))
            driver.move(y: top - accessory - 4, time: 0.001)
            fixture.window.layoutIfNeeded()
            var frame = fixture.host.frame
            frame.origin.y += 44; frame.size.height -= 44
            UIView.performWithoutAnimation { fixture.host.frame = frame }
            XCTAssertTrue(driver.handle(Notification(name: UIResponder.keyboardWillChangeFrameNotification, userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: fixture.host.convert(fixture.host.bounds, to: nil),
                UIResponder.keyboardAnimationDurationUserInfoKey: 0.0,
            ])))
            fixture.keyboardWindow.layoutIfNeeded(); CATransaction.flush()
            driver.end(y: top - accessory + 0.5, time: 0.002)
            XCTAssertFalse(driver.dismissedInTouchSequence,
                           "\(mode): the finger plus captured accessory is above the current keyboard top")
            fixture.window.layoutIfNeeded(); CATransaction.flush()
            for _ in 0..<150 where driver.isDriving { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(driver.isDriving)
            XCTAssertEqual(fixture.host.layer.bounds.origin.y, 0, accuracy: 0.5)
        }
    }

    func testAChangedHostHeightIsAppliedWhenOwnedMotionReturnsToIdle() async throws {
        for mode in ScrollEngineMode.allCases {
            for changesDuringReturn in [false, true] {
                let fixture = try await Fixture(mode: mode)
                defer { fixture.close() }
                let driver = fixture.driver, top = fixture.keyboardTop
                XCTAssertTrue(driver.begin(y: top - fixture.accessory - 40, time: 0, touchedView: fixture.list))
                driver.move(y: top + 65, time: 0.1)
                fixture.window.layoutIfNeeded()
                if changesDuringReturn {
                    driver.end(y: top + 65, time: 0.4)
                    fixture.window.layoutIfNeeded()
                }
                var frame = fixture.host.frame
                frame.origin.y -= 44; frame.size.height += 44
                UIView.performWithoutAnimation { fixture.host.frame = frame }
                let notification = Notification(name: UIResponder.keyboardWillChangeFrameNotification, userInfo: [
                    UIResponder.keyboardFrameEndUserInfoKey: fixture.host.convert(fixture.host.bounds, to: nil),
                    UIResponder.keyboardAnimationDurationUserInfoKey: 0.0,
                    UIResponder.keyboardAnimationCurveUserInfoKey: 7,
                ])
                XCTAssertTrue(driver.handle(notification))
                if !changesDuringReturn {
                    driver.end(y: top + 65, time: 0.4, cancelled: true)
                    fixture.window.layoutIfNeeded()
                }
                XCTAssertFalse(driver.dismissedInTouchSequence)
                CATransaction.flush()
                for _ in 0..<150 where driver.isDriving { try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertFalse(driver.isDriving)
                let height = Double(fixture.window.bounds.maxY - frame.minY)
                let label = "\(mode)/duringReturn=\(changesDuringReturn)"
                XCTAssertEqual(try XCTUnwrap(fixture.updates.values.last).height, height, accuracy: 0.5, label)
                XCTAssertEqual(fixture.bar.frame.maxY + 8, frame.minY, accuracy: 0.5, label)
                XCTAssertEqual(fixture.list.viewportInsets.top, height + fixture.bar.bounds.height + 8, accuracy: 0.5, label)
            }
        }
    }

    func testAHeightChangeDuringDismissalKeepsTheHostBelowTheWindow() async throws {
        for mode in ScrollEngineMode.allCases {
            let fixture = try await Fixture(mode: mode)
            defer { fixture.close() }
            let driver = fixture.driver, top = fixture.keyboardTop
            XCTAssertTrue(driver.begin(y: top - fixture.accessory - 40, time: 0, touchedView: fixture.list))
            driver.move(y: top + 65, time: 0.1)
            fixture.window.layoutIfNeeded()
            driver.end(y: top + 65, time: 0.11)
            fixture.window.layoutIfNeeded()
            XCTAssertTrue(driver.dismissedInTouchSequence)
            var frame = fixture.host.frame
            frame.origin.y -= 44; frame.size.height += 44
            UIView.performWithoutAnimation { fixture.host.frame = frame }
            XCTAssertTrue(driver.handle(Notification(name: UIResponder.keyboardWillChangeFrameNotification, userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: fixture.host.convert(fixture.host.bounds, to: nil),
                UIResponder.keyboardAnimationDurationUserInfoKey: 0.0,
            ])))
            CATransaction.flush()
            for _ in 0..<150 where driver.ownership != .awaitingHide { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(driver.ownership, .awaitingHide)
            XCTAssertEqual(fixture.host.layer.bounds.origin.y, -frame.height, accuracy: 0.5,
                           "\(mode): a taller host must be fully below the window before ending editing")
            XCTAssertEqual(try XCTUnwrap(fixture.updates.values.last).height, 0, accuracy: 0.5)
        }
    }

    func testANativeKeyboardHeightChangeIsAppliedAfterOwnedMotion() async throws {
        for mode in ScrollEngineMode.allCases {
            for changesDuringReturn in [false, true] {
                try await checkNativeHeightChange(mode: mode, changesDuringReturn: changesDuringReturn)
            }
        }
    }

    private func checkNativeHeightChange(mode: ScrollEngineMode, changesDuringReturn: Bool) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let oldKey = scene.windows.first { $0.isKeyWindow }
        let controller = ListChatController(mode: mode), window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer {
            controller.keyboardDismissal?.invalidate(); window.endEditing(true)
            window.isHidden = true; window.rootViewController = nil; oldKey?.makeKeyAndVisible()
        }
        if window.bounds.width > window.bounds.height { try await rotate(scene, controller: controller, landscape: false) }
        controller.view.layoutIfNeeded()
        let composer = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UIStackView }.first?.arrangedSubviews.compactMap { $0 as? UITextView }.first)
        let bar = try XCTUnwrap(controller.view.subviews.first { $0.accessibilityIdentifier == "composerBar" })
        XCTAssertTrue(composer.becomeFirstResponder())
        try await Task.sleep(for: .milliseconds(800))
        controller.keyboardDismissal?.invalidate()
        let updates = KeyboardUpdateLog()
        let driver = KeyboardDismissalController(scrollView: controller.list, coordinateView: controller.view,
            accessoryHeight: { [weak bar] in Double(bar?.bounds.height ?? 0) },
            restingHeight: { [weak controller] in Double(controller?.view.safeAreaInsets.bottom ?? 0) },
            hasInput: { [weak composer] in composer?.isFirstResponder == true },
            update: { [weak controller] in updates.values.append($0); controller?.applyDrivenKeyboard($0) })
        controller.keyboardDismissal = driver; driver.refresh()
        XCTAssertTrue(driver.isAvailable)
        let host = try XCTUnwrap(KeyboardHostLookup.find(in: scene))
        let before = host.view.convert(host.view.bounds, to: window)
        let trace = KeyboardRecoveryTrace(window: window, bar: bar)
        defer {
            composer.inputAccessoryView = nil
            if let data = try? JSONSerialization.data(withJSONObject: trace.events, options: [.sortedKeys, .prettyPrinted]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "native-keyboard-height-\(mode)-duringReturn=\(changesDuringReturn)"
                attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        // Keep the owned return alive while native input-view reload finishes.
        controller.list.animationDurationScale = 4
        XCTAssertTrue(driver.begin(y: before.minY - bar.bounds.height - 40, time: 0, touchedView: controller.list))
        driver.move(y: before.minY + 65, time: 0.1)
        window.layoutIfNeeded()
        if changesDuringReturn {
            driver.end(y: before.minY + 65, time: 0.4)
            window.layoutIfNeeded()
        }
        trace.record("before-height-change")
        let accessory = UIView(frame: CGRect(x: 0, y: 0, width: window.bounds.width, height: 64))
        accessory.autoresizingMask = [.flexibleWidth]
        composer.inputAccessoryView = accessory
        composer.reloadInputViews()
        var changed: CGRect?
        for _ in 0..<100 {
            if let current = KeyboardHostLookup.find(in: scene) {
                let frame = current.view.convert(current.view.bounds, to: window)
                if abs(frame.height - before.height) > 32 { changed = frame; break }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let changedFrame = try XCTUnwrap(changed, "The native host must actually change height during this diagnostic")
        for _ in 0..<20 where driver.isDriving
            && trace.count(UIResponder.keyboardWillChangeFrameNotification, endingAt: changedFrame) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(driver.isDriving, "The height must change before ownership ends")
        XCTAssertGreaterThanOrEqual(trace.count(UIResponder.keyboardWillChangeFrameNotification, endingAt: changedFrame), 1,
                                    "A matching native notification must arrive while ownership is held")
        let changedHost = try XCTUnwrap(KeyboardHostLookup.find(in: scene))
        XCTAssertTrue(changedHost.view === host.view, "Replacing the native host is a separate diagnostic outcome")
        trace.record("changed-height-while-owned")
        if !changesDuringReturn {
            driver.end(y: before.minY + 65, time: 0.4, cancelled: true)
            window.layoutIfNeeded()
        }
        XCTAssertFalse(driver.dismissedInTouchSequence)
        CATransaction.flush()
        for _ in 0..<200 where driver.isDriving { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(driver.isDriving)
        trace.record("idle-after-height-change")
        let finalHost = try XCTUnwrap(KeyboardHostLookup.find(in: scene))
        XCTAssertTrue(finalHost.view === host.view)
        XCTAssertEqual(finalHost.view.layer.bounds.origin.y, 0, accuracy: 0.5)
        let final = finalHost.view.convert(finalHost.view.bounds, to: window)
        XCTAssertEqual(final.height, changedFrame.height, accuracy: 0.5)
        let height = Double(controller.view.bounds.maxY - controller.view.convert(final, from: window).minY)
        let inset = max(height, controller.view.safeAreaInsets.bottom) + bar.bounds.height + 8
        XCTAssertEqual(try XCTUnwrap(updates.values.last).height, height, accuracy: 0.5)
        XCTAssertEqual(controller.list.viewportInsets.top, inset, accuracy: 0.5)
        XCTAssertEqual(bar.frame.maxY + 8, min(controller.view.bounds.maxY - controller.view.safeAreaInsets.bottom,
                                            controller.view.convert(final, from: window).minY), accuracy: 0.5)
    }

    func testInteractiveStateUsesExactBoundaryEqualityAndOverlapCanBeNegative() async throws {
        for mode in ScrollEngineMode.allCases {
            let fixture = try await Fixture(mode: mode)
            defer { fixture.close() }
            let driver = fixture.driver, bottom = fixture.window.bounds.maxY
            XCTAssertTrue(driver.begin(y: fixture.keyboardTop - fixture.accessory - 40, time: 0, touchedView: fixture.list))
            driver.move(y: bottom - fixture.accessory, time: 0.1)
            fixture.window.layoutIfNeeded()
            XCTAssertEqual(fixture.updates.values.last?.isInteractive, false)
            driver.move(y: bottom - fixture.accessory + 20, time: 0.2)
            fixture.window.layoutIfNeeded()
            XCTAssertEqual(fixture.updates.values.last?.isInteractive, true)
            XCTAssertEqual(fixture.updates.values.last?.height, -20)
            XCTAssertEqual(-fixture.host.layer.bounds.origin.y, bottom - fixture.keyboardTop + 20, accuracy: 1e-6)
        }
    }

    func testNativeReleaseAnimationsCarryTheSpecifiedCurvesAndRefreshRequests() throws {
        for maximum in [60, 61, 62, 120] {
            for scale in [1.0, 2] {
                let spring = try XCTUnwrap(KeyboardDismissalAnimation.make(dismisses: true, from: 70, to: 300,
                    durationScale: scale, maximumFramesPerSecond: maximum) as? CASpringAnimation)
                XCTAssertEqual(spring.mass, 1); XCTAssertEqual(spring.stiffness, 555.027); XCTAssertEqual(spring.damping, 47.118)
                XCTAssertEqual(spring.initialVelocity, 0); XCTAssertFalse(spring.allowsOverdamping)
                XCTAssertEqual(spring.duration, 0.3832); XCTAssertEqual(spring.speed, Float(1 / scale))
                XCTAssertEqual(spring.fromValue as? Double, 230); XCTAssertEqual(spring.toValue as? Double, 0)
                XCTAssertTrue(spring.isAdditive); XCTAssertEqual(spring.fillMode, .forwards); XCTAssertTrue(spring.isRemovedOnCompletion)
                XCTAssertEqual(spring.value(forKey: KeyboardDismissalAnimation.frameRateHint.key) as? Int, 1_048_619)
                XCTAssertEqual(spring.preferredFrameRateRange.minimum, maximum > 61 ? 30 : 80)
                XCTAssertEqual(spring.preferredFrameRateRange.maximum, maximum > 61 ? Float(maximum) : 120)
                XCTAssertEqual(spring.preferredFrameRateRange.preferred, maximum > 61 ? Float(maximum) : 120)
                let returning = KeyboardDismissalAnimation.make(dismisses: false, from: 70, to: 0,
                    durationScale: scale, maximumFramesPerSecond: maximum)
                XCTAssertFalse(returning is CASpringAnimation)
                XCTAssertEqual(returning.duration, 0.25); XCTAssertEqual(returning.fromValue as? Double, -70)
                var first: [Float] = [0, 0], second: [Float] = [0, 0]
                first.withUnsafeMutableBufferPointer { returning.timingFunction?.getControlPoint(at: 1, values: $0.baseAddress!) }
                second.withUnsafeMutableBufferPointer { returning.timingFunction?.getControlPoint(at: 2, values: $0.baseAddress!) }
                XCTAssertEqual(first, [0.380, 0.700]); XCTAssertEqual(second, [0.125, 1])
            }
        }
    }

    func testRefocusingDuringTheSystemHideRestoresTheRealKeyboard() async throws {
        for mode in ScrollEngineMode.allCases { try await checkRefocusing(mode: mode) }
    }

    func testRefocusingMatchesTheRealKeyboardWithAForwardOnlyClock() async throws {
        for mode in ScrollEngineMode.allCases { try await checkRefocusing(mode: mode, rewinds: false) }
    }

    func testRotationDuringRefocusKeepsTheNextKeyboardCycleWorking() async throws {
        for mode in ScrollEngineMode.allCases { try await checkRefocusing(mode: mode, rotationDuringRecovery: true) }
    }

    func testRotationRightAfterRefocusKeepsTheNextKeyboardCycleWorking() async throws {
        for mode in ScrollEngineMode.allCases { try await checkRefocusing(mode: mode, rotationDuringRecovery: false) }
    }

    private func checkRefocusing(mode: ScrollEngineMode, rewinds: Bool = true, rotationDuringRecovery: Bool? = nil) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let oldKey = scene.windows.first { $0.isKeyWindow }
        let controller = ListChatController(mode: mode), window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds; window.rootViewController = controller; window.makeKeyAndVisible()
        defer {
            controller.keyboardDismissal?.invalidate(); window.endEditing(true)
            window.isHidden = true; window.rootViewController = nil; oldKey?.makeKeyAndVisible()
            if rotationDuringRecovery != nil { scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) }
        }
        let initialBounds = scene.effectiveGeometry.coordinateSpace.bounds
        if rotationDuringRecovery != nil || initialBounds.width > initialBounds.height {
            try await rotate(scene, controller: controller, landscape: false)
        }
        controller.view.layoutIfNeeded()
        let composer = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UIStackView }.first?.arrangedSubviews.compactMap { $0 as? UITextView }.first)
        XCTAssertTrue(composer.becomeFirstResponder())
        try await Task.sleep(for: .milliseconds(800))
        let driver = try XCTUnwrap(controller.keyboardDismissal)
        driver.refresh()
        guard driver.isAvailable else { throw XCTSkip("This runtime supplies no in-process keyboard host") }
        let host = try XCTUnwrap(KeyboardHostLookup.find(in: scene))
        let frame = host.view.convert(host.view.bounds, to: window)
        let bar = try XCTUnwrap(controller.view.subviews.first { $0.accessibilityIdentifier == "composerBar" })
        let trace = KeyboardRecoveryTrace(window: window, bar: bar)
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: trace.events, options: [.sortedKeys, .prettyPrinted]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                let scenario = rotationDuringRecovery.map { $0 ? "rotate-during" : "rotate-after" } ?? (rewinds ? "rewind" : "forward")
                attachment.name = "native-keyboard-refocus-\(mode)-\(scenario)"
                attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        trace.record("before-dismiss")
        let accessory = bar.bounds.height + 8
        XCTAssertTrue(driver.begin(y: frame.minY - accessory - 40, time: 0, touchedView: controller.list))
        driver.move(y: frame.minY + 100, time: 0.06)
        driver.end(y: frame.minY + 110, time: 0.07)
        for _ in 0..<1000 where driver.ownership != .awaitingHide { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(driver.ownership, .awaitingHide)
        try await Task.sleep(for: .milliseconds(10))
        trace.record("before-refocus")
        XCTAssertTrue(composer.becomeFirstResponder())
        trace.record("after-refocus-call")
        CATransaction.flush(); try await Task.sleep(for: .milliseconds(35))
        trace.record("after-refocus-flush")
        let returned = try XCTUnwrap(KeyboardHostLookup.find(in: scene))
        let animation = try XCTUnwrap(returned.view.layer.animation(forKey: "ultraview.keyboard.dismissal"))
        let barAnimation = try XCTUnwrap(composerMotion(bar.layer))
        let listAnimation = try XCTUnwrap(controller.list.contentView.layer.animation(forKey: "ultraview.list.viewportOffset"))
        XCTAssertFalse((returned.view.layer.animationKeys() ?? []).contains {
            (returned.view.layer.animation(forKey: $0) as? CAPropertyAnimation)?.keyPath == "position"
        }, "The driver must replace the native position motion")
        let begin = returned.view.layer.convertTime(animation.beginTime, to: nil)
        XCTAssertEqual(bar.layer.convertTime(barAnimation.beginTime, to: nil), begin, accuracy: 0.000_001)
        XCTAssertEqual(controller.list.contentView.layer.convertTime(listAnimation.beginTime, to: nil), begin, accuracy: 0.000_001)
        let insetBeforeLateHide = controller.list.viewportInsets, barBeforeLateHide = bar.frame
        trace.record("injecting-late-hide")
        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        XCTAssertEqual(controller.list.viewportInsets, insetBeforeLateHide)
        XCTAssertEqual(bar.frame, barBeforeLateHide)
        XCTAssertTrue(driver.isDriving)
        if let rotationDuringRecovery {
            if !rotationDuringRecovery { try await Task.sleep(for: .milliseconds(700)) }
            try await rotate(scene, controller: controller, landscape: true)
            try await Task.sleep(for: .milliseconds(700))
            XCTAssertFalse(driver.isDriving)
            trace.record("after-rotation")
            try await checkTheNextKeyboardCycle(controller, window: window, composer: composer, bar: bar, trace: trace, checksInitialGuide: false)
            try await rotate(scene, controller: controller, landscape: false)
            return
        }
        let appBegin = window.layer.convertTime(begin, from: nil)
        let keyboardBegin = returned.window.layer.convertTime(begin, from: nil)
        window.layer.speed = 0; returned.window.layer.speed = 0
        let phases = rewinds ? [0.0, 0.1, 0.25, 0.5, 0.8, 1] : [0.15, 0.3, 0.5, 0.8, 1]
        for phase in phases {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            window.layer.timeOffset = appBegin + max(0.000_001, animation.duration * phase)
            returned.window.layer.timeOffset = keyboardBegin + max(0.000_001, animation.duration * phase)
            CATransaction.commit(); CATransaction.flush()
            try await Task.sleep(for: .milliseconds(35))
            trace.record("phase-\(phase)")
            let shown = try XCTUnwrap(returned.view.layer.presentation())
            let keyboardRoot = try XCTUnwrap(returned.window.layer.presentation())
            let contentTop = shown.convert(CGPoint.zero, to: keyboardRoot)
            let physicalTop = window.convert(contentTop, from: returned.window).y
            let containerFrame = window.convert(shown.convert(shown.bounds, to: keyboardRoot), from: returned.window)
            let targetFrame = returned.view.convert(returned.view.bounds, to: window)
            XCTAssertEqual(containerFrame.minY, targetFrame.minY, accuracy: 0.5,
                           "The replaced host frame must stay settled at phase \(phase)")
            let shownBar = try XCTUnwrap(bar.layer.presentation()), root = try XCTUnwrap(window.layer.presentation())
            let barBottom = shownBar.convert(shownBar.bounds, to: root).maxY
            let floor = controller.view.bounds.maxY - controller.view.safeAreaInsets.bottom
            if phase == 0 { XCTAssertGreaterThanOrEqual(physicalTop, floor - 0.5) }
            XCTAssertEqual(barBottom + 8, min(floor, physicalTop), accuracy: 0.5, "re-focus phase \(phase)")
        }
        window.layer.speed = 1; window.layer.timeOffset = 0
        returned.window.layer.speed = 1; returned.window.layer.timeOffset = 0
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertFalse(driver.isDriving)
        XCTAssertTrue(composer.isFirstResponder)
        XCTAssertEqual(returned.view.layer.bounds.origin.y, 0, accuracy: 0.5)
        let keyboardTop = hostFrame(returned, in: controller.view, window: window).minY
        XCTAssertEqual(bar.frame.maxY + 8, min(controller.view.bounds.maxY - controller.view.safeAreaInsets.bottom, keyboardTop), accuracy: 0.5)
        let endFrame = returned.view.convert(returned.view.bounds, to: window)
        XCTAssertEqual(trace.count(UIResponder.keyboardDidShowNotification, endingAt: endFrame, after: trace.showStart), 1, "Refocus must finish once")
        XCTAssertEqual(trace.count(UIResponder.keyboardDidChangeFrameNotification, endingAt: endFrame, after: trace.showStart), 1, "Refocus must report its shown frame once")
        try await checkTheNextKeyboardCycle(controller, window: window, composer: composer, bar: bar, trace: trace)
    }

    private func checkTheNextKeyboardCycle(_ controller: ListChatController, window: UIWindow, composer: UITextView,
                                           bar: UIView, trace: KeyboardRecoveryTrace, checksInitialGuide: Bool = true) async throws {
        let scene = try XCTUnwrap(window.windowScene)
        let host = try XCTUnwrap(KeyboardHostLookup.find(in: scene))
        XCTAssertFalse(host.window.isHidden)
        XCTAssertNotNil(host.view.window)
        XCTAssertTrue(composer.isFirstResponder)
        let text = composer.text ?? ""
        composer.insertText("x")
        XCTAssertEqual(composer.text, text + "x")
        composer.deleteBackward()
        controller.view.layoutIfNeeded()
        let frame = hostFrame(host, in: controller.view, window: window)
        let presented = try XCTUnwrap(host.view.layer.presentation()), keyboardRoot = try XCTUnwrap(host.window.layer.presentation())
        let physical = controller.view.convert(window.convert(presented.convert(CGPoint.zero, to: keyboardRoot), from: host.window), from: window)
        XCTAssertEqual(physical.y, frame.minY, accuracy: 0.5)
        // The hosted native control also retains a portrait guide frame after
        // rotation. Check the physical host now and the guide after its next
        // native keyboard change, when UIKit refreshes it on both paths.
        if checksInitialGuide { XCTAssertEqual(controller.view.keyboardLayoutGuide.layoutFrame.minY, frame.minY, accuracy: 0.5) }
        XCTAssertEqual(bar.frame.maxY + 8, min(controller.view.bounds.maxY - controller.view.safeAreaInsets.bottom, frame.minY), accuracy: 0.5)
        let endFrame = host.view.convert(host.view.bounds, to: window)
        let showsBefore = trace.count(UIResponder.keyboardDidShowNotification, endingAt: endFrame)
        let framesBefore = trace.count(UIResponder.keyboardDidChangeFrameNotification, endingAt: endFrame)
        XCTAssertTrue(composer.resignFirstResponder())
        CATransaction.flush(); try await Task.sleep(for: .milliseconds(35))
        XCTAssertTrue(hasPositionMotion(host.view.layer), "The next system hide must animate")
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertTrue(composer.becomeFirstResponder())
        CATransaction.flush(); try await Task.sleep(for: .milliseconds(35))
        let shown = try XCTUnwrap(KeyboardHostLookup.find(in: scene))
        XCTAssertTrue(hasPositionMotion(shown.view.layer), "The next system show must animate")
        try await Task.sleep(for: .milliseconds(700))
        trace.record("after-next-native-cycle")
        XCTAssertEqual(trace.count(UIResponder.keyboardDidShowNotification, endingAt: endFrame) - showsBefore, 1)
        XCTAssertEqual(trace.count(UIResponder.keyboardDidChangeFrameNotification, endingAt: endFrame) - framesBefore, 1)
        XCTAssertFalse(shown.window.isHidden)
        XCTAssertTrue(composer.isFirstResponder)
        controller.view.layoutIfNeeded()
        let top = hostFrame(shown, in: controller.view, window: window).minY
        XCTAssertEqual(controller.view.keyboardLayoutGuide.layoutFrame.minY, top, accuracy: 0.5)
        XCTAssertEqual(bar.frame.maxY + 8, min(controller.view.bounds.maxY - controller.view.safeAreaInsets.bottom, top), accuracy: 0.5)
        let driver = try XCTUnwrap(controller.keyboardDismissal)
        driver.refresh()
        let windowTop = shown.view.convert(shown.view.bounds, to: window).minY
        XCTAssertTrue(driver.begin(y: windowTop - bar.bounds.height - 48, time: 0, touchedView: controller.list))
        driver.move(y: windowTop + 100, time: 0.06)
        driver.end(y: windowTop + 110, time: 0.07)
        try await Task.sleep(for: .milliseconds(950))
        trace.record("after-next-driven-dismissal")
        XCTAssertFalse(composer.isFirstResponder)
        XCTAssertFalse(driver.isDriving)
    }

    private func hasPositionMotion(_ layer: CALayer) -> Bool {
        (layer.animationKeys() ?? []).contains { (layer.animation(forKey: $0) as? CAPropertyAnimation)?.keyPath == "position" }
    }

    private func hostFrame(_ host: KeyboardHostLookup.Host, in view: UIView, window: UIWindow) -> CGRect {
        let keyboard = host.view.convert(host.view.bounds, to: host.window)
        return view.convert(window.convert(keyboard, from: host.window), from: window)
    }

    private func rotate(_ scene: UIWindowScene, controller: UIViewController, landscape: Bool) async throws {
        try await setKeyboardSceneOrientation(scene, controller: controller, landscape: landscape)
    }
}

@MainActor private final class RotationOutcome { var error: String? }

@MainActor
private func setKeyboardSceneOrientation(_ scene: UIWindowScene, controller: UIViewController, landscape: Bool) async throws {
    let result = RotationOutcome()
    scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscapeLeft : .portrait)) { @Sendable error in
        let message = error.localizedDescription
        Task { @MainActor in result.error = message }
    }
    controller.setNeedsUpdateOfSupportedInterfaceOrientations()
    for _ in 0..<150 {
        let bounds = scene.effectiveGeometry.coordinateSpace.bounds
        if (bounds.width > bounds.height) == landscape { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    let bounds = scene.effectiveGeometry.coordinateSpace.bounds
    XCTAssertEqual(bounds.width > bounds.height, landscape, result.error ?? "The scene must rotate")
    try await Task.sleep(for: .milliseconds(600))
    controller.viewIfLoaded?.layoutIfNeeded()
}

/// This observer lives only in the test process and attaches its observations
/// to the result bundle. It does not change the app's notification handlers.
@MainActor
private final class KeyboardRecoveryTrace: NSObject {
    private weak var window: UIWindow?
    private weak var bar: UIView?
    private(set) var events: [[String: Any]] = []
    private var notificationFrames: [(Notification.Name, CGRect)] = []
    private(set) var showStart = 0

    init(window: UIWindow, bar: UIView) {
        self.window = window; self.bar = bar
        super.init()
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification,
                     UIResponder.keyboardDidShowNotification, UIResponder.keyboardDidHideNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)), name: name, object: nil)
        }
    }

    deinit { MainActor.assumeIsolated { NotificationCenter.default.removeObserver(self) } }

    @objc private func changed(_ notification: Notification) {
        if let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
           let window {
            let converted = window.convert(frame, from: nil)
            if notification.name == UIResponder.keyboardWillChangeFrameNotification, converted.minY < window.bounds.maxY - 0.5 {
                showStart = notificationFrames.count
            }
            notificationFrames.append((notification.name, converted))
        }
        var details: [String: Any] = [:]
        for key in [UIResponder.keyboardFrameBeginUserInfoKey, UIResponder.keyboardFrameEndUserInfoKey] {
            if let frame = notification.userInfo?[key] as? CGRect { details[key] = rect(frame) }
        }
        details["duration"] = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey]
        details["curve"] = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey]
        let label = notification.name == UIResponder.keyboardWillChangeFrameNotification ? "willChange-after-handler" : notification.name.rawValue
        record(label, details: details)
        if notification.name == UIResponder.keyboardWillChangeFrameNotification {
            DispatchQueue.main.async { [weak self] in self?.record("willChange-next-turn") }
        }
    }

    func count(_ name: Notification.Name, endingAt frame: CGRect, after index: Int = 0) -> Int {
        notificationFrames.dropFirst(index).filter { event in
            event.0 == name && abs(event.1.minX - frame.minX) < 0.5 && abs(event.1.minY - frame.minY) < 0.5
                && abs(event.1.width - frame.width) < 0.5 && abs(event.1.height - frame.height) < 0.5
        }.count
    }

    func record(_ label: String, details: [String: Any] = [:]) {
        var event: [String: Any] = ["label": label, "time": CACurrentMediaTime(), "details": details]
        if let bar { event["bar"] = snapshot(bar) }
        if let window, let host = KeyboardHostLookup.find(in: window.windowScene) {
            event["windowBounds"] = rect(window.bounds)
            event["sceneBounds"] = window.windowScene.map { rect($0.effectiveGeometry.coordinateSpace.bounds) }
            event["barParentBounds"] = bar.map { rect($0.superview?.bounds ?? .zero) }
            event["keyboardGuideFrame"] = bar.map { rect($0.superview?.keyboardLayoutGuide.layoutFrame ?? .zero) }
            var ancestry: [[String: Any]] = [], current: UIView? = host.view
            while let view = current { ancestry.append(snapshot(view)); current = view.superview }
            event["hostAncestry"] = ancestry
            event["hostModelFrameInApp"] = rect(host.view.convert(host.view.bounds, to: window))
            if let shown = host.view.layer.presentation(), let root = host.window.layer.presentation() {
                let content = shown.convert(CGPoint.zero, to: root)
                let point = window.convert(content, from: host.window)
                event["physicalContentTop"] = point.y
                event["presentedContainerFrame"] = rect(window.convert(shown.convert(shown.bounds, to: root), from: host.window))
            }
        }
        events.append(event)
    }

    private func snapshot(_ view: UIView) -> [String: Any] {
        let layer = view.layer
        var result: [String: Any] = ["class": NSStringFromClass(type(of: view)), "bounds": rect(layer.bounds),
                                     "frame": rect(layer.frame), "position": [layer.position.x, layer.position.y],
                                     "layerTime": layer.convertTime(CACurrentMediaTime(), from: nil),
                                     "speed": layer.speed, "timeOffset": layer.timeOffset, "beginTime": layer.beginTime,
                                     "masksToBounds": layer.masksToBounds, "hasMask": layer.mask != nil,
                                     "hasContents": layer.contents != nil, "backgroundAlpha": layer.backgroundColor?.alpha ?? 0,
                                     "shadowOpacity": layer.shadowOpacity]
        if let shown = layer.presentation() {
            result["presentedBounds"] = rect(shown.bounds); result["presentedFrame"] = rect(shown.frame)
            result["presentedPosition"] = [shown.position.x, shown.position.y]
        }
        result["animations"] = (layer.animationKeys() ?? []).compactMap { key -> [String: Any]? in
            guard let animation = layer.animation(forKey: key) else { return nil }
            var value: [String: Any] = ["key": key, "class": NSStringFromClass(type(of: animation)),
                                        "beginTime": animation.beginTime, "duration": animation.duration, "speed": animation.speed,
                                        "timeOffset": animation.timeOffset, "removedOnCompletion": animation.isRemovedOnCompletion,
                                        "fillMode": animation.fillMode.rawValue]
            if let timing = animation.timingFunction {
                var first = [Float](repeating: 0, count: 2), second = [Float](repeating: 0, count: 2)
                timing.getControlPoint(at: 1, values: &first); timing.getControlPoint(at: 2, values: &second)
                value["timingPoints"] = [first, second]
            }
            if let property = animation as? CAPropertyAnimation { value["path"] = property.keyPath; value["additive"] = property.isAdditive }
            if let basic = animation as? CABasicAnimation {
                value["from"] = basic.fromValue.map { String(describing: $0) }
                value["to"] = basic.toValue.map { String(describing: $0) }
            }
            if let frames = animation as? CAKeyframeAnimation, let values = frames.values {
                value["samples"] = [values.first, values.dropFirst(values.count / 4).first, values.dropFirst(values.count / 2).first, values.last].map { $0.map { String(describing: $0) } ?? "nil" }
            }
            if let spring = animation as? CASpringAnimation {
                value["mass"] = spring.mass; value["stiffness"] = spring.stiffness
                value["damping"] = spring.damping; value["velocity"] = spring.initialVelocity
            }
            return value
        }
        return result
    }

    private func rect(_ frame: CGRect) -> [Double] { [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)] }
}

@MainActor
private final class Fixture {
    let updates = KeyboardUpdateLog()
    let controller: ListChatController
    let window: UIWindow
    let keyboardWindow: UIWindow
    let host: UIView
    let bar: UIView
    let driver: KeyboardDismissalController
    let keyboardTop: Double
    let accessory: Double
    private let input = InputView()
    private let oldKey: UIWindow?
    var list: UltraListView { controller.list }

    init(mode: ScrollEngineMode, scale: Double = 1) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        oldKey = scene.windows.first { $0.isKeyWindow }
        controller = ListChatController(mode: mode); window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds; window.rootViewController = controller; window.makeKeyAndVisible()
        if window.bounds.width > window.bounds.height {
            try await setKeyboardSceneOrientation(scene, controller: controller, landscape: false)
        }
        controller.view.layoutIfNeeded(); controller.keyboardDismissal?.invalidate()
        bar = try XCTUnwrap(controller.view.subviews.first { $0.accessibilityIdentifier == "composerBar" })
        accessory = bar.bounds.height
        let height = min(300, window.bounds.height * 0.45)
        keyboardTop = window.bounds.maxY - height
        keyboardWindow = UIWindow(windowScene: scene); keyboardWindow.frame = window.frame
        let keyboardController = UIViewController(); keyboardWindow.rootViewController = keyboardController
        host = UIView(frame: CGRect(x: 0, y: keyboardTop, width: window.bounds.width, height: height))
        keyboardController.view.addSubview(host); keyboardWindow.isHidden = false
        keyboardController.view.layoutIfNeeded()
        controller.view.addSubview(input)
        XCTAssertTrue(input.becomeFirstResponder())
        let keyboardWindow = self.keyboardWindow, host = self.host, input = self.input, bar = self.bar, controller = self.controller, updates = self.updates
        driver = KeyboardDismissalController(scrollView: controller.list, coordinateView: controller.view,
            accessoryHeight: { [weak bar] in Double(bar?.bounds.height ?? 0) },
            restingHeight: { [weak controller] in Double(controller?.view.safeAreaInsets.bottom ?? 0) },
            hasInput: { [weak input] in input?.isFirstResponder == true },
            lookupHost: { _ in keyboardWindow.isHidden ? nil : .init(window: keyboardWindow, view: host) },
            update: { [weak controller] in updates.values.append($0); controller?.applyDrivenKeyboard($0) })
        controller.keyboardDismissal = driver; driver.refresh()
        controller.list.animationDurationScale = scale
        for _ in 0..<150 where controller.list.loadedIndexRange.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        controller.list.scrollTo(.init(index: 25), transition: .none)
        for _ in 0..<150 where !controller.list.loadedIndexRange.contains(25) { try await Task.sleep(for: .milliseconds(20)) }
        controller.keyboardFrameChanged(height: height, duration: 0, curve: 7)
        CATransaction.flush(); try await Task.sleep(for: .milliseconds(60))
    }

    func rowGap(_ row: UIView) throws -> Double {
        let root = try XCTUnwrap(window.layer.presentation()), row = try XCTUnwrap(row.layer.presentation())
        let bar = try XCTUnwrap(bar.layer.presentation())
        return row.convert(row.bounds, to: root).maxY - bar.convert(bar.bounds, to: root).minY
    }

    func close() {
        driver.invalidate(); controller.list.haltScrolling()
        window.endEditing(true); keyboardWindow.isHidden = true; window.isHidden = true
        keyboardWindow.rootViewController = nil; window.rootViewController = nil; oldKey?.makeKeyAndVisible()
    }
}

@MainActor private final class KeyboardUpdateLog {
    var values: [KeyboardDismissalUpdate] = []
}

@MainActor private final class InputView: UIView {
    override var canBecomeFirstResponder: Bool { true }
}

@MainActor
private func composerMotion(_ layer: CALayer) -> CAPropertyAnimation? {
    layer.animationKeys()?.compactMap { layer.animation(forKey: $0) as? CAPropertyAnimation }
        .first { $0.keyPath == "position.y" }
}
#endif