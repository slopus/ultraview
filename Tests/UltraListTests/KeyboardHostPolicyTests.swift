import Testing
@testable import UltraList

/// Frames measured on an iPad Pro 13-inch (iOS 27) and an iPhone 13 Pro Max.
struct KeyboardHostPolicyTests {
    private func drives(host: (Double, Double, Double, Double), window: (Double, Double), screen: (Double, Double)) -> Bool {
        KeyboardHostPolicy.drives(host: .init(minX: host.0, minY: host.1, maxX: host.0 + host.2, maxY: host.1 + host.3),
                                  window: .init(minX: 0, minY: 0, maxX: window.0, maxY: window.1),
                                  screenWidth: screen.0, screenHeight: screen.1)
    }

    @Test func aDockedKeyboardUnderAFullScreenWindowIsDriven() {
        // iPad, portrait and landscape.
        #expect(drives(host: (0, 973, 1032, 403), window: (1032, 1376), screen: (1032, 1376)))
        #expect(drives(host: (0, 534, 1376, 498), window: (1376, 1032), screen: (1376, 1032)))
        // Phone, portrait and landscape.
        #expect(drives(host: (0, 580, 428, 346), window: (428, 926), screen: (428, 926)))
        #expect(drives(host: (0, 228, 926, 200), window: (926, 428), screen: (926, 428)))
        // Half a point of rounding either way.
        #expect(drives(host: (0, 973, 1031.5, 402.5), window: (1032, 1376), screen: (1032.5, 1376)))
    }

    @Test func aWindowSmallerThanTheScreenLeavesTheKeyboardToTheSystem() {
        // Windowed apps: a 384 by 557 window over the screen-wide docked
        // keyboard, which its own window reports at the screen's origin.
        #expect(!drives(host: (0, 973, 1032, 403), window: (384, 557), screen: (1032, 1376)))
        // A full-height window across half the screen.
        #expect(!drives(host: (0, 973, 1032, 403), window: (516, 1376), screen: (1032, 1376)))
        // A full-width window that doesn't reach the bottom.
        #expect(!drives(host: (0, 973, 1032, 403), window: (1032, 1000), screen: (1032, 1376)))
        // A window still in its old orientation while the screen turns.
        #expect(!drives(host: (0, 973, 1032, 403), window: (1032, 1376), screen: (1376, 1032)))
    }

    @Test func onlyAKeyboardDockedAcrossTheBottomIsDriven() {
        // Floating.
        #expect(!drives(host: (356, 879.5, 320, 322.5), window: (1032, 1376), screen: (1032, 1376)))
        // Undocked above the bottom edge.
        #expect(!drives(host: (0, 600, 1032, 403), window: (1032, 1376), screen: (1032, 1376)))
        // Moved off the bottom, and empty.
        #expect(!drives(host: (0, 1376, 1032, 403), window: (1032, 1376), screen: (1032, 1376)))
        #expect(!drives(host: (0, 1376, 1032, 0), window: (1032, 1376), screen: (1032, 1376)))
    }

    @Test func aWindowCoversTheScreenOnlyAtItsSizeInItsOrientation() {
        func covers(_ width: Double, _ height: Double, screen: (Double, Double)) -> Bool {
            KeyboardHostPolicy.coversScreen(window: .init(minX: 0, minY: 0, maxX: width, maxY: height),
                                            screenWidth: screen.0, screenHeight: screen.1)
        }
        #expect(covers(1032, 1376, screen: (1032, 1376)))
        #expect(covers(1376, 1032, screen: (1376, 1032)))
        #expect(covers(1032.5, 1375.5, screen: (1032, 1376)))
        #expect(!covers(384, 557, screen: (1032, 1376)))
        #expect(!covers(1032, 1376, screen: (1376, 1032)))
    }
}
