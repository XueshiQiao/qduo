import SwiftUI
import AppKit

/// A provider's name with its logo in front, for the provider pickers (the AI
/// Models page, the action editor). The onboarding guide's provider buttons use
/// `icon` alone.
///
/// The logos are in `Assets.xcassets/ProviderLogos`, named `ProviderLogo-<id>`:
/// the services' marks from Lobe Icons (github.com/lobehub/lobe-icons, MIT), the
/// bird from Magpie's own app icon, and slider lines for "Custom". Each sits on a
/// white rounded tile, so a coloured mark stays visible on a menu's blue
/// highlight and in dark mode. They are 16 points square, the size of a menu
/// item's image (a menu draws an image at its own size).
struct ProviderLabel: View {
    let provider: String

    var body: some View {
        Label {
            Text(LLMConfig.displayName(provider))
        } icon: {
            Self.icon(provider)
        }
    }

    /// The logo; a provider added later without one gets "Custom"'s.
    static func icon(_ provider: String) -> Image {
        let name = "ProviderLogo-\(provider)"
        return Image(NSImage(named: name) != nil ? name : "ProviderLogo-custom")
    }
}
