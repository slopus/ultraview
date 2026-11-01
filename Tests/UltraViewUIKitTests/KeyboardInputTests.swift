#if canImport(UIKit)
import UIKit
import Testing
import UltraCore
@testable import UltraList

/// The system's interactive keyboard input on our engines exists only while
/// a docked keyboard is up.
@MainActor
@Suite(.serialized) struct KeyboardInputTests {
    private func announce(_ frame: CGRect?) {
        if let frame {
            NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
                                            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: frame])
        } else {
            NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
                                            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(x: 0, y: 844, width: 390, height: 336)])
            NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        }
    }

    private func settle() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        view.subviews.compactMap { $0 as? UIScrollView }.filter { !($0 is ScrollToTopProxy) }
    }

    @Test(arguments: [ScrollEngineMode.keyframe, .stepped])
    func theInputExistsOnlyWhileADockedKeyboardIsUp(mode: ScrollEngineMode) async {
        announce(nil)
        let window = makeWindow()
        window.frame = .init(x: 0, y: 0, width: 390, height: 844)
        let list = UltraScrollView(engineMode: mode)
        list.frame = window.bounds
        window.addSubview(list); window.isHidden = false
        defer { window.isHidden = true; list.removeFromSuperview(); announce(nil) }
        list.keyboardDismissMode = .interactive
        #expect(!list.hasKeyboardInput)
        #expect(scrollViews(in: list).isEmpty)
        #expect(list.gestureRecognizers?.count ?? 0 == 0)

        announce(.init(x: 0, y: 508, width: 390, height: 336))
        #expect(list.hasKeyboardInput)
        #expect(scrollViews(in: list).count == 1)
        #expect(list.gestureRecognizers?.count == 1)

        // A floating keyboard isn't followed: the input leaves.
        announce(.init(x: 40, y: 300, width: 300, height: 250))
        await settle()
        #expect(!list.hasKeyboardInput)
        #expect(scrollViews(in: list).isEmpty)
        #expect(list.gestureRecognizers?.count ?? 0 == 0)

        announce(.init(x: 0, y: 508, width: 390, height: 336))
        #expect(list.hasKeyboardInput)
        // On its way off the screen it keeps the input until it has hidden.
        if let screen = window.windowScene?.screen {
            NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: screen, userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: CGRect(x: 0, y: screen.bounds.maxY, width: 390, height: 336)])
            await settle()
            #expect(list.hasKeyboardInput)
        }
        announce(nil)
        await settle()
        #expect(!list.hasKeyboardInput)
        #expect(list.gestureRecognizers?.count ?? 0 == 0)

        // Out of the window, or with another mode, a docked keyboard adds nothing.
        announce(.init(x: 0, y: 508, width: 390, height: 336))
        list.keyboardDismissMode = .onDrag
        await settle()
        #expect(!list.hasKeyboardInput)
        list.keyboardDismissMode = .interactive
        #expect(list.hasKeyboardInput)
        list.removeFromSuperview()
        await settle()
        #expect(!list.hasKeyboardInput)
        window.addSubview(list)
        #expect(list.hasKeyboardInput)
    }

    @Test func aSharedInputSurfaceCarriesTheInputPan() async {
        announce(nil)
        let window = makeWindow()
        window.frame = .init(x: 0, y: 0, width: 390, height: 844)
        let surface = UIView(frame: window.bounds), list = UltraScrollView(engineMode: .keyframe)
        list.frame = surface.bounds
        surface.addSubview(list); window.addSubview(surface); window.isHidden = false
        defer { window.isHidden = true; announce(nil) }
        list.keyboardDismissMode = .interactive
        list.attachScrollInput(to: surface)
        let panCount = surface.gestureRecognizers?.count ?? 0
        announce(.init(x: 0, y: 508, width: 390, height: 336))
        #expect(surface.gestureRecognizers?.count == panCount + 1)
        announce(nil)
        await settle()
        #expect(surface.gestureRecognizers?.count == panCount)
    }

    @Test func aHostFrameCrossesWindowsThroughTheirScreenFrames() {
        let keyboardWindow = makeWindow(), window = makeWindow()
        keyboardWindow.frame = .init(x: 0, y: 0, width: 428, height: 926)
        window.frame = .init(x: 0, y: 40, width: 428, height: 886)
        let rect = CGRect(x: 0, y: 579, width: 428, height: 347)
        #expect(KeyboardHostLookup.transfer(rect, from: keyboardWindow, to: window) == CGRect(x: 0, y: 539, width: 428, height: 347))
        #expect(KeyboardHostLookup.transfer(rect, from: window, to: window) == rect)
        let container = UIView(frame: keyboardWindow.bounds), host = UIView(frame: rect)
        container.addSubview(host); keyboardWindow.addSubview(container)
        let frame = KeyboardHostLookup.frame(of: .init(window: keyboardWindow, view: host), in: window)
        #expect(frame == CGRect(x: 0, y: 539, width: 428, height: 347))
    }

    @Test func theUIKitEngineKeepsItsOwnMode() {
        let list = UltraScrollView(engineMode: .uiKit)
        list.keyboardDismissMode = .interactive
        #expect((list.contentView as? UIScrollView)?.keyboardDismissMode == .interactive)
        list.keyboardDismissMode = .onDrag
        #expect((list.contentView as? UIScrollView)?.keyboardDismissMode == .onDrag)
    }
}
#endif
