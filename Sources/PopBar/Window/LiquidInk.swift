import SwiftUI

/// The Liquid style's ink, shared by the ring and the capsule so the two match:
/// dark navy (light mode) or near-white (dark mode) at rest, the app icon's
/// gradient when hovered.
///
/// Dark mode is read from the raw OS setting rather than the view's colour
/// scheme; see `WheelActionsView.isDark` for why.
enum LiquidInk {
    static var isDark: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    /// The app icon's own gradient (`scripts/make-icon.py`: #2563EB above, #06B6D4
    /// below, leaning slightly right). Lifted a step in dark mode so it reads on the
    /// dark glass.
    static func brandColors(dark: Bool = isDark) -> (top: Color, bottom: Color) {
        dark
            ? (Color(red: 0.376, green: 0.647, blue: 0.980), Color(red: 0.133, green: 0.827, blue: 0.933))   // #60A5FA → #22D3EE
            : (Color(red: 0.145, green: 0.388, blue: 0.922), Color(red: 0.024, green: 0.714, blue: 0.831))   // #2563EB → #06B6D4
    }

    static func brandGradient(dark: Bool = isDark) -> LinearGradient {
        let c = brandColors(dark: dark)
        return LinearGradient(colors: [c.top, c.bottom], startPoint: .top, endPoint: UnitPoint(x: 0.35, y: 1))
    }

    static func glyph(hot: Bool, dark: Bool = isDark) -> AnyShapeStyle {
        if hot { return AnyShapeStyle(brandGradient(dark: dark)) }
        return AnyShapeStyle(dark ? Color.white.opacity(0.92) : Color(red: 0.17, green: 0.21, blue: 0.27))
    }
}
