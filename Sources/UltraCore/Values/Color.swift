import Foundation
import UltraLayout
#if canImport(UIKit)
import UIKit
#endif

/// An sRGB color with an optional variant for dark appearance. Nodes keep
/// colors as values; the pipeline resolves them off the main thread for the
/// host's current appearance.
public struct Color: Sendable, Hashable {
    /// One concrete sRGB color, components in 0...1.
    public struct Components: Sendable, Hashable {
        public var red: CGFloat
        public var green: CGFloat
        public var blue: CGFloat
        public var alpha: CGFloat

        public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        public var isClear: Bool { alpha <= 0 }
    }

    public var light: Components
    public var dark: Components?

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        light = Components(red: red, green: green, blue: blue, alpha: alpha)
    }

    public init(white: CGFloat, alpha: CGFloat = 1) {
        self.init(red: white, green: white, blue: white, alpha: alpha)
    }

    /// `Color(hex: 0x3478F6)`.
    public init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// A color that changes with the appearance.
    public static func dynamic(light: Color, dark: Color) -> Color {
        var color = light
        color.dark = dark.light
        return color
    }

    public func resolved(dark isDark: Bool) -> Components {
        isDark ? (dark ?? light) : light
    }

    public func withAlpha(_ alpha: CGFloat) -> Color {
        var color = self
        color.light.alpha = alpha
        color.dark?.alpha = alpha
        return color
    }

    public static let clear = Color(white: 0, alpha: 0)
    public static let black = Color(white: 0)
    public static let white = Color(white: 1)
    public static let gray = Color(white: 0.5)
    public static let red = Color(hex: 0xFF3B30)
    public static let orange = Color(hex: 0xFF9500)
    public static let yellow = Color(hex: 0xFFCC00)
    public static let green = Color(hex: 0x34C759)
    public static let teal = Color(hex: 0x30B0C7)
    public static let blue = Color(hex: 0x007AFF)
    public static let indigo = Color(hex: 0x5856D6)
    public static let purple = Color(hex: 0xAF52DE)
    public static let pink = Color(hex: 0xFF2D55)

    #if canImport(UIKit)
    /// Captures a UIKit color, including its dark variant if it has one.
    public init(_ color: UIColor) {
        func components(_ style: UIUserInterfaceStyle) -> Components {
            let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return Components(red: red, green: green, blue: blue, alpha: alpha)
        }
        light = components(.light)
        let dark = components(.dark)
        self.dark = dark == light ? nil : dark
    }
    #endif
}
